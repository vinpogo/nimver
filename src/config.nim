## Loads Conventional Commit, workspace, and package configuration from
## `.nimver/config.ini`.

import std/[os, streams, parsecfg, tables, strutils, sequtils]
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
;
; Repositories with multiple manifests can declare a workspace. The default
; strategy is `independent`: each package keeps its own version, and
; `nimver bump` releases every package with pending changes, each to its own
; next version. `nimver bump <package>` narrows that to one package. Use
; `fixed` to give every package the same version instead.
;
; A changed file belongs to the package whose manifest is its nearest ancestor.
; Packages sharing a directory are equally near, so a file beside them follows
; `sharedChanges` unless `sourceFiles` claims it - and they share the
; CHANGELOG.md in that directory, where each section names its package.
;
; Quote any value containing `*`: unquoted, the ini format ends the value there.
;
; [workspace]
; strategy = independent
; sharedChanges = all
;
; [package.example]
; manifest = packages/example/package.json
; sourceFiles = "packages/example/**"   ; optional; defaults to nearest manifest

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

type
  WorkspaceStrategy* = enum
    wsFixed
    wsIndependent

  SharedChangesKind* = enum
    scAll
    scNone

  PackageConfig* = object
    name*: string
    manifestPath*: string
    sourceFilePatterns*: seq[string]
      ## Optional. Without patterns a file belongs to the package whose
      ## manifest is its nearest ancestor.

  Config* = object
    types*: Table[string, BumpLevel]
    workspaceStrategy*: WorkspaceStrategy
    strategyWasSpecified*: bool
      ## Distinguishes a configured strategy from the default, so sibling
      ## manifests can imply `fixed` without overriding an explicit choice.
    sharedChanges*: SharedChangesKind
    packages*: seq[PackageConfig]

proc configPath*(repoRoot: string): string =
  repoRoot / ".nimver" / "config.ini"

proc parseSharedChanges(value: string): SharedChangesKind =
  case value.strip().toLowerAscii()
  of "all":
    scAll
  of "none":
    scNone
  else:
    raise newException(
      ValueError, "Invalid sharedChanges value: " & value & ". Expected all or none"
    )

proc validateWorkspaceConfig(config: Config, path: string) =
  var packageNames = initTable[string, bool]()
  var manifestPaths = initTable[string, bool]()
  for package in config.packages:
    if package.name.len == 0:
      raise newException(IOError, "Package name cannot be empty in " & path)
    if package.manifestPath.len == 0:
      raise newException(
        IOError, "Package '" & package.name & "' is missing manifest in " & path
      )
    if packageNames.hasKey(package.name):
      raise newException(IOError, "Duplicate package '" & package.name & "' in " & path)
    if manifestPaths.hasKey(package.manifestPath):
      raise newException(
        IOError, "Duplicate package manifest '" & package.manifestPath & "' in " & path
      )
    packageNames[package.name] = true
    manifestPaths[package.manifestPath] = true

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

  result = Config(
    types: initTable[string, BumpLevel](),
    workspaceStrategy: wsIndependent,
    sharedChanges: scAll,
  )
  var currentSection = ""
  var currentPackageIndex = -1
  while true:
    let event = next(parser)
    case event.kind
    of cfgEof:
      break
    of cfgSectionStart:
      currentSection = event.section
      currentPackageIndex = -1
      if currentSection.toLowerAscii().startsWith("package."):
        let packageName = currentSection["package.".len .. ^1].strip()
        result.packages.add(PackageConfig(name: packageName))
        currentPackageIndex = result.packages.high
    of cfgKeyValuePair, cfgOption:
      let normalizedSection = currentSection.toLowerAscii()
      let normalizedKey = event.key.strip().toLowerAscii()
      if '*' in normalizedKey:
        # An ini value is only allowed to contain `*` inside quotes: unquoted,
        # the value ends at the first `*` and the rest arrives as keys of its
        # own. Left to run, that silently narrowed
        # `sourceFiles = packages/web/**` to `packages/web/`, matching nothing.
        raise newException(
          IOError,
          "Unquoted `*` in " & path &
            ": a value containing `*` has to be quoted, as in sourceFiles = \"packages/web/**, docs/**\"",
        )
      if normalizedSection == "types":
        result.types[event.key.strip().toLowerAscii()] = parseBumpLevel(event.value)
      elif normalizedSection == "workspace":
        case normalizedKey
        of "strategy":
          case event.value.strip().toLowerAscii()
          of "fixed":
            result.workspaceStrategy = wsFixed
            result.strategyWasSpecified = true
          of "independent":
            result.workspaceStrategy = wsIndependent
            result.strategyWasSpecified = true
          else:
            raise newException(
              IOError,
              "Invalid workspace strategy: " & event.value &
                ". Expected fixed or independent, in " & path,
            )
        of "sharedchanges":
          try:
            result.sharedChanges = parseSharedChanges(event.value)
          except ValueError as parsingError:
            raise newException(IOError, parsingError.msg & " in " & path)
        else:
          discard
      elif currentPackageIndex >= 0:
        case normalizedKey
        of "manifest":
          result.packages[currentPackageIndex].manifestPath = event.value.strip()
        of "sourcefiles":
          result.packages[currentPackageIndex].sourceFilePatterns =
            event.value.split(',').mapIt(it.strip()).filterIt(it.len > 0)
        else:
          discard
    of cfgError:
      raise newException(IOError, "Error parsing " & path & ": " & event.msg)

  validateWorkspaceConfig(result, path)

proc lookupType*(config: Config, commitType: string): (bool, BumpLevel) =
  let key = commitType.toLowerAscii()
  if config.types.hasKey(key):
    (true, config.types[key])
  else:
    (false, blNone)
