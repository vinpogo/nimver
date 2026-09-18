## Reads `.nimver/config.ini` into a table, refusing anything nimver cannot act
## on before `config` reads meaning into it.
##
## The point is that a mistake in a configuration file is otherwise not an error
## but a silence. `std/parsecfg` answers a line it cannot lex by dropping the
## rest of the file; a section nobody looks up is simply never looked up. Either
## way a misspelled `[packages.web]` leaves a workspace with no packages, which
## reads as a repository that never declared any - and that releases the wrong
## thing rather than saying so.

import std/[editdistance, parsecfg, sequtils, streams, strutils, tables]

const
  TypesSection* = "types"
  WorkspaceSection* = "workspace"
  CommitsSection* = "commits"
  PackagePrefix* = "package."
  StrategyKey* = "strategy"
  SharedChangesKey* = "sharedChanges"
  UnknownTypeKey* = "unknownType"
  ManifestKey* = "manifest"
  SourceFilesKey* = "sourceFiles"

const
  FixedSections = [TypesSection, WorkspaceSection, CommitsSection]
  WorkspaceKeys = [StrategyKey, SharedChangesKey]
  CommitsKeys = [UnknownTypeKey]
  PackageKeys = [ManifestKey, SourceFilesKey]

const SectionSymbolChars =
  {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', ' ', '\x80' .. '\xFF', '.', '/', '\\', '-'}
  ## What `std/parsecfg` lexes as one unquoted symbol - its own `SymChars`,
  ## which it does not export. A header made only of these already parses.

func quotedSectionHeader(line: string): string =
  ## A section name outside `SectionSymbolChars` - `[package.@acme/widgets]` -
  ## does not lex as one token. Quoting the header first turns it into a string
  ## literal, which parsecfg does accept. Headers that already parse are
  ## returned untouched, so only what is broken today changes.
  let open = line.find('[')
  if open == -1 or line[0 ..< open].strip().len > 0:
    return line
  let close = line.find(']', open + 1)
  if close == -1:
    return line
  let rest = line[close + 1 .. ^1]
  let trailing = rest.strip()
  if trailing.len > 0 and trailing[0] notin {';', '#'}:
    # Not a header after all, or one parsecfg would reject anyway. Left alone so
    # it fails the way it does without us rather than in some new way.
    return line
  # Stripped, because that is what parsecfg's own lexer would have seen: it
  # skips whitespace before the section token and trims what trails it. Quoting
  # the padding instead would make it part of the name.
  let inner = line[open + 1 ..< close].strip()
  if inner.len == 0 or inner.allCharsInSet(SectionSymbolChars) or
      (inner.len > 1 and inner.startsWith('"') and inner.endsWith('"')):
    return line
  # `getString` unescapes `\\` and `\"`, so escaping both round-trips any name.
  line[0 ..< open] & "[\"" & inner.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & "\"]" &
    rest

func quotedEmptyValue(line: string): string =
  ## `strategy =` means "left unset" here, but parsecfg reads a value-less
  ## setting as a parse error. Spelling it as the empty string keeps the
  ## meaning and leaves the error for what is actually malformed.
  let equals = line.find('=')
  if equals <= 0:
    return line
  let key = line[0 ..< equals].strip()
  if key.len == 0 or key[0] in {'[', ';', '#'}:
    return line
  let value = line[equals + 1 .. ^1]
  let written = value.strip()
  if written.len > 0 and written[0] notin {';', '#'}:
    return line
  line[0 .. equals] & " \"\"" & value

func normalized(contents: string): string =
  ## What the file says, spelled the way `std/parsecfg` needs to hear it.
  # Split on `\n` rather than by lines: a `\r` stays where it was.
  contents.split('\n').mapIt(it.quotedSectionHeader().quotedEmptyValue()).join("\n")

proc loadConfigTable(contents, path: string): Config =
  ## `std/parsecfg`'s own `loadConfig`, except that a parse error is raised
  ## rather than answered by returning everything up to it, and a section with
  ## no keys is kept rather than dropped - an empty `[package.web]` is a
  ## package missing its manifest, not a package nobody wrote down.
  result = newConfig()
  var parser: CfgParser
  parser.open(newStringStream(contents), path)
  defer:
    parser.close()

  var section = ""
  while true:
    let event = parser.next()
    case event.kind
    of cfgEof:
      break
    of cfgSectionStart:
      section = event.section
      if not result.hasKey(section):
        result[section] = newOrderedTable[string, string]()
    of cfgKeyValuePair:
      result.mgetOrPut(section, newOrderedTable[string, string]())[event.key] =
        event.value
    of cfgOption:
      result.mgetOrPut(section, newOrderedTable[string, string]())["--" & event.key] =
        event.value
    of cfgError:
      raise newException(IOError, "Could not read " & path & ": " & event.msg)

func closestSpelling(unknown: string, candidates: openArray[string]): string =
  ## The nearest known spelling, when one is near enough to be worth naming:
  ## `packages` earns a pointer to `package`, `notes` earns none.
  var shortestDistance = 3
  for candidate in candidates:
    let distance = editDistanceAscii(unknown.toLowerAscii(), candidate.toLowerAscii())
    if distance < shortestDistance:
      shortestDistance = distance
      result = candidate

func suggestedSection(section: string): string =
  ## A package section is half name, so only its prefix is worth comparing:
  ## `[packages.web]` should point at `[package.web]`, not at `[types]`.
  let dot = section.find('.')
  if dot > 0 and closestSpelling(section[0 ..< dot], ["package"]).len > 0:
    return PackagePrefix & section[dot + 1 .. ^1]
  closestSpelling(section, FixedSections)

func knownKeys(section: string): seq[string] =
  if section == WorkspaceSection:
    @WorkspaceKeys
  elif section == CommitsSection:
    @CommitsKeys
  elif section.startsWith(PackagePrefix):
    @PackageKeys
  else:
    @[] # `[types]`, whose keys are the commit types the repository uses.

proc checkUnquotedGlobs(userConfig: Config, path: string) =
  ## Checked before anything else about a key: an unquoted `*` in a *value*
  ## lexes into a key of its own, and "unknown key `*`" would be a riddle.
  for _, keys in userConfig.pairs():
    for key in keys.keys():
      if '*' in key:
        raise newException(
          IOError,
          "Unquoted `*` in " & path &
            ": a value containing `*` has to be quoted, as in sourceFiles = \"packages/web/**, docs/**\"",
        )

proc checkSection(
    section: string, keys: OrderedTableRef[string, string], path: string
) =
  if section.len == 0:
    if keys.len > 0:
      raise newException(
        IOError,
        "Setting '" & toSeq(keys.keys())[0] & "' before any section in " & path &
          ". Every setting belongs under a section, as in [workspace].",
      )
    return

  if section notin FixedSections and not section.startsWith(PackagePrefix):
    let suggested = suggestedSection(section)
    raise newException(
      IOError,
      "Unknown section [" & section & "] in " & path & (
        if suggested.len > 0:
          ", did you mean [" & suggested & "]?"
        else:
          ". Known sections are [types], [workspace], [commits] and [package.<name>]."
      ),
    )

  let allowed = knownKeys(section)
  if allowed.len == 0:
    return
  for key in keys.keys():
    if key notin allowed:
      let suggested = closestSpelling(key, allowed)
      raise newException(
        IOError,
        "Unknown setting '" & key & "' under [" & section & "] in " & path & (
          if suggested.len > 0:
            ", did you mean '" & suggested & "'?"
          else:
            ". [" & section & "] takes " & allowed.join(" and ") & "."
        ),
      )

proc readConfigTable*(contents, path: string): Config =
  ## The sections and settings a configuration file holds, once it is known to
  ## hold nothing else.
  result = loadConfigTable(contents.normalized(), path)
  result.checkUnquotedGlobs(path)
  for section, keys in result.pairs():
    checkSection(section, keys, path)
