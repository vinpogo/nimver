import std/[algorithm, options, sequtils, strutils, tables]
import ../sysio
import results
import ../effects
import ../config
import ../track
import ../history
import ../semver
import ../workspace
import ../adapters/manifest

type TrackArguments = object
  subcommand: string
  trackName: string
  packageName: Option[string]
  stable: bool

proc parseArguments(arguments: seq[string]): Result[TrackArguments, string] =
  ## `--package <name>` / `-p <name>` rather than a positional, because
  ## `nimver track enter alpha web` would read as two track names.
  var parsed: TrackArguments
  var positional: seq[string] = @[]
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if argument in ["--package", "-p"]:
      if index + 1 >= arguments.len:
        return err("`" & argument & "` needs a package name")
      parsed.packageName = some(arguments[index + 1])
      index += 2
      continue
    if argument == "--stable":
      parsed.stable = true
      index += 1
      continue
    if argument.startsWith("-"):
      return err("Unknown option '" & argument & "' for `nimver track`")
    positional.add(argument)
    index += 1

  if positional.len > 0:
    parsed.subcommand = positional[0]
  if positional.len > 2:
    return err("`nimver track " & parsed.subcommand & "` takes at most one name")
  if positional.len == 2:
    parsed.trackName = positional[1]
  ok(parsed)

proc tagShape(trackName: string): string =
  if trackName.len > 0:
    "v<version>-" & trackName & ".<n>"
  else:
    "v<version>"

proc promotionNote(track: Track): string =
  ## True whether or not the marker has already been spent, which is what lets
  ## this report keep its rule of reading nothing but the track file.
  if track.promotesToStable:
    ", entered with --stable: the first version cut below 1.0.0 is 1.0.0 itself"
  else:
    ""

proc reportTracks(selection: TrackSelection): Effects =
  ## Deliberately without loading the workspace: that needs every configured
  ## manifest to be on disk, and saying which track you are on should not
  ## depend on the repository being in one piece.
  if selection.default.hasTrack():
    result.add(
      say(
        "On track '" & selection.default.name & "'. Versions are tagged " &
          tagShape(selection.default.name) & promotionNote(selection.default) & "."
      )
    )
  else:
    result.add(say("Not on a track. Versions are tagged " & tagShape("") & "."))

  for packageName in toSeq(selection.byPackage.keys()).sorted():
    let track = selection.byPackage[packageName]
    if track.hasTrack():
      result.add(
        say(
          "  " & packageName & ": track '" & track.name & "', tagged " &
            tagShape(track.name) & promotionNote(track)
        )
      )
    else:
      result.add(say("  " & packageName & ": not on a track"))

proc requireConfigured(repoRoot: string): Result[void, string] =
  ## `fileAt` rather than `loadUserConfig`, so a config that is temporarily
  ## broken does not also block changing track.
  if not fileAt(configPath(repoRoot)):
    return
      err("Config not found at " & configPath(repoRoot) & ". Run `nimver init` first.")
  ok()

proc checkedPackage(
    repoRoot: string, packageName: string, effects: var Effects
): Result[WorkspacePackage, string] =
  let config = ?loadUserConfig(repoRoot)
  let projectWorkspace = ?loadWorkspace(repoRoot, config, effects)
  if projectWorkspace.strategy == wsFixed:
    return err(
      "workspace strategy is 'fixed', so every package shares one version and one track. Drop `--package`, or set strategy = independent."
    )
  projectWorkspace.findPackage(packageName)

proc warnWithoutARelease(
    repoRoot: string, packageName: Option[string], effects: var Effects
): Result[void, string] =
  ## Entering a track needs a release to measure from, and the manifest stops
  ## being one the moment the first prerelease is written. Said here, while it
  ## is still true and still cheap to fix.
  ##
  ## Advice, not a gate: a repository too broken to read is a problem for
  ## `bump` to report, not for a track switch, so the caller lets a failure go.
  let config = ?loadUserConfig(repoRoot)
  let projectWorkspace = ?loadWorkspace(repoRoot, config, effects)
  let namespaced =
    projectWorkspace.strategy == wsIndependent and projectWorkspace.packages.len > 1
  for package in projectWorkspace.packages:
    if packageName.isSome and package.name != packageName.get:
      continue
    let naming = newReleaseNaming(package.name, namespaced)
    let sinceRelease = ?pendingChanges(repoRoot, config, naming, effects, vbRelease)
    if sinceRelease.boundaryVersion.isNone():
      let tagExample =
        if namespaced:
          "git tag " & package.name & "-v" & $(?readVersion(package.manifest))
        else:
          "git tag v" & $(?readVersion(package.manifest))
      effects.add(
        warn(
          "nimver: " & (
            if namespaced:
              "package '" & package.name & "' has"
            else:
              "this repository has"
          ) &
            " no release tag in this branch's history, so a prerelease will have nothing to be based on. Tag the version it is already on: " &
            tagExample
        )
      )
  ok()

