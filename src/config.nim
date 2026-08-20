## Loads Conventional Commit, workspace, and package configuration from
## `.nimver/config.ini`.

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
;
; Repositories with multiple manifests can declare a workspace. The default
; strategy is `independent`: each package keeps its own version and is released
; with `nimver bump <package>`. Use `fixed` to give every package the same
; version, released together by `nimver bump`.
;
; [workspace]
; strategy = independent
; sharedChanges = all
;
; [package.example]
; manifest = packages/example/package.json

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
    scPackage

  SharedChangesPolicy* = object
    kind*: SharedChangesKind
    packageName*: string

  PackageConfig* = object
    name*: string
    manifestPath*: string

  Config* = object
    types*: Table[string, BumpLevel]
    workspaceStrategy*: WorkspaceStrategy
    sharedChanges*: SharedChangesPolicy
    packages*: seq[PackageConfig]

proc configPath*(repoRoot: string): string =
  repoRoot / ".nimver" / "config.ini"

proc parseSharedChanges(value: string): SharedChangesPolicy =
  ## `package.<name>` targets a single package. `package:<name>` is accepted
  ## too, but only when quoted in the ini file: `parsecfg` treats an unquoted
  ## colon as the key/value delimiter and would strip everything after it.
  let normalizedValue = value.strip()
  case normalizedValue.toLowerAscii()
  of "all":
    SharedChangesPolicy(kind: scAll)
  of "none":
    SharedChangesPolicy(kind: scNone)
  else:
    let lowercasedValue = normalizedValue.toLowerAscii()
    if lowercasedValue.startsWith("package.") or lowercasedValue.startsWith("package:"):
      let packageName = normalizedValue["package.".len .. ^1].strip()
      if packageName.len == 0:
        raise newException(ValueError, "sharedChanges package name cannot be empty")
      SharedChangesPolicy(kind: scPackage, packageName: packageName)
    else:
      raise newException(
        ValueError,
        "Invalid sharedChanges value: " & value &
          ". Expected all, none, or package.<name>",
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

  let referencesImplicitRoot =
    config.packages.len == 0 and config.sharedChanges.packageName == "root"
  if config.sharedChanges.kind == scPackage and not referencesImplicitRoot and
      not packageNames.hasKey(config.sharedChanges.packageName):
    raise newException(
      IOError,
      "sharedChanges references unknown package '" & config.sharedChanges.packageName &
        "' in " & path,
    )

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
    sharedChanges: SharedChangesPolicy(kind: scAll),
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
      if normalizedSection == "types":
        result.types[event.key.strip().toLowerAscii()] = parseBumpLevel(event.value)
      elif normalizedSection == "workspace":
        case normalizedKey
        of "strategy":
          case event.value.strip().toLowerAscii()
          of "fixed":
            result.workspaceStrategy = wsFixed
          of "independent":
            result.workspaceStrategy = wsIndependent
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
