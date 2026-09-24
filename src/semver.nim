## Minimal semantic version (major.minor.patch) parsing and bumping, plus the
## track a prerelease is cut on.
##
## Terminology, used throughout nimver: a *version* is anything `bump` tags; a
## *release* is a version with no track; a *prerelease* is a version with one.

import std/strutils

type
  BumpLevel* = enum
    blIgnore
    blNone
    blPatch
    blMinor
    blMajor

  SemVer* = object
    major*, minor*, patch*: int
    track*: string ## Empty for a release; `alpha` for a prerelease.
    iteration*: int ## 0 for a release; 1-based within a track.

const TrackNameChars* = {'a' .. 'z', 'A' .. 'Z'}
  ## A track is spelled into a git tag and into the version a manifest carries,
  ## so letters alone keep it out of trouble: nothing to confuse with the `.`
  ## before the iteration, nothing `git check-ref-format` refuses, and nothing
  ## npm would read as a version when it doubles as a dist-tag.

proc `$`*(v: SemVer): string =
  result = $v.major & "." & $v.minor & "." & $v.patch
  if v.track.len > 0:
    result.add("-" & v.track & "." & $v.iteration)

func isPrerelease*(v: SemVer): bool =
  v.track.len > 0

func core*(v: SemVer): SemVer =
  ## The version without its track - what the release it is building towards
  ## will be called.
  SemVer(major: v.major, minor: v.minor, patch: v.patch)

func onTrack*(v: SemVer, track: string, iteration: int): SemVer =
  SemVer(
    major: v.major, minor: v.minor, patch: v.patch, track: track, iteration: iteration
  )

const FirstStableVersion* = SemVer(major: 1, minor: 0, patch: 0)
  ## What a promotion cuts, exactly. Bumping any 0.x by a major lands here
  ## anyway; naming it keeps the promotion honest when the base has been
  ## hand-edited out from under it.

func isStable*(v: SemVer): bool =
  ## Whether the version makes the promises semver makes for a released
  ## package. Below 1.0.0 there are none: `^0.4.2` lets a consumer take 0.4.3
  ## and no further, so 0.4 to 0.5 is already the break that 1.x spells as a
  ## major.
  ##
  ## Read off the core, so `1.0.0-rc.1` is already stable. That is what makes a
  ## promotion stick across the iterations of a track.
  v.major > 0

func heldBelowStable*(level: BumpLevel, current: SemVer): BumpLevel =
  ## The level a bump is actually cut at. Below 1.0.0 every one is held a notch
  ## down - a major takes the minor, a minor the patch - which is what `^0.x`
  ## already means to npm and to cargo. On the level rather than on the commit
  ## type, so it follows whatever the types are configured to mean. Patch is the
  ## floor: held any lower, a release with changes in it would have nothing left
  ## to cut.
  if current.isStable():
    return level
  case level
  of blMajor: blMinor
  of blMinor: blPatch
  else: level

func parseTrackSuffix(suffix: string): tuple[track: string, iteration: int] =
  ## `alpha.9` as we write it, or nothing recognisable. Anything else - a
  ## hand-written `SNAPSHOT`, an `rc1` without an iteration - is left to the
  ## caller to drop, which is what nimver has always done with a suffix it did
  ## not write.
  let dot = suffix.rfind('.')
  if dot <= 0 or dot == suffix.len - 1:
    return ("", 0)
  let name = suffix[0 ..< dot]
  if not name.allCharsInSet(TrackNameChars):
    return ("", 0)
  try:
    let iteration = parseInt(suffix[dot + 1 .. ^1])
    if iteration < 1:
      return ("", 0)
    (name, iteration)
  except ValueError:
    ("", 0)

proc parseSemVer*(s: string): SemVer =
  ## Parses the `major.minor.patch` core of a version string, keeping a
  ## `-<track>.<iteration>` suffix and dropping build metadata (`+...`) and any
  ## other prerelease spelling.
  let withoutBuild = s.strip().split('+', 1)[0]
  let dash = withoutBuild.find('-')
  let core =
    if dash == -1:
      withoutBuild
    else:
      withoutBuild[0 ..< dash]
  let parts = core.split('.')
  if parts.len != 3:
    raise newException(ValueError, "Invalid semantic version: " & s)
  result = SemVer(
    major: parseInt(parts[0]), minor: parseInt(parts[1]), patch: parseInt(parts[2])
  )
  if dash != -1:
    (result.track, result.iteration) = parseTrackSuffix(withoutBuild[dash + 1 .. ^1])

proc bump*(v: SemVer, level: BumpLevel): SemVer =
  ## Always yields a release: a track is put back on afterwards, by whoever
  ## knows which one and at which iteration.
  case level
  of blMajor:
    SemVer(major: v.major + 1, minor: 0, patch: 0)
  of blMinor:
    SemVer(major: v.major, minor: v.minor + 1, patch: 0)
  of blPatch:
    SemVer(major: v.major, minor: v.minor, patch: v.patch + 1)
  of blNone:
    v
  of blIgnore:
    v

proc `$`*(level: BumpLevel): string =
  case level
  of blMajor: "major"
  of blMinor: "minor"
  of blPatch: "patch"
  of blNone: "none"
  of blIgnore: "ignore"

proc parseBumpLevel*(s: string): BumpLevel =
  case s.strip().toLowerAscii()
  of "major":
    blMajor
  of "minor":
    blMinor
  of "patch":
    blPatch
  of "none":
    blNone
  of "ignore":
    blIgnore
  else:
    raise newException(ValueError, "Invalid bump level: " & s)
