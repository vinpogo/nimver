import std/[algorithm, options, sequtils]
import ../config
import ../sysio
import ../adapters/manifest
import ../changelog
import ../semver
import ../track
import ../workspace
import ../gitutils
import ../release

proc plannedReleases(
    repoRoot: string,
    projectWorkspace: Workspace,
    currentConfig: NimverConfig,
    requestedPackageName: Option[string],
    tracks: TrackSelection,
): seq[PackageRelease] =
  ## Every release the strategy would consider, releasable or not, so that
  ## having nothing to bump can still be reported in the caller's terms.
  case projectWorkspace.strategy
  of wsFixed:
    if requestedPackageName.isSome:
      raise newException(
        IOError,
        "workspace strategy is 'fixed', so `nimver bump` releases every package at once. Drop the package argument, or set strategy = independent.",
      )
    # One version across every manifest, so one track: the repository-wide one.
    @[
      planFixedRelease(
        repoRoot, projectWorkspace, currentConfig, Track(name: tracks.default)
      )
    ]
  of wsIndependent:
    # A bare `bump` releases everything that has pending changes; naming a
    # package narrows the release to that one.
    let candidates =
      if requestedPackageName.isSome:
        @[projectWorkspace.findPackage(requestedPackageName.get)]
      else:
        projectWorkspace.packages
    candidates.mapIt(
      planRelease(
        repoRoot, projectWorkspace, currentConfig, it, tracks.trackFor(it.name)
      )
    )

proc nothingToBumpReason(planned: seq[PackageRelease]): string =
  if planned.anyIt(it.hasPendingChanges()):
    "All pending changes are non-version-impacting (bump=none)."
  elif planned.len != 1:
    "No pending changes for any configured package."
  elif planned[0].name.len > 0:
    "No pending changes for package '" & planned[0].name & "'."
  else:
    "No changes since the last release."

proc reportPlanned(projectWorkspace: Workspace, releases: seq[PackageRelease]) =
  for release in releases:
    echo "Bumping ",
      releaseLabelFor(projectWorkspace, release),
      ": ",
      $release.current,
      " -> ",
      $release.next,
      " (",
      $release.level,
      ")"

proc reportDryRun(releases: seq[PackageRelease]) =
  for release in releases:
    let releaseLabel =
      if releases.len > 1:
        " for " & release.name
      else:
        ""
    echo "\nWould tag ", release.tag
    echo "--- CHANGELOG entry", releaseLabel, " (dry run, nothing written) ---"
    echo release.section

proc warnAboutTracks(tracks: TrackSelection, projectWorkspace: Workspace) =
  ## Said before anything is planned, so it is there whether the run goes on to
  ## release, to find nothing to bump, or to refuse for want of a release to
  ## build on.
  if not tracks.anyTrack():
    return

  proc advice(trackName: string): string =
    " These are prereleases: the tag and the manifest version both carry `-" & trackName &
      ".<n>`. Run `nimver track exit` to come off the track."

  let onDefault =
    projectWorkspace.packages.allIt(tracks.trackFor(it.name).name == tracks.default)
  if onDefault and tracks.default.len > 0:
    writeError(
      "nimver: releasing on track '" & tracks.default & "'." & advice(tracks.default)
    )
    return

  for package in projectWorkspace.packages:
    let trackName = tracks.trackFor(package.name).name
    if trackName.len > 0:
      writeError(
        "nimver: releasing " & package.name & " on track '" & trackName & "'." &
          advice(trackName)
      )

proc checkTagsAreFree(repoRoot: string, releases: seq[PackageRelease]) =
  ## Before a line of it is written. `applyReleases` tags last, so a name `git
  ## tag` already knows would fail after the manifests were moved and the
  ## release commit made, leaving the two out of step.
  for release in releases:
    if tagExists(repoRoot, release.tag):
      raise newException(
        IOError,
        "tag " & release.tag &
          " already exists. Delete it, or release from a branch that has not used it.",
      )

proc applyReleases(
    repoRoot: string, projectWorkspace: Workspace, releases: seq[PackageRelease]
) =
  let changelogs = changelogWrites(releases)
  for release in releases:
    for manifest in release.manifests:
      writeVersion(manifest, release.next)
      echo "Updated ", manifest.filePath, " (", manifest.displayName(), ")"
  for changelog in changelogs:
    prependToChangelog(changelog.path, changelog.text)
    echo "Updated ", changelog.path

  for release in releases:
    for manifest in release.manifests:
      gitAdd(repoRoot, manifest.filePath)
  for changelog in changelogs:
    gitAdd(repoRoot, changelog.path)
  gitCommit(repoRoot, releaseCommitSubject(projectWorkspace, releases))
  echo "Created release commit."

  for release in releases:
    gitTag(repoRoot, release.tag)
    echo "Created tag " & release.tag

proc cmdBump*(repoRoot: string, requestedPackageName: Option[string], dryRun: bool) =
  let config = loadUserConfig(repoRoot)
  let tracks = readTracks(repoRoot)
  let projectWorkspace = loadWorkspace(repoRoot, config)
  warnAboutTracks(tracks, projectWorkspace)
  let planned =
    plannedReleases(repoRoot, projectWorkspace, config, requestedPackageName, tracks)

  # One order for everything a run emits - changelog sections, progress lines,
  # tags, the commit subject - so releasing the same set of packages reads the
  # same way every time, whatever order the config declares them in.
  let releases = planned.filterIt(it.isReleasable()).sortedByIt(it.name)
  if releases.len == 0:
    echo nothingToBumpReason(planned), " Nothing to bump."
    return

  reportPlanned(projectWorkspace, releases)
  if dryRun:
    reportDryRun(releases)
    return
  checkTagsAreFree(repoRoot, releases)
  applyReleases(repoRoot, projectWorkspace, releases)
