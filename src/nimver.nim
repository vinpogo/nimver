## nimver: semantic versioning for Nim projects, driven by
## Conventional Commits and wired into Git via a `commit-msg` hook.

import std/[os, strutils, sequtils, algorithm, tables, options]
import ./gitutils
import ./config
import ./changes
import ./history
import ./adapters/manifest
import ./changelog
import ./semver
import ./workspace
import ./commands/init
import ./commands/version
import ./commands/installHooks
import ./commands/checkCommitMsg

const Usage = """
nimver - semantic versioning from Conventional Commits

Usage:
  nimver init
  nimver install-hooks [--force]
  nimver bump [<package>] [--dry-run]
  nimver version

See https://github.com/vinpogo/nimver for details.

"""

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

proc releaseNamingFor(
    projectWorkspace: Workspace, package: WorkspacePackage
): ReleaseNaming =
  ## How this package's releases are named, which is how reading history back
  ## finds the last of them. Mirrors `releaseTagFor` and
  ## `releaseCommitSubjectFor` - change those and this has to follow, or a
  ## release stops recognising its own predecessor.
  newReleaseNaming(package.name, projectWorkspace.hasSeveralPackages())

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
    dryRun: bool,
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
  for package in projectWorkspace.packages:
    echo "Updated ",
      package.manifest.filePath, " (", package.manifest.displayName(), ")"
  echo "Updated ", changelogPath

  for package in projectWorkspace.packages:
    gitAdd(repoRoot, package.manifest.filePath)
  gitAdd(repoRoot, changelogPath)
  gitCommit(repoRoot, "version: v" & $next)
  echo "Created release commit."

  gitTag(repoRoot, "v" & $next)
  echo "Created tag v" & $next

type PackageRelease = object
  ## One package's planned release: what it moves to, and the changes that say
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
  ## Pending changes that all map to `none` belong in the changelog of some
  ## later release, not in a release of their own.
  release.hasPendingChanges() and release.level != blNone

proc planRelease(
    repoRoot: string,
    projectWorkspace: Workspace,
    currentConfig: Config,
    package: WorkspacePackage,
): PackageRelease =
  ## Every package reads its own stretch of history, ending at its own last
  ## release. A change touching two packages is therefore counted once for
  ## each, however far apart the two last went out - which is the whole point
  ## of releasing them independently.
  result.package = package
  result.entries = pendingChanges(
      repoRoot, currentConfig, releaseNamingFor(projectWorkspace, package)
    )
    .filterIt(package.name in it.affectedPackages)
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
    currentConfig: Config,
    dryRun: bool,
) =
  ## Releases each of `candidates` that has pending changes, every package to
  ## its own next version, as one commit carrying one tag per package.
  var releases: seq[PackageRelease] = @[]
  var anyPending = false
  for package in candidates:
    let release = planRelease(repoRoot, projectWorkspace, currentConfig, package)
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

  for release in releases:
    gitAdd(repoRoot, release.package.manifest.filePath)
  for changelog in changelogs:
    gitAdd(repoRoot, changelog.path)
  gitCommit(repoRoot, releaseCommitSubject(projectWorkspace, releases))
  echo "Created release commit."

  for release in releases:
    gitTag(repoRoot, release.tag)
    echo "Created tag " & release.tag

proc cmdBump(repoRoot: string, requestedPackageName: Option[string], dryRun: bool) =
  let config = loadConfig(repoRoot)
  let projectWorkspace = loadWorkspace(repoRoot, config)

  case projectWorkspace.strategy
  of wsFixed:
    if requestedPackageName.isSome:
      raise newException(
        IOError,
        "workspace strategy is 'fixed', so `nimver bump` releases every package at once. Drop the package argument, or set strategy = independent.",
      )
    # One version for the whole repository, so one stretch of history behind
    # it: everything since the release that last moved that version.
    let entries =
      pendingChanges(repoRoot, config, newReleaseNaming("", namespaced = false))
    if entries.len == 0:
      echo "No changes since the last release. Nothing to bump."
      return
    bumpFixedWorkspace(repoRoot, projectWorkspace, entries, dryRun)
  of wsIndependent:
    # A bare `bump` releases everything that has pending changes; naming a
    # package narrows the release to that one.
    let candidates =
      if requestedPackageName.isSome:
        @[projectWorkspace.findPackage(requestedPackageName.get)]
      else:
        projectWorkspace.packages
    bumpIndependentPackages(repoRoot, projectWorkspace, candidates, config, dryRun)

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
    of "bump":
      let nonFlagArgs = args[1 ..^ 1].filterIt(not it.startsWith("--"))
      if nonFlagArgs.len > 1:
        stderr.writeLine("nimver: `bump` takes at most one package name")
        quit(1)
      let requestedPackageName =
        if nonFlagArgs.len > 0:
          some(nonFlagArgs[0])
        else:
          none(string)
      cmdBump(repoRoot, requestedPackageName, "--dry-run" in args)
    else:
      echo Usage
      quit(1)
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)
