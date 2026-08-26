import std/[os, streams, parsecfg, tables, sets, strutils, sequtils, sugar, options]
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
  var seenNames, seenManifests = initHashSet[string]()
  for package in config.packages:
    if package.name.len == 0:
      raise newException(IOError, "Package name cannot be empty in " & path)
    if package.manifestPath.len == 0:
      raise newException(
        IOError, "Package '" & package.name & "' is missing manifest in " & path
      )
    if seenNames.containsOrIncl(package.name):
      raise newException(IOError, "Duplicate package '" & package.name & "' in " & path)
    if seenManifests.containsOrIncl(package.manifestPath):
      raise newException(
        IOError, "Duplicate package manifest '" & package.manifestPath & "' in " & path
      )

proc getValue(userConfig: Config, section, key: string): Option[string] =
  if section in userConfig and key in userConfig[section]:
    let value = userConfig[section][key].strip()
    if value.len > 0:
      return some(value)
  none(string)

func parseWorkspaceStrategy(value: string): WorkspaceStrategy =
  case value
  of "fixed":
    wsFixed
  of "independent":
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

func parseSourceFilePatterns(raw: string): seq[string] =
  raw.split(',').mapIt(it.strip()).filterIt(it.len > 0)

proc checkForUnquotedGlobs(userConfig: Config, path: string) =
  for _, kvs in userConfig.pairs():
    for key in kvs.keys():
      if '*' in key:
        raise newException(
          IOError,
          "Unquoted `*` in " & path &
            ": a value containing `*` has to be quoted, as in sourceFiles = \"packages/web/**, docs/**\"",
        )

proc parseTypes(userConfig: Config): Table[string, BumpLevel] =
  if "types" in userConfig:
    for commitType, level in userConfig["types"]:
      result[commitType.strip().toLowerAscii()] = parseBumpLevel(level)

proc parsePackages(userConfig: Config): seq[PackageConfig] =
  const prefix = "package."
  collect:
    for section in userConfig.keys():
      if section.toLowerAscii().startsWith(prefix):
        PackageConfig(
          name: section[prefix.len .. ^1].strip(),
          manifestPath: userConfig.getValue(section, "manifest").get(""),
          sourceFilePatterns:
            userConfig.getValue(section, "sourceFiles").map(parseSourceFilePatterns),
        )

proc parseConfig*(contents, path: string): NimverConfig =
  let userConfig = loadConfig(newStringStream(contents), path)
  checkForUnquotedGlobs(userConfig, path)
  let strategy = userConfig.getValue("workspace", "strategy")
  result = NimverConfig(
    types: parseTypes(userConfig),
    workspaceStrategy: strategy.map(parseWorkspaceStrategy).get(wsIndependent),
    strategyWasSpecified: strategy.isSome,
    sharedChanges: userConfig
      .getValue("workspace", "sharedChanges")
      .map(parseSharedChangesKind)
      .get(scAll),
    packages: parsePackages(userConfig),
  )
  validateWorkspaceConfig(result, path)

proc loadUserConfig*(repoRoot: string): NimverConfig =
  let path = configPath(repoRoot)
  if not fileExists(path):
    raise newException(
      IOError, "Config not found at " & path & ". Run `nimver init` first."
    )
  parseConfig(readFile(path), path)

func lookupLevel(config: NimverConfig, commitType: string): Option[BumpLevel] =
  let key = commitType.toLowerAscii()
  if key in config.types:
    some(config.types[key])
  else:
    none(BumpLevel)

func validateAndLookup*(config: NimverConfig, parsed: ParsedCommit): Option[BumpLevel] =
  lookupLevel(config, parsed.commitType).map(
    (level: BumpLevel) => (if parsed.breaking: blMajor else: level)
  )
