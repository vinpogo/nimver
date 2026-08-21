## nimver: semantic versioning for Nim projects, driven by
## Conventional Commits and wired into Git via a `commit-msg` hook.

import std/[os, strutils, sequtils, algorithm, sets, tables]
import ./gitutils
import ./config
import ./commitparser
import ./changes
import ./adapters/manifest
import ./changelog
import ./semver
import ./workspace
import ./result
import ./commands/init
import ./commands/version
import ./commands/installHooks
import ./commands/checkCommitMsg

const Usage = """
nimver - semantic versioning from Conventional Commits

Usage:
  nimver init
  nimver install-hooks [--force]
  nimver bump [<package>] [--no-commit] [--no-tag] [--dry-run]
  nimver version

See https://github.com/vinpogo/nimver for details.

"""

proc syncNoteForCommit(
    repoRoot: string, cfg: Config, projectWorkspace: Workspace, revision: string
): bool =
  ## Brings the change note recorded for `revision` in line with that commit's
  ## message, and reports whether the working tree changed.
  ##
  ## The note a commit recorded shows up as an *addition* in its own diff, so
  ## that is what gets replaced. Only additions count: a release commit
  ## legitimately rewrites notes still pending for other packages, and those
  ## must survive. Rebuilding from the message rather than patching it means a
  ## reword that changes the type (`fix:` -> `feat:`) fixes the bump level too.
  var dirty = false
  for path in gitAddedPaths(repoRoot, revision):
    if path.startsWith(ChangesRelPrefix) and path.endsWith(".txt"):
      let notePath = repoRoot / path
      if fileExists(notePath):
        removeFile(notePath)
        dirty = true

  let parseResult = parseCommitMessage(gitCommitMessage(repoRoot, revision))
  if isFailure(parseResult):
    stderr.writeLine("nimver: skipping unparseable commit: " & parseResult.error)
    return dirty

  let maybeLevel = validateAndLookup(cfg, parseResult.value)
  if isFailure(maybeLevel):
    stderr.writeLine("nimver: skipping commit: " & maybeLevel.error)
    return dirty
  if maybeLevel.value == blIgnore:
    return dirty

  let affectedPackages =
    affectedPackageNames(projectWorkspace, gitChangedPaths(repoRoot, revision))
  if affectedPackages.len == 0:
    return dirty

  discard writeChangeFile(
    repoRoot, parseResult.value.commitType, maybeLevel.value,
    parseResult.value.breaking, affectedPackages, parseResult.value.rawMessage,
  )
  true

proc foldNotesIntoHead(repoRoot: string) =
  gitAdd(repoRoot, changesDir(repoRoot))
  putEnv("NIMVER_AMENDING", "1")
  gitAmendNoVerify(repoRoot)

proc cmdRecordCommit(repoRoot: string) =
  ## Runs as the `post-commit` hook. Writes the bump-note file for the
  ## commit that was just created and folds it into that same commit via a
  ## guarded amend (see the `post-commit` hook script for the re-entrancy
  ## guard).
  if isRebaseInProgress(repoRoot):
    # Amending here would fight with the rebase sequencer's own bookkeeping
    # (see `isRebaseInProgress`). The `post-rewrite` hook picks the work up
    # once the rebase has finished.
    return

  let cfg = loadConfig(repoRoot)
  let projectWorkspace = loadWorkspace(repoRoot, cfg)
  if syncNoteForCommit(repoRoot, cfg, projectWorkspace, "HEAD"):
    foldNotesIntoHead(repoRoot)

proc cmdRecordRewrite(repoRoot, rewriteKind: string) =
  ## Runs as the `post-rewrite` hook, once `git rebase` has finished replaying
  ## commits. Git feeds `<old> <new>` pairs on stdin.
  ##
  ## This is where reworded commits get their notes corrected: `post-commit`
  ## fires *during* the rebase, when amending would derail the sequencer. The
  ## corrected notes are folded into HEAD rather than into each rewritten
  ## commit - moving them back would mean rewriting history a second time,
  ## and what a release reads is the set of pending notes, not which commit
  ## carries them.
  if rewriteKind == "amend":
    return # `post-commit` already re-recorded that commit

  let cfg = loadConfig(repoRoot)
  let projectWorkspace = loadWorkspace(repoRoot, cfg)

  var rewrittenRevisions: seq[string] = @[]
  for line in stdin.lines:
    let fields = line.splitWhitespace()
    if fields.len >= 2:
      rewrittenRevisions.add(fields[1])

  var dirty = false
  for revision in rewrittenRevisions:
    if syncNoteForCommit(repoRoot, cfg, projectWorkspace, revision):
      dirty = true

  if dirty:
    foldNotesIntoHead(repoRoot)

