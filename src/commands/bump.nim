import std/[algorithm, options, sequtils]
import results
import ../config
import ../sysio
import ../effects
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
    promoteToStable: bool,
    effects: var Effects,
): Result[seq[PackageRelease], string] =
  ## Every release the strategy would consider, releasable or not, so that
  ## having nothing to bump can still be reported in the caller's terms.
  case projectWorkspace.strategy
  of wsFixed:
    if requestedPackageName.isSome:
      return err(
        "workspace strategy is 'fixed', so `nimver bump` releases every package at once. Drop the package argument, or set strategy = independent."
      )
    # One version across every manifest, so one track: the repository-wide one.
    ok(
      @[
        ?planFixedRelease(
          repoRoot, projectWorkspace, currentConfig, effects, tracks.default,
          promoteToStable,
        )
      ]
    )
  of wsIndependent:
    # A bare `bump` releases everything that has pending changes; naming a
    # package narrows the release to that one.
    let candidates =
      if requestedPackageName.isSome:
        @[?projectWorkspace.findPackage(requestedPackageName.get)]
      else:
        projectWorkspace.packages
    var planned: seq[PackageRelease] = @[]
    for candidate in candidates:
      planned.add(
        ?planRelease(
          repoRoot,
          projectWorkspace,
          currentConfig,
          candidate,
          effects,
          tracks.trackFor(candidate.name),
          promoteToStable,
        )
      )
    ok(planned)

proc nothingToBumpReason(planned: seq[PackageRelease]): string =
  if planned.anyIt(it.hasPendingChanges()):
    "All pending changes are non-version-impacting (bump=none)."
  elif planned.len != 1:
    "No pending changes for any configured package."
  elif planned[0].name.len > 0:
    "No pending changes for package '" & planned[0].name & "'."
  else:
    "No changes since the last release."

proc reportPlanned(
    projectWorkspace: Workspace, releases: seq[PackageRelease]
): Effects =
  for release in releases:
    result.add(
      say(
        "Bumping " & releaseLabelFor(projectWorkspace, release) & ": " & $release.current &
          " -> " & $release.next & " (" & release.bumpReason() & ")"
      )
    )

proc reportDryRun(releases: seq[PackageRelease]): Effects =
  for release in releases:
    let releaseLabel =
      if releases.len > 1:
        " for " & release.name
      else:
        ""
    result.add(say("\nWould tag " & release.tag))
    result.add(
      say("--- CHANGELOG entry" & releaseLabel & " (dry run, nothing written) ---")
    )
    result.add(say(release.section))

proc warnAboutTracks(tracks: TrackSelection, projectWorkspace: Workspace): Effects =
  ## Said before anything is planned, so it is there whether the run goes on to
  ## release, to find nothing to bump, or to refuse for want of a release to
  ## build on.
  if not tracks.anyTrack():
    return

  proc advice(track: Track): string =
    result =
      " These are prereleases: the tag and the manifest version both carry `-" &
      track.name & ".<n>`."
    if track.promotesToStable:
      result.add(
        " The track was entered with `--stable`, so the first version it cuts below 1.0.0 is 1.0.0 itself."
      )
    result.add(" Run `nimver track exit` to come off the track.")

  let onDefault =
    projectWorkspace.packages.allIt(tracks.trackFor(it.name) == tracks.default)
  if onDefault and tracks.default.hasTrack():
    return @[
      warn(
        "nimver: releasing on track '" & tracks.default.name & "'." &
          advice(tracks.default)
      )
    ]

  for package in projectWorkspace.packages:
    let track = tracks.trackFor(package.name)
    if track.hasTrack():
      result.add(
        warn(
          "nimver: releasing " & package.name & " on track '" & track.name & "'." &
            advice(track)
        )
      )

proc checkTagsAreFree(
    repoRoot: string, releases: seq[PackageRelease]
): Result[void, string] =
  ## Before a line of it is written. `releaseEffects` tags last, so a name `git
  ## tag` already knows would fail after the manifests were moved and the
  ## release commit made, leaving the two out of step.
  for release in releases:
    if ?tagExists(repoRoot, release.tag):
      return err(
        "tag " & release.tag &
          " already exists. Delete it, or release from a branch that has not used it."
      )
  ok()

proc stagedPath(repoRoot, path: string): Result[string, string] =
  ## The file a link leads to, so that what was written through the link is
  ## committed. Git refuses a file outside the repository, so a link out of it
  ## is staged as itself.
  if not fileAt(path):
    return ok(path)
  let target = ?resolvedPath(path)
  if target.isRelativeTo(?resolvedPath(repoRoot)):
    ok(target)
  else:
    ok(path)

proc releaseEffects(
    repoRoot: string, projectWorkspace: Workspace, releases: seq[PackageRelease]
): Result[Effects, string] =
  ## Every file's new contents are worked out before anything is queued, so a
  ## manifest that cannot be rewritten fails the run before it changes anything.
  var manifestWrites: seq[(ProjectManifest, string)] = @[]
  for release in releases:
    for manifest in release.manifests:
      manifestWrites.add((manifest, ?versionWritten(manifest, release.next)))
  var changelogContents: seq[(string, string)] = @[]
  for changelog in changelogWrites(releases):
    let existing =
      if fileAt(changelog.path):
        some(?readFileContents(changelog.path))
      else:
        none(string)
    changelogContents.add((changelog.path, withSection(existing, changelog.text)))
  var stagedPaths: seq[string] = @[]
  for (manifest, _) in manifestWrites:
    stagedPaths.add(?stagedPath(repoRoot, manifest.filePath))
  for (path, _) in changelogContents:
    stagedPaths.add(?stagedPath(repoRoot, path))

  var effects: Effects = @[]
  for (manifest, contents) in manifestWrites:
    effects.add(writeTo(manifest.filePath, contents))
    effects.add(
      say("Updated " & manifest.filePath & " (" & manifest.displayName() & ")")
    )
  for (path, contents) in changelogContents:
    effects.add(writeTo(path, contents))
    effects.add(say("Updated " & path))

  for path in stagedPaths:
    effects.add(stage(repoRoot, path))
  effects.add(commit(repoRoot, releaseCommitSubject(projectWorkspace, releases)))
  effects.add(say("Created release commit."))

  for release in releases:
    effects.add(tag(repoRoot, release.tag))
    effects.add(say("Created tag " & release.tag))
  ok(effects)

proc cmdBump*(
    repoRoot: string,
    requestedPackageName: Option[string],
    dryRun: bool,
    promoteToStable: bool,
    effects: var Effects,
): Result[void, string] =
  let config = ?loadUserConfig(repoRoot)
  let tracks = ?readTracks(repoRoot)
  let projectWorkspace = ?loadWorkspace(repoRoot, config, effects)
  effects.add(warnAboutTracks(tracks, projectWorkspace))
  let planned = ?plannedReleases(
    repoRoot, projectWorkspace, config, requestedPackageName, tracks, promoteToStable,
    effects,
  )

  # One order for everything a run emits - changelog sections, progress lines,
  # tags, the commit subject - so releasing the same set of packages reads the
  # same way every time, whatever order the config declares them in.
  let releases = planned.filterIt(it.isReleasable()).sortedByIt(it.name)
  if releases.len == 0:
    effects.add(say(nothingToBumpReason(planned) & " Nothing to bump."))
    return ok()

  effects.add(reportPlanned(projectWorkspace, releases))
  if dryRun:
    effects.add(reportDryRun(releases))
    return ok()
  ?checkTagsAreFree(repoRoot, releases)
  effects.add(?releaseEffects(repoRoot, projectWorkspace, releases))
  ok()
