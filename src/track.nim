## Which track each package is on, as the working tree has it.
##
## Read from `.nimver/track`, never from history: a track is a property of the
## version being cut now, not of the commits behind it. The same commit
## legitimately goes out in `alpha.1`, in `alpha.2` and in the release that
## follows them, so "which track was this commit on" has no answer. What each
## past version *was* cut on is recorded already, in the tag names.

import std/[algorithm, sequtils, strutils, tables]
import ./sysio
import ./config
import ./semver

type
  Track* = object
    name*: string ## Empty means no track.

  TrackSelection* = object
    ## A `fixed` workspace has one version and therefore one track, so only
    ## `default` is ever set for it. An independent one can put its packages on
    ## different tracks, or take one off while the rest stay on.
    default*: string
    byPackage*: Table[string, string]
      ## Presence is an override; an empty value means explicitly off the track.

const
  TrackFileName* = "track"
  TrackRelPath* = ConfigDir / TrackFileName

func noTrack*(): Track =
  Track(name: "")

func hasTrack*(track: Track): bool =
  track.name.len > 0

func trackFor*(selection: TrackSelection, packageName: string): Track =
  ## An override wins, then the default, then no track.
  if packageName in selection.byPackage:
    Track(name: selection.byPackage[packageName])
  else:
    Track(name: selection.default)

func anyTrack*(selection: TrackSelection): bool =
  if selection.default.len > 0:
    return true
  for _, name in selection.byPackage:
    if name.len > 0:
      return true
  false

func trackNameProblem*(name: string): string =
  ## What is wrong with a track name, phrased to follow "a track name ...".
  ## Empty when nothing is.
  ##
  ## Letters alone, and everything else follows: no `.` to make
  ## `v1.2.0-rc.2.1` ambiguous about where the track ends and the iteration
  ## begins, nothing `git check-ref-format` refuses, and nothing npm would read
  ## as a version when the name doubles as a dist-tag.
  if name.len == 0:
    return "must not be empty"
  if not name.allCharsInSet(TrackNameChars):
    return "may only contain letters"
  ""

proc trackPath*(repoRoot: string): string =
  repoRoot / TrackRelPath

proc parseTrackSelection*(contents, path: string): TrackSelection =
  ## A line with no `=` is the default track; `<package> = <track>` overrides
  ## one package, and an empty value takes it off. Blank lines and `;`/`#`
  ## comments are ignored.
  var sawDefault = false
  for rawLine in contents.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line[0] in {';', '#'}:
      continue

    let equals = line.find('=')
    if equals == -1:
      if sawDefault:
        raise newException(
          IOError,
          "More than one default track in " & path & ": '" & line & "'. Write `" & line &
            "` once for every package, or `<package> = " & line & "` for one of them.",
        )
      let problem = trackNameProblem(line)
      if problem.len > 0:
        raise newException(
          IOError,
          "Invalid track name '" & line & "' in " & path & ": a track name " & problem &
            ".",
        )
      result.default = line
      sawDefault = true
      continue

    let packageName = line[0 ..< equals].strip()
    let trackName = line[equals + 1 .. ^1].strip()
    if packageName.len == 0:
      raise newException(
        IOError,
        "Missing package name in " & path & ": '" & line &
          "'. Write `<package> = <track>`, or the track on its own for every package.",
      )
    if trackName.len > 0:
      let problem = trackNameProblem(trackName)
      if problem.len > 0:
        raise newException(
          IOError,
          "Invalid track name '" & trackName & "' for package '" & packageName & "' in " &
            path & ": a track name " & problem & ".",
        )
    result.byPackage[packageName] = trackName

proc readTracks*(repoRoot: string): TrackSelection =
  ## A missing or empty file means no package is on a track.
  let path = trackPath(repoRoot)
  if not fileAt(path):
    return TrackSelection()
  parseTrackSelection(readFileContents(path), path)

func renderTrackSelection*(selection: TrackSelection): string =
  ## Sorted, because this file is committed: a table's own order would reshuffle
  ## the diff every time anything about it changed.
  if selection.default.len > 0:
    result.add(selection.default & "\n")
  for packageName in toSeq(selection.byPackage.keys()).sorted():
    let trackName = selection.byPackage[packageName]
    if trackName.len > 0:
      result.add(packageName & " = " & trackName & "\n")
    else:
      result.add(packageName & " =\n")

proc writeTracks*(repoRoot: string, selection: TrackSelection) =
  let path = trackPath(repoRoot)
  makeDirectory(path.parentDir())
  writeFileContents(path, renderTrackSelection(selection))

proc clearTracks*(repoRoot: string) =
  ## Deleting rather than writing an empty file: absence is what "no track"
  ## means, and a file holding nothing would read as something half-said.
  let path = trackPath(repoRoot)
  if fileAt(path):
    deleteFile(path)
