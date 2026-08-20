## nimver: semantic versioning for Nim projects, driven by
## Conventional Commits and wired into Git via a `commit-msg` hook.

import std/[os, strutils, sequtils, algorithm, tables]
import ./gitutils
import ./config
import ./commitparser
import ./changes
import ./adapters/manifest
import ./changelog
import ./hooks
import ./semver
import ./workspace

const NimblePkgVersion {.strdefine.} = "unknown"

const Usage = """
nimver - semantic versioning from Conventional Commits

Usage:
  nimver init
  nimver install-hooks [--force]
  nimver bump [<package>] [--no-commit] [--no-tag] [--dry-run]
  nimver version

`bump` takes a package name only in an `independent` workspace, where it
releases that one package. A `fixed` workspace always releases every package.

Invoked by installed hooks (not usually run by hand):
  nimver check-commit-msg <path-to-message-file>
  nimver record-commit
"""

proc cmdVersion() =
  echo NimblePkgVersion

proc cmdInit(repoRoot: string) =
  createDir(changesDir(repoRoot))
  let cfgPath = configPath(repoRoot)
  if fileExists(cfgPath):
    echo "Config already exists at ", cfgPath
  else:
    writeFile(cfgPath, DefaultConfig)
    echo "Created ", cfgPath
  echo "Run `nimver install-hooks` to wire up the commit-msg hook."

proc cmdInstallHooks(repoRoot: string, force: bool) =
  let hooksDir = installHooks(repoRoot, force)
  echo "Installed commit-msg hook at ", hooksDir / "commit-msg"
  echo "Installed post-commit hook at ", hooksDir / "post-commit"

proc validateAndLookup(cfg: Config, parsed: ParsedCommit): (bool, string, BumpLevel) =
  ## Returns `(ok, errorMessage, bumpLevel)`.
  let (known, configuredLevel) = lookupType(cfg, parsed.commitType)
  if not known:
    let allowed = toSeq(cfg.types.keys).sorted().join(", ")
    return (
      false,
      "unknown commit type '" & parsed.commitType & "'. Allowed types: " & allowed,
      blNone,
    )
  let bumpLevel = if parsed.breaking: blMajor else: configuredLevel
  (true, "", bumpLevel)

proc cmdCheckCommitMsg(repoRoot: string, msgFilePath: string) =
  ## Runs as the `commit-msg` hook. Only validates; the commit's tree is
  ## already fixed by this point, so writing the bump-note file here would
  ## not end up in the commit being created (see `record-commit`).
  let raw = readFile(msgFilePath)
  let (ok, err, parsed) = parseCommitMessage(raw)
  if not ok:
    stderr.writeLine("nimver: invalid commit message: " & err)
    quit(1)

  let cfg = loadConfig(repoRoot)
  let (validType, typeErr, _) = validateAndLookup(cfg, parsed)
  if not validType:
    stderr.writeLine("nimver: " & typeErr)
    quit(1)

proc cmdRecordCommit(repoRoot: string) =
  ## Runs as the `post-commit` hook. Writes the bump-note file for the
  ## commit that was just created and folds it into that same commit via a
  ## guarded amend (see the `post-commit` hook script for the re-entrancy
  ## guard).
  if isRebaseInProgress(repoRoot):
    # Amending here would fight with the rebase sequencer's own bookkeeping
    # (see `isRebaseInProgress`). Leave existing notes untouched; review
    # `.nimver/changes` once the rebase completes if any
    # reworded commits should have their notes updated.
    stderr.writeLine(
      "nimver: skipping change-note recording during an in-progress rebase"
    )
    return

  let raw = gitLastCommitMessage(repoRoot)
  let (ok, err, parsed) = parseCommitMessage(raw)
  if not ok:
    stderr.writeLine("nimver: skipping unparseable commit: " & err)
    return

  let cfg = loadConfig(repoRoot)
  let (validType, typeErr, bumpLevel) = validateAndLookup(cfg, parsed)
  if not validType:
    stderr.writeLine("nimver: skipping commit: " & typeErr)
    return
  let projectWorkspace = loadWorkspace(repoRoot, cfg)
  let changedPaths = gitHeadChangedPaths(repoRoot)
  let affectedPackages = affectedPackageNames(projectWorkspace, changedPaths)

  # If HEAD *added* a change-note file, this call is amending a commit that was
  # already recorded rather than a brand-new commit - remove the stale note
  # (whatever its previously recorded type was) before writing a fresh one.
  # Checking the commit's actual diff (rather than tracking hashes) also means a
  # reword that changes the commit's type (e.g. `fix:` -> `feat:`) is handled
  # correctly for free. Only additions count: a release commit legitimately
  # rewrites notes that are still pending for other packages.
  var dirty = false
  for path in gitHeadAddedPaths(repoRoot):
    if path.startsWith(ChangesRelPrefix) and path.endsWith(".txt"):
      let full = repoRoot / path
      if fileExists(full):
        removeFile(full)
        dirty = true

  if bumpLevel != blIgnore and affectedPackages.len > 0:
    discard writeChangeFile(
      repoRoot, parsed.commitType, bumpLevel, parsed.breaking, affectedPackages,
      parsed.rawMessage,
    )
    dirty = true

  if not dirty:
    return

  gitAdd(repoRoot, changesDir(repoRoot))
  putEnv("NIMVER_AMENDING", "1")
  gitAmendNoVerify(repoRoot)

