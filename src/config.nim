import std/[parsecfg, tables, sets, strutils, sequtils, sugar, options]
import ./sysio
import ./semver
import ./commitparser
import ./configcheck

const DefaultConfig* = """; nimver configuration
; see https://github.com/vinpogo/nimver for details

; How to treat a type that is not listed below. `reject` refuses the commit;
; any bump level accepts it and counts it at that level.
; [commits]
; unknownType = reject

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
    unknownType*: Option[BumpLevel] = none(BumpLevel)

const ConfigName* = "config.ini"
const ConfigDir* = ".nimver"
const ConfigRelPath* = ConfigDir / ConfigName

func configPath*(repoRoot: string): string =
  repoRoot / ConfigRelPath

const PackageNameChars = ScopeChars
  ## A package name is released under a tag of its own and becomes the scope of
  ## the release commit, so it has to be spellable as both. Taking the commit
  ## scope's character set is the tighter of the two, and rules out everything
  ## `git check-ref-format` refuses along the way.

func packageNameProblem(name: string): string =
  ## What is wrong with a name, phrased to follow "a name ...". Empty when
  ## nothing is.
  if not name.allCharsInSet(PackageNameChars):
    return "may only contain letters, digits and `@ . , - _ /`"
  if name.startsWith('-'):
    return "must not start with `-`, which `git tag` would read as an option"
  if ".." in name:
    return "must not contain `..`"
  if name == "@":
    return "must not be a bare `@`"
  for part in name.split('/'):
    if part.len == 0:
      return "must not contain an empty part between slashes"
    if part.startsWith('.'):
      return "must not contain a part starting with `.`"
    if part.endsWith(".lock"):
      return "must not contain a part ending in `.lock`"
  ""

proc validateWorkspaceConfig(config: NimverConfig, path: string) =
  var seenNames, seenManifests = initHashSet[string]()
  for package in config.packages:
    if package.name.len == 0:
      raise newException(IOError, "Package name cannot be empty in " & path)
    let nameProblem = packageNameProblem(package.name)
    if nameProblem.len > 0:
      raise newException(
        IOError,
        "Invalid package name '" & package.name & "' in " & path & ": a name " &
          nameProblem & ". It is released as the tag `" & package.name &
          "-v1.2.3` and names itself in the release commit.",
      )
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

proc parseUnknownType(value: string): Option[BumpLevel] =
  if value.strip().toLowerAscii() == "reject":
    return none(BumpLevel)
  try:
    some(parseBumpLevel(value))
  except ValueError:
    raise newException(
      ValueError,
      "Invalid unknownType: " & value &
        ". Expected reject, ignore, none, patch, minor or major.",
    )

func parseSourceFilePatterns(raw: string): seq[string] =
  raw.split(',').mapIt(it.strip()).filterIt(it.len > 0)

proc parseTypes(userConfig: Config): Table[string, BumpLevel] =
  if TypesSection in userConfig:
    for commitType, level in userConfig[TypesSection]:
      result[commitType.strip().toLowerAscii()] = parseBumpLevel(level)

proc parsePackages(userConfig: Config): seq[PackageConfig] =
  collect:
    for section in userConfig.keys():
      if section.startsWith(PackagePrefix):
        PackageConfig(
          name: section[PackagePrefix.len .. ^1].strip(),
          manifestPath: userConfig.getValue(section, ManifestKey).get(""),
          sourceFilePatterns:
            userConfig.getValue(section, SourceFilesKey).map(parseSourceFilePatterns),
        )

proc parseConfig*(contents, path: string): NimverConfig =
  let userConfig = readConfigTable(contents, path)
  let strategy = userConfig.getValue(WorkspaceSection, StrategyKey)
  result = NimverConfig(
    types: parseTypes(userConfig),
    workspaceStrategy: strategy.map(parseWorkspaceStrategy).get(wsIndependent),
    strategyWasSpecified: strategy.isSome,
    sharedChanges: userConfig
      .getValue(WorkspaceSection, SharedChangesKey)
      .map(parseSharedChangesKind)
      .get(scAll),
    packages: parsePackages(userConfig),
    unknownType: userConfig
      .getValue(CommitsSection, UnknownTypeKey)
      .map(parseUnknownType)
      .flatten(),
  )
  validateWorkspaceConfig(result, path)

proc loadUserConfig*(repoRoot: string): NimverConfig =
  let path = configPath(repoRoot)
  if not fileAt(path):
    raise newException(
      IOError, "Config not found at " & path & ". Run `nimver init` first."
    )
  parseConfig(readFileContents(path), path)

func lookupLevel(config: NimverConfig, commitType: string): Option[BumpLevel] =
  let key = commitType.toLowerAscii()
  if key in config.types:
    some(config.types[key])
  else:
    config.unknownType

func validateAndLookup*(config: NimverConfig, parsed: ParsedCommit): Option[BumpLevel] =
  lookupLevel(config, parsed.commitType).map(
    (level: BumpLevel) => (if parsed.breaking: blMajor else: level)
  )
