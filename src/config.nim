import std/[os, streams, parsecfg, tables, strutils, sequtils, sugar, options]
import ./semver
import ./commitparser

const DefaultConfig* = """; nimver configuration
; see https://github.com/vinpogo/nimver for details

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
wip = ignore
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
    sourceFilePatterns*: Option[seq[string]] = none(seq[string])

  NimverConfig* = object
    types*: Table[string, BumpLevel] = initTable[string, BumpLevel]()
    strategyWasSpecified*: bool = false
    packages*: seq[PackageConfig] = @[]
    workspaceStrategy*: WorkspaceStrategy = wsIndependent
    sharedChanges*: SharedChangesKind = scAll

const ConfigName* = "config.ini"
const ConfigDir* = ".nimver"
const ConfigRelPath* = ConfigDir / ConfigName

func configPath*(repoRoot: string): string =
  repoRoot / ConfigRelPath

proc validateWorkspaceConfig(config: NimverConfig, path: string) =
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

func parseWorkspaceStrategy(value: string): WorkspaceStrategy =
  case value
  of "fixed":
    wsFixed
  of "independent":
    wsIndependent
  of "":
    wsIndependent
  else:
    raise newException(ValueError, "Invalid workspace strategy: " & value)

func parseSharedChangesKind(value: string): SharedChangesKind =
  case value
  of "none":
    scNone
  of "all":
    scAll
  else:
    raise newException(ValueError, "Invalid shared changes kind: " & value)

proc checkForUnquotedGlobs(userConfig: parsecfg.Config, path: string) =
  for _, kvs in userConfig.pairs():
    for key in kvs.keys():
      if '*' in key:
        raise newException(
          IOError,
          "Unquoted `*` in " & path &
            ": a value containing `*` has to be quoted, as in sourceFiles = \"packages/web/**, docs/**\"",
        )

proc parseTypes(userConfig: parsecfg.Config): Table[string, BumpLevel] =
  if userConfig.hasKey("types"):
    userConfig["types"]
      .pairs()
      .toSeq()
      .mapIt((it[0].strip().toLowerAscii(), parseBumpLevel(it[1])))
      .toTable()
  else:
    initTable[string, BumpLevel]()

func parseSourceFilePatterns(raw: string): Option[seq[string]] =
  if raw.len > 0:
    some(raw.split(',').mapIt(it.strip()).filterIt(it.len > 0))
  else:
    none(seq[string])

proc parsePackages(userConfig: parsecfg.Config): seq[PackageConfig] =
  collect:
    for section in userConfig.keys():
      if section.toLowerAscii().startsWith("package."):
        PackageConfig(
          name: section["package.".len .. ^1].strip(),
          manifestPath: userConfig.getSectionValue(section, "manifest").strip(),
          sourceFilePatterns:
            parseSourceFilePatterns(userConfig.getSectionValue(section, "sourceFiles")),
        )

proc parseConfig*(contents, path: string): NimverConfig =
  let userConfig = loadConfig(newStringStream(contents), path)
  checkForUnquotedGlobs(userConfig, path)
  let workspaceStrategyRaw = userConfig.getSectionValue("workspace", "strategy")
  let sharedChangesRaw = userConfig.getSectionValue("workspace", "sharedChanges", "all")
  let config = NimverConfig(
    types: parseTypes(userConfig),
    workspaceStrategy: parseWorkspaceStrategy(workspaceStrategyRaw),
    strategyWasSpecified: workspaceStrategyRaw != "",
    sharedChanges: parseSharedChangesKind(sharedChangesRaw),
    packages: parsePackages(userConfig),
  )
  validateWorkspaceConfig(config, path)
  config

proc loadUserConfig*(repoRoot: string): NimverConfig =
  let path = configPath(repoRoot)
  if not fileExists(path):
    raise newException(
      IOError, "Config not found at " & path & ". Run `nimver init` first."
    )
  parseConfig(readFile(path), path)

proc lookupLevel(config: NimverConfig, commitType: string): Option[BumpLevel] =
  let key = commitType.toLowerAscii()
  if config.types.hasKey(key):
    some(config.types[key])
  else:
    none[BumpLevel]()

proc validateAndLookup*(config: NimverConfig, parsed: ParsedCommit): Option[BumpLevel] =
  lookupLevel(config, parsed.commitType).map(
    (level: BumpLevel) => (if parsed.breaking: blMajor else: level)
  )