proc highestBumpLevel(entries: seq[ChangeEntry]): BumpLevel =
  result = blNone
  for entry in entries:
    if entry.bumpLevel > result:
      result = entry.bumpLevel

proc changelogPathFor(repoRoot: string, package: WorkspacePackage): string =
  ## An independently versioned package keeps its changelog next to its
  ## manifest, since its version moves on its own schedule.
  if package.rootDirectory.len == 0:
    repoRoot / "CHANGELOG.md"
  else:
    repoRoot / package.rootDirectory / "CHANGELOG.md"

proc hasSeveralPackages(projectWorkspace: Workspace): bool =
  ## Tags and release commits are namespaced only once there is more than one
  ## package to tell apart. A lone package keeps the flat `vX.Y.Z` scheme,
  ## whether it was detected or declared - naming a package to exclude a
  ## sibling manifest should not change how releases are tagged.
  projectWorkspace.packages.len > 1

proc releaseTagFor(
    projectWorkspace: Workspace, package: WorkspacePackage, version: SemVer
): string =
  if projectWorkspace.hasSeveralPackages():
    package.name & "-v" & $version
  else:
    "v" & $version

proc releaseCommitSubjectFor(
    projectWorkspace: Workspace, package: WorkspacePackage, version: SemVer
): string =
  if projectWorkspace.hasSeveralPackages():
    "version(" & package.name & "): v" & $version
  else:
    "version: v" & $version

proc releaseLabelFor(projectWorkspace: Workspace, package: WorkspacePackage): string =
  ## What the release is called in progress output: the package name when
  ## several exist, otherwise the same wording as a fixed release.
  if projectWorkspace.hasSeveralPackages(): package.name else: "version"

proc reportSkippedTag() =
  # Without a release commit, HEAD is still whatever it was before this run -
  # tagging it would mislabel an unrelated commit.
  echo "Skipped tag: no release commit was created (pass --no-tag along with --no-commit)."

proc bumpFixedWorkspace(
    repoRoot: string,
    projectWorkspace: Workspace,
    entries: seq[ChangeEntry],
    doCommit, doTag, dryRun: bool,
) =
  let overall = highestBumpLevel(entries)
  if overall == blNone:
    echo "All pending changes are non-version-impacting (bump=none). Nothing to bump."
    return

  let current = readVersion(projectWorkspace.packages[0].manifest)
  for package in projectWorkspace.packages[1 .. ^1]:
    let packageVersion = readVersion(package.manifest)
    if packageVersion != current:
      raise newException(
        IOError,
        "Fixed workspace manifests must have the same version: package '" &
          projectWorkspace.packages[0].name & "' is " & $current & ", package '" &
          package.name & "' is " & $packageVersion,
      )
  let next = bump(current, overall)
  let section = buildSection(next, entries)
  let changelogPath = repoRoot / "CHANGELOG.md"

  echo "Bumping version: ", $current, " -> ", $next, " (", $overall, ")"
  if dryRun:
    echo "\n--- CHANGELOG entry (dry run, nothing written) ---"
    echo section
    return

  for package in projectWorkspace.packages:
    writeVersion(package.manifest, next)
  prependToChangelog(changelogPath, section)
  deleteChangeFiles(entries)
  for package in projectWorkspace.packages:
    echo "Updated ",
      package.manifest.filePath, " (", package.manifest.displayName(), ")"
  echo "Updated ", changelogPath

  if doCommit:
    for package in projectWorkspace.packages:
      gitAdd(repoRoot, package.manifest.filePath)
    gitAdd(repoRoot, changelogPath)
    gitAdd(repoRoot, changesDir(repoRoot))
    gitCommit(repoRoot, "version: v" & $next)
    echo "Created release commit."

  if doTag:
    if not doCommit:
      reportSkippedTag()
    else:
      gitTag(repoRoot, "v" & $next)
      echo "Created tag v" & $next