proc highestBumpLevel(entries: seq[ChangeEntry]): BumpLevel =
  result = blNone
  for entry in entries:
    if entry.bumpLevel > result:
      result = entry.bumpLevel

proc changelogPathFor(repoRoot: string, package: WorkspacePackage): string =
  ## An independently versioned package keeps its changelog next to its
  ## manifest, since its version moves on its own schedule. Sibling manifests
  ## resolve to the same path and therefore share one changelog.
  if package.rootDirectory.len == 0:
    repoRoot / "CHANGELOG.md"
  else:
    repoRoot / package.rootDirectory / "CHANGELOG.md"

proc changelogPackageLabelFor(
    repoRoot: string, projectWorkspace: Workspace, package: WorkspacePackage
): string =
  ## Packages sharing a changelog have to name themselves in it: a bare version
  ## would not say which of them moved. A package with a changelog of its own
  ## keeps the plain `## [1.2.0]` heading.
  let changelogPath = changelogPathFor(repoRoot, package)
  for other in projectWorkspace.packages:
    if other.name != package.name and changelogPathFor(repoRoot, other) == changelogPath:
      return package.name
  ""

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

type PackageRelease = object
  ## One package's planned release: what it moves to, and the notes that say
  ## so. Planning every package before writing anything keeps a release of
  ## several packages a single commit.
  package: WorkspacePackage
  entries: seq[ChangeEntry]
  current, next: SemVer
  level: BumpLevel
  section: string
  changelogPath: string
  tag: string

proc hasPendingChanges(release: PackageRelease): bool =
  release.entries.len > 0

proc isReleasable(release: PackageRelease): bool =
  ## Pending notes that all say `bump=none` belong in the changelog of some
  ## later release, not in a release of their own.
  release.hasPendingChanges() and release.level != blNone

proc planRelease(
    repoRoot: string,
    projectWorkspace: Workspace,
    package: WorkspacePackage,
    allEntries: seq[ChangeEntry],
): PackageRelease =
  result.package = package
  result.entries =
    allEntries.filterIt(package.name in projectWorkspace.effectivePackages(it))
  result.level = highestBumpLevel(result.entries)
  if not result.isReleasable():
    return

  result.current = readVersion(package.manifest)
  result.next = bump(result.current, result.level)
  result.section = buildSection(
    result.next,
    result.entries,
    changelogPackageLabelFor(repoRoot, projectWorkspace, package),
  )
  result.changelogPath = changelogPathFor(repoRoot, package)
  result.tag = releaseTagFor(projectWorkspace, package, result.next)

type ChangelogWrite = object
  ## One changelog file and everything this run prepends to it. Packages that
  ## share a file are folded into a single write: prepending once per release
  ## would push each section above the one written a moment earlier, so the
  ## file would end up in reverse order.
  path: string
  text: string

proc changelogWrites(releases: seq[PackageRelease]): seq[ChangelogWrite] =
  var writeIndexByPath = initTable[string, int]()
  for release in releases:
    if writeIndexByPath.hasKey(release.changelogPath):
      result[writeIndexByPath[release.changelogPath]].text.add("\n" & release.section)
    else:
      writeIndexByPath[release.changelogPath] = result.len
      result.add(ChangelogWrite(path: release.changelogPath, text: release.section))

