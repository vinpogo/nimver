## Loads the `.nimver/config.ini` type -> bump-level mapping.

import std/[os, streams, parsecfg, tables, strutils]
import ./semver

const DefaultConfig* = """; nimver configuration
;
; Maps a Conventional Commits type to a semantic version bump.
; Allowed values: major, minor, patch, none, ignore
;   - "none" still shows up in the changelog but does not bump the version.
;   - "ignore" is skipped entirely: no change file is recorded and it never
;     shows up in the changelog. Used for the "version" type, which is what
;     `bump --commit` uses for its own release commits, so they don't get
;     picked up as a pending change on the next `bump`.
;   - a commit type not listed here is rejected by the commit-msg hook.
; Regardless of this mapping, a commit marked as breaking (`feat!: ...` or a
; `BREAKING CHANGE:` footer) always bumps `major`.

[types]
feat = minor
fix = patch
perf = patch
refactor = patch
revert = patch
docs = none
style = none
chore = none
test = none
build = none
ci = none
version = ignore
"""

type Config* = object
  types*: Table[string, BumpLevel]

proc configPath*(repoRoot: string): string =
  repoRoot / ".nimver" / "config.ini"

proc loadConfig*(repoRoot: string): Config =
  let path = configPath(repoRoot)
  if not fileExists(path):
    raise newException(
      IOError, "Config not found at " & path & ". Run `nimver init` first."
    )

  var stream = newFileStream(path, fmRead)
  defer:
    stream.close()

  var parser: CfgParser
  open(parser, stream, path)
  defer:
    close(parser)

  result = Config(types: initTable[string, BumpLevel]())
  var currentSection = ""
  while true:
    let event = next(parser)
    case event.kind
    of cfgEof:
      break
    of cfgSectionStart:
      currentSection = event.section
    of cfgKeyValuePair, cfgOption:
      if currentSection.toLowerAscii() == "types":
        result.types[event.key.strip().toLowerAscii()] = parseBumpLevel(event.value)
    of cfgError:
      raise newException(IOError, "Error parsing " & path & ": " & event.msg)

proc lookupType*(config: Config, commitType: string): (bool, BumpLevel) =
  let key = commitType.toLowerAscii()
  if config.types.hasKey(key):
    (true, config.types[key])
  else:
    (false, blNone)