proc bumpPackage(
    repoRoot: string,
    projectWorkspace: Workspace,
    package: WorkspacePackage,
    allEntries: seq[ChangeEntry],
    doCommit, doTag, dryRun: bool,
) =
  let entries =
    allEntries.filterIt(package.name in projectWorkspace.effectivePackages(it))
  if entries.len == 0:
    echo "No pending changes for package '", package.name, "'. Nothing to bump."
    return

  let overall = highestBumpLevel(entries)
  if overall == blNone:
    echo "All pending changes are non-version-impacting (bump=none). Nothing to bump."
    return

  let current = readVersion(package.manifest)
  let next = bump(current, overall)
  let section = buildSection(next, entries)
  let changelogPath = changelogPathFor(repoRoot, package)
  let tag = releaseTagFor(projectWorkspace, package, next)

  echo "Bumping ",
    releaseLabelFor(projectWorkspace, package),
    ": ",
    $current,
    " -> ",
    $next,
    " (",
    $overall,
    ")"
  if dryRun:
    echo "\n--- CHANGELOG entry (dry run, nothing written) ---"
    echo section
    return

  writeVersion(package.manifest, next)
  prependToChangelog(changelogPath, section)
  for entry in entries:
    let remainingPackages =
      projectWorkspace.effectivePackages(entry).filterIt(it != package.name)
    entry.rewriteAffectedPackages(remainingPackages)
  echo "Updated ", package.manifest.filePath, " (", package.manifest.displayName(), ")"
  echo "Updated ", changelogPath

  if doCommit:
    gitAdd(repoRoot, package.manifest.filePath)
    gitAdd(repoRoot, changelogPath)
    gitAdd(repoRoot, changesDir(repoRoot))
    gitCommit(repoRoot, releaseCommitSubjectFor(projectWorkspace, package, next))
    echo "Created release commit."

  if doTag:
    if not doCommit:
      reportSkippedTag()
    else:
      gitTag(repoRoot, tag)
      echo "Created tag " & tag

proc packagesWithPendingChanges(
    projectWorkspace: Workspace, entries: seq[ChangeEntry]
): seq[string] =
  for package in projectWorkspace.packages:
    for entry in entries:
      if package.name in projectWorkspace.effectivePackages(entry):
        result.add(package.name)
        break

proc cmdBump(repoRoot, requestedPackageName: string, doCommit, doTag, dryRun: bool) =
  ## `doCommit`/`doTag` are true by default at the call site; `--no-commit`
  ## / `--no-tag` on the command line opt out of either one.
  let config = loadConfig(repoRoot)
  let projectWorkspace = loadWorkspace(repoRoot, config)
  let entries = readChangeFiles(repoRoot)
  if entries.len == 0:
    echo "No pending changes found in .nimver/changes. Nothing to bump."
    return

  case projectWorkspace.strategy
  of wsFixed:
    if requestedPackageName.len > 0:
      raise newException(
        IOError,
        "workspace strategy is 'fixed', so `nimver bump` releases every package at once. Drop the package argument, or set strategy = independent.",
      )
    bumpFixedWorkspace(repoRoot, projectWorkspace, entries, doCommit, doTag, dryRun)
  of wsIndependent:
    # With a single package there is nothing to disambiguate, so a bare `bump`
    # releases it. Naming a package is only required once several exist.
    let package =
      if requestedPackageName.len > 0:
        projectWorkspace.findPackage(requestedPackageName)
      elif projectWorkspace.packages.len == 1:
        projectWorkspace.packages[0]
      else:
        raise newException(
          IOError,
          "workspace strategy is 'independent', so `nimver bump` needs a package to release. Packages with pending changes: " &
            packagesWithPendingChanges(projectWorkspace, entries).join(", "),
        )
    bumpPackage(repoRoot, projectWorkspace, package, entries, doCommit, doTag, dryRun)

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    echo Usage
    quit(1)

  if args[0] in ["version", "--version", "-v"]:
    cmdVersion()
    quit(0)

  var repoRoot: string
  try:
    repoRoot = findRepoRoot()
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)

  try:
    case args[0]
    of "init":
      cmdInit(repoRoot)
    of "install-hooks":
      cmdInstallHooks(repoRoot, "--force" in args)
    of "check-commit-msg":
      if args.len < 2:
        stderr.writeLine("Usage: nimver check-commit-msg <path-to-message-file>")
        quit(1)
      cmdCheckCommitMsg(repoRoot, args[1])
    of "record-commit":
      cmdRecordCommit(repoRoot)
    of "bump":
      var requestedPackageName = ""
      for arg in args[1 .. ^1]:
        if not arg.startsWith("--"):
          if requestedPackageName.len > 0:
            stderr.writeLine("nimver: `bump` takes at most one package name")
            quit(1)
          requestedPackageName = arg
      cmdBump(
        repoRoot,
        requestedPackageName,
        not ("--no-commit" in args),
        not ("--no-tag" in args),
        "--dry-run" in args,
      )
    else:
      echo Usage
      quit(1)
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)
