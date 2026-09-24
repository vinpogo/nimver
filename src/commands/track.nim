import std/[algorithm, options, sequtils, strutils, tables]
import ../sysio
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

proc parseArguments(arguments: seq[string]): TrackArguments =
  ## `--package <name>` / `-p <name>` rather than a positional, because
  ## `nimver track enter alpha web` would read as two track names.
  var positional: seq[string] = @[]
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if argument in ["--package", "-p"]:
      if index + 1 >= arguments.len:
        raise newException(IOError, "`" & argument & "` needs a package name")
      result.packageName = some(arguments[index + 1])
      index += 2
      continue
    if argument.startsWith("-"):
      raise
        newException(IOError, "Unknown option '" & argument & "' for `nimver track`")
    positional.add(argument)
    index += 1

  if positional.len > 0:
    result.subcommand = positional[0]
  if positional.len > 2:
    raise newException(
      IOError, "`nimver track " & result.subcommand & "` takes at most one name"
    )
  if positional.len == 2:
    result.trackName = positional[1]

proc tagShape(trackName: string): string =
  if trackName.len > 0:
    "v<version>-" & trackName & ".<n>"
  else:
    "v<version>"

proc reportTracks(selection: TrackSelection) =
  ## Deliberately without loading the workspace: that needs every configured
  ## manifest to be on disk, and saying which track you are on should not
  ## depend on the repository being in one piece.
  if selection.default.len > 0:
    echo "On track '",
      selection.default, "'. Versions are tagged ", tagShape(selection.default), "."
  else:
    echo "Not on a track. Versions are tagged ", tagShape(""), "."

  for packageName in toSeq(selection.byPackage.keys()).sorted():
    let trackName = selection.byPackage[packageName]
    if trackName.len > 0:
      echo "  ", packageName, ": track '", trackName, "', tagged ", tagShape(trackName)
    else:
      echo "  ", packageName, ": not on a track"

proc requireConfigured(repoRoot: string) =
  ## `fileAt` rather than `loadUserConfig`, so a config that is temporarily
  ## broken does not also block changing track.
  if not fileAt(configPath(repoRoot)):
    raise newException(
      IOError,
      "Config not found at " & configPath(repoRoot) & ". Run `nimver init` first.",
    )

proc checkedPackage(repoRoot: string, packageName: string): WorkspacePackage =
  let config = loadUserConfig(repoRoot)
  let projectWorkspace = loadWorkspace(repoRoot, config)
  if projectWorkspace.strategy == wsFixed:
    raise newException(
      IOError,
      "workspace strategy is 'fixed', so every package shares one version and one track. Drop `--package`, or set strategy = independent.",
    )
  projectWorkspace.findPackage(packageName)

proc warnWithoutARelease(repoRoot: string, packageName: Option[string]) =
  ## Entering a track needs a release to measure from, and the manifest stops
  ## being one the moment the first prerelease is written. Said here, while it
  ## is still true and still cheap to fix.
  ##
  ## Advice, not a gate: a repository too broken to read is a problem for
  ## `bump` to report, not for a track switch.
  try:
    let config = loadUserConfig(repoRoot)
    let projectWorkspace = loadWorkspace(repoRoot, config)
    let namespaced =
      projectWorkspace.strategy == wsIndependent and projectWorkspace.packages.len > 1
    for package in projectWorkspace.packages:
      if packageName.isSome and package.name != packageName.get:
        continue
      let naming = newReleaseNaming(package.name, namespaced)
      if pendingChanges(repoRoot, config, naming, vbRelease).boundaryVersion.isNone():
        let tagExample =
          if namespaced:
            "git tag " & package.name & "-v" & $readVersion(package.manifest)
          else:
            "git tag v" & $readVersion(package.manifest)
        writeError(
          "nimver: " & (
            if namespaced:
              "package '" & package.name & "' has"
            else:
              "this repository has"
          ) &
            " no release tag in this branch's history, so a prerelease will have nothing to be based on. Tag the version it is already on: " &
            tagExample
        )
  except CatchableError:
    discard

proc enterTrack(repoRoot: string, arguments: TrackArguments) =
  if arguments.trackName.len == 0:
    raise newException(IOError, "Usage: nimver track enter <name> [--package <name>]")

  let problem = trackNameProblem(arguments.trackName)
  if problem.len > 0:
    raise newException(
      IOError,
      "Invalid track name '" & arguments.trackName & "': a track name " & problem &
        ". It becomes the tag suffix `v1.2.3-" & arguments.trackName &
        ".1` and the track written into the manifest version.",
    )

  var selection = readTracks(repoRoot)
  if arguments.packageName.isSome:
    let package = checkedPackage(repoRoot, arguments.packageName.get)
    if selection.trackFor(package.name).name == arguments.trackName:
      echo "Package '",
        package.name, "' is already on track '", arguments.trackName, "'."
      return
    selection.byPackage[package.name] = arguments.trackName
    writeTracks(repoRoot, selection)
    echo "Package '",
      package.name,
      "' is on track '",
      arguments.trackName,
      "'. Its next bump tags <package>-",
      tagShape(arguments.trackName),
      "."
  else:
    if selection.default == arguments.trackName:
      echo "Already on track '", arguments.trackName, "'."
      return
    selection.default = arguments.trackName
    writeTracks(repoRoot, selection)
    echo "On track '",
      arguments.trackName, "'. The next bump tags ", tagShape(arguments.trackName), "."

  warnWithoutARelease(repoRoot, arguments.packageName)
  echo "Commit ", TrackRelPath, " so CI releases on the same track."

proc exitTrack(repoRoot: string, arguments: TrackArguments) =
  if arguments.trackName.len > 0:
    raise newException(IOError, "Usage: nimver track exit [--package <name>]")

  var selection = readTracks(repoRoot)
  if arguments.packageName.isSome:
    let package = checkedPackage(repoRoot, arguments.packageName.get)
    # Written as an empty override rather than removed: with a repo-wide
    # default standing, removing the line would put the package back on it.
    selection.byPackage[package.name] = ""
    writeTracks(repoRoot, selection)
    echo "Package '",
      package.name,
      "' is off the track. Its next bump tags <package>-",
      tagShape(""),
      "."
  else:
    if not selection.anyTrack() and not fileAt(trackPath(repoRoot)):
      echo "Not on a track. Versions are tagged ", tagShape(""), "."
      return
    clearTracks(repoRoot)
    echo "Off the track. The next bump tags ", tagShape(""), "."

  echo "Commit ", TrackRelPath, " so CI releases the same way."

proc cmdTrack*(repoRoot: string, arguments: seq[string]) =
  let parsed = parseArguments(arguments)
  case parsed.subcommand
  of "":
    reportTracks(readTracks(repoRoot))
  of "enter":
    requireConfigured(repoRoot)
    enterTrack(repoRoot, parsed)
  of "exit":
    requireConfigured(repoRoot)
    exitTrack(repoRoot, parsed)
  else:
    raise newException(
      IOError,
      "Unknown track command '" & parsed.subcommand & "'. Expected enter or exit.",
    )