proc consumeChangeNotes(projectWorkspace: Workspace, releases: seq[PackageRelease]) =
  ## A note shared by several packages is only spent for the ones being
  ## released. It has to be rewritten once against the whole release set:
  ## rewriting it per package would restore the packages an earlier rewrite in
  ## the same run had already removed, since each release still holds the note
  ## as it was read from disk.
  var releasedNames = initHashSet[string]()
  for release in releases:
    releasedNames.incl(release.package.name)

  var rewrittenPaths = initHashSet[string]()
  for release in releases:
    for entry in release.entries:
      if rewrittenPaths.containsOrIncl(entry.path):
        continue
      entry.rewriteAffectedPackages(
        projectWorkspace.effectivePackages(entry).filterIt(it notin releasedNames)
      )

proc releaseCommitSubject(
    projectWorkspace: Workspace, releases: seq[PackageRelease]
): string =
  ## Releasing several independently versioned packages has no single version
  ## to name, so the subject lists the tags the commit is about to carry.
  if releases.len == 1:
    releaseCommitSubjectFor(projectWorkspace, releases[0].package, releases[0].next)
  else:
    "version: " & releases.mapIt(it.tag).join(", ")

proc bumpIndependentPackages(
    repoRoot: string,
    projectWorkspace: Workspace,
    candidates: seq[WorkspacePackage],
    allEntries: seq[ChangeEntry],
    doCommit, doTag, dryRun: bool,
) =
  ## Releases each of `candidates` that has pending changes, every package to
  ## its own next version, as one commit carrying one tag per package.
  var releases: seq[PackageRelease] = @[]
  var anyPending = false
  for package in candidates:
    let release = planRelease(repoRoot, projectWorkspace, package, allEntries)
    if release.hasPendingChanges():
      anyPending = true
    if release.isReleasable():
      releases.add(release)

  # One order for everything a run emits - changelog sections, progress lines,
  # tags, the commit subject - so releasing the same set of packages reads the
  # same way every time, whatever order the config declares them in.
  releases.sort(
    proc(first, second: PackageRelease): int =
      cmp(first.package.name, second.package.name)
  )

  if releases.len == 0:
    if anyPending:
      echo "All pending changes are non-version-impacting (bump=none). Nothing to bump."
    elif candidates.len == 1:
      echo "No pending changes for package '", candidates[0].name, "'. Nothing to bump."
    else:
      echo "No pending changes for any configured package. Nothing to bump."
    return

  for release in releases:
    echo "Bumping ",
      releaseLabelFor(projectWorkspace, release.package),
      ": ",
      $release.current,
      " -> ",
      $release.next,
      " (",
      $release.level,
      ")"

  if dryRun:
    for release in releases:
      let releaseLabel =
        if releases.len > 1:
          " for " & release.package.name
        else:
          ""
      echo "\n--- CHANGELOG entry", releaseLabel, " (dry run, nothing written) ---"
      echo release.section
    return

  let changelogs = changelogWrites(releases)
  for release in releases:
    writeVersion(release.package.manifest, release.next)
    echo "Updated ",
      release.package.manifest.filePath,
      " (",
      release.package.manifest.displayName(),
      ")"
  for changelog in changelogs:
    prependToChangelog(changelog.path, changelog.text)
    echo "Updated ", changelog.path
  consumeChangeNotes(projectWorkspace, releases)

  if doCommit:
    for release in releases:
      gitAdd(repoRoot, release.package.manifest.filePath)
    for changelog in changelogs:
      gitAdd(repoRoot, changelog.path)
    gitAdd(repoRoot, changesDir(repoRoot))
    gitCommit(repoRoot, releaseCommitSubject(projectWorkspace, releases))
    echo "Created release commit."

  if doTag:
    if not doCommit:
      reportSkippedTag()
    else:
      for release in releases:
        gitTag(repoRoot, release.tag)
        echo "Created tag " & release.tag

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
    # A bare `bump` releases everything that has pending changes; naming a
    # package narrows the release to that one.
    let candidates =
      if requestedPackageName.len > 0:
        @[projectWorkspace.findPackage(requestedPackageName)]
      else:
        projectWorkspace.packages
    bumpIndependentPackages(
      repoRoot, projectWorkspace, candidates, entries, doCommit, doTag, dryRun
    )

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
    of "record-rewrite":
      cmdRecordRewrite(
        repoRoot,
        if args.len > 1:
          args[1]
        else:
          "",
      )
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
