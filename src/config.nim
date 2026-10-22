import std/[parsecfg, tables, sets, strutils, sequtils, sugar, options]
import results
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
revert = patch
ref = none
refactor = none
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

proc validateWorkspaceConfig(config: NimverConfig, path: string): Result[void, string] =
  var seenNames, seenManifests = initHashSet[string]()
  for package in config.packages:
    if package.name.len == 0:
      return err("Package name cannot be empty in " & path)
    let nameProblem = packageNameProblem(package.name)
    if nameProblem.len > 0:
      return err(
        "Invalid package name '" & package.name & "' in " & path & ": a name " &
          nameProblem & ". It is released as the tag `" & package.name &
          "-v1.2.3` and names itself in the release commit."
      )
    if package.manifestPath.len == 0:
      return err("Package '" & package.name & "' is missing manifest in " & path)
    if seenNames.containsOrIncl(package.name):
      return err("Duplicate package '" & package.name & "' in " & path)
    if seenManifests.containsOrIncl(package.manifestPath):
      return err("Duplicate package manifest '" & package.manifestPath & "' in " & path)
  ok()

proc getValue(userConfig: Config, section, key: string): Option[string] =
  if section in userConfig and key in userConfig[section]:
    let value = userConfig[section][key].strip()
    if value.len > 0:
      return some(value)
  none(string)

func parseWorkspaceStrategy(value: string): Result[WorkspaceStrategy, string] =
  case value
  of "fixed":
    ok(wsFixed)
  of "independent":
    ok(wsIndependent)
  else:
    err("Invalid workspace strategy: " & value)

func parseSharedChangesKind(value: string): Result[SharedChangesKind, string] =
  case value
  of "none":
    ok(scNone)
  of "all":
    ok(scAll)
  else:
    err("Invalid shared changes kind: " & value)

proc parseUnknownType(value: string): Result[Option[BumpLevel], string] =
  if value.strip().toLowerAscii() == "reject":
    return ok(none(BumpLevel))
  let level = parseBumpLevel(value).valueOr:
    return err(
      "Invalid unknownType: " & value &
        ". Expected reject, ignore, none, patch, minor or major."
    )
  ok(some(level))

proc parsedOr[T](
    value: Option[string], parse: proc(value: string): Result[T, string], default: T
): Result[T, string] =
  ## A setting's parsed value, or `default` when it is not set at all.
  if value.isSome:
    parse(value.get)
  else:
    ok(default)

func parseSourceFilePatterns(raw: string): seq[string] =
  raw.split(',').mapIt(it.strip()).filterIt(it.len > 0)

proc parseTypes(userConfig: Config): Result[Table[string, BumpLevel], string] =
  var types = initTable[string, BumpLevel]()
  if TypesSection in userConfig:
    for commitType, level in userConfig[TypesSection]:
      types[commitType.strip().toLowerAscii()] = ?parseBumpLevel(level)
  ok(types)

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

proc parseConfig*(contents, path: string): Result[NimverConfig, string] =
  let userConfig = ?readConfigTable(contents, path)
  let strategy = userConfig.getValue(WorkspaceSection, StrategyKey)
  let config = NimverConfig(
    types: ?parseTypes(userConfig),
    workspaceStrategy: ?strategy.parsedOr(parseWorkspaceStrategy, wsIndependent),
    strategyWasSpecified: strategy.isSome,
    sharedChanges: ?userConfig.getValue(WorkspaceSection, SharedChangesKey).parsedOr(
      parseSharedChangesKind, scAll
    ),
    packages: parsePackages(userConfig),
    unknownType: ?userConfig.getValue(CommitsSection, UnknownTypeKey).parsedOr(
      parseUnknownType, none(BumpLevel)
    ),
  )
  ?validateWorkspaceConfig(config, path)
  ok(config)

proc loadUserConfig*(repoRoot: string): Result[NimverConfig, string] =
  let path = configPath(repoRoot)
  if not fileAt(path):
    return err("Config not found at " & path & ". Run `nimver init` first.")
  parseConfig(?readFileContents(path), path)

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
