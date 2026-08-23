import std/[os, algorithm, options]
import ../config
import ../changes
import ../history
import ../adapters/manifest
import ../changelog
import ../semver
import ../workspace
import ../gitutils
import ../release

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

proc bumpIndependentPackages(
    repoRoot: string,
    projectWorkspace: Workspace,
    candidates: seq[WorkspacePackage],
    currentConfig: NimverConfig,
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

proc cmdBump*(repoRoot: string, requestedPackageName: Option[string], dryRun: bool) =
  let config = loadUserConfig(repoRoot)
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
    # When there is exactly one package we know its name and can also
    # recognise its old namespaced tags as boundaries, in case the workspace
    # previously had several packages and has since been reduced to one.
    let survivingName =
      if projectWorkspace.packages.len == 1:
        projectWorkspace.packages[0].name
      else:
        ""
    let entries = pendingChanges(
      repoRoot, config, newReleaseNaming(survivingName, namespaced = false)
    )
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
