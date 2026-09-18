import std/[streams, parsecfg, tables, sets, strutils, sequtils, sugar, options]
import ./sysio
import ./semver
import ./commitparser

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

const SectionSymbolChars =
  {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', ' ', '\x80' .. '\xFF', '.', '/', '\\', '-'}
  ## What `std/parsecfg` lexes as one unquoted symbol - its own `SymChars`,
  ## which it does not export. A header made only of these already parses.

func quotedSectionHeader(line: string): string =
  ## A section name outside `SectionSymbolChars` - `[package.@acme/widgets]` -
  ## does not lex as one token, and `loadConfig` answers a parse error by
  ## dropping the rest of the file without a word. Quoting the header first
  ## turns it into a string literal, which parsecfg does accept. Headers that
  ## already parse are returned untouched, so only what is broken today changes.
  let open = line.find('[')
  if open == -1 or line[0 ..< open].strip().len > 0:
    return line
  let close = line.find(']', open + 1)
  if close == -1:
    return line
  let inner = line[open + 1 ..< close]
  let rest = line[close + 1 .. ^1]
  let trailing = rest.strip()
  if trailing.len > 0 and trailing[0] notin {';', '#'}:
    # Not a header after all, or one parsecfg would reject anyway. Left alone so
    # it fails the way it does today rather than in some new way.
    return line
  if inner.len == 0 or inner.allCharsInSet(SectionSymbolChars) or
      (inner.len > 1 and inner.startsWith('"') and inner.endsWith('"')):
    return line
  # `getString` unescapes `\\` and `\"`, so escaping both round-trips any name.
  line[0 ..< open] & "[\"" & inner.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & "\"]" &
    rest

func quoteSectionHeaders(contents: string): string =
  # Split on `\n` rather than by lines: a `\r` stays where it was.
  contents.split('\n').mapIt(it.quotedSectionHeader()).join("\n")

proc parseConfig*(contents, path: string): NimverConfig =
  let userConfig = loadConfig(newStringStream(contents.quoteSectionHeaders()), path)
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
    unknownType:
      userConfig.getValue("commits", "unknownType").map(parseUnknownType).flatten(),
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