proc enterTrack(
    repoRoot: string, arguments: TrackArguments, effects: var Effects
): Result[void, string] =
  if arguments.trackName.len == 0:
    return err("Usage: nimver track enter <name> [--package <name>]")

  let problem = trackNameProblem(arguments.trackName)
  if problem.len > 0:
    return err(
      "Invalid track name '" & arguments.trackName & "': a track name " & problem &
        ". It becomes the tag suffix `v1.2.3-" & arguments.trackName &
        ".1` and the track written into the manifest version."
    )

  # The whole track is compared, not just its name: `enter rc --stable` while
  # already on a plain `rc` has something to record, and `enter rc` after it
  # takes the promise back.
  let entering = Track(name: arguments.trackName, promotesToStable: arguments.stable)

  var selection = ?readTracks(repoRoot)
  if arguments.packageName.isSome:
    let package = ?checkedPackage(repoRoot, arguments.packageName.get, effects)
    if selection.trackFor(package.name) == entering:
      effects.add(
        say(
          "Package '" & package.name & "' is already on track '" & arguments.trackName &
            "'."
        )
      )
      return ok()
    selection.byPackage[package.name] = entering
    effects.add(trackEffects(repoRoot, selection))
    effects.add(
      say(
        "Package '" & package.name & "' is on track '" & arguments.trackName &
          "'. Its next bump tags <package>-" & tagShape(arguments.trackName) & "."
      )
    )
  else:
    if selection.default == entering:
      effects.add(say("Already on track '" & arguments.trackName & "'."))
      return ok()
    selection.default = entering
    effects.add(trackEffects(repoRoot, selection))
    effects.add(
      say(
        "On track '" & arguments.trackName & "'. The next bump tags " &
          tagShape(arguments.trackName) & "."
      )
    )

  if arguments.stable:
    effects.add(
      say(
        "Entered with --stable: the first version cut on this track is 1.0.0, so no further flag is needed."
      )
    )
  discard warnWithoutARelease(repoRoot, arguments.packageName, effects)
  effects.add(say("Commit " & TrackRelPath & " so CI releases on the same track."))
  ok()

proc exitTrack(
    repoRoot: string, arguments: TrackArguments, effects: var Effects
): Result[void, string] =
  if arguments.trackName.len > 0:
    return err("Usage: nimver track exit [--package <name>]")
  if arguments.stable:
    return err(
      "`--stable` says which version the next bump cuts, and `track exit` cuts none. Drop it, or run `nimver bump --stable` when you are ready for 1.0.0."
    )

  var selection = ?readTracks(repoRoot)
  if arguments.packageName.isSome:
    let package = ?checkedPackage(repoRoot, arguments.packageName.get, effects)
    # Written as an empty override rather than removed: with a repo-wide
    # default standing, removing the line would put the package back on it.
    selection.byPackage[package.name] = noTrack()
    effects.add(trackEffects(repoRoot, selection))
    effects.add(
      say(
        "Package '" & package.name & "' is off the track. Its next bump tags <package>-" &
          tagShape("") & "."
      )
    )
  else:
    if not selection.anyTrack() and not fileAt(trackPath(repoRoot)):
      effects.add(say("Not on a track. Versions are tagged " & tagShape("") & "."))
      return ok()
    effects.add(clearTrackEffects(repoRoot))
    effects.add(say("Off the track. The next bump tags " & tagShape("") & "."))

  effects.add(say("Commit " & TrackRelPath & " so CI releases the same way."))
  ok()

proc cmdTrack*(
    repoRoot: string, arguments: seq[string], effects: var Effects
): Result[void, string] =
  let parsed = ?parseArguments(arguments)
  case parsed.subcommand
  of "":
    if parsed.stable:
      return err(
        "`--stable` belongs on `nimver track enter <name>`; `nimver track` only says which track you are on."
      )
    effects.add(reportTracks(?readTracks(repoRoot)))
    ok()
  of "enter":
    ?requireConfigured(repoRoot)
    enterTrack(repoRoot, parsed, effects)
  of "exit":
    ?requireConfigured(repoRoot)
    exitTrack(repoRoot, parsed, effects)
  else:
    return
      err("Unknown track command '" & parsed.subcommand & "'. Expected enter or exit.")
