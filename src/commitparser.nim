import std/[strutils, sequtils, options]
import ./result

type
  ParsedCommit* = object
    commitType*: string
    scope*: string
    breaking*: bool
    subject*: string
    releaseNote*: string
    breakingNote*: string
    rawMessage*: string ## Full message, comments and trailing blank lines removed.

  ParsedHeader = object
    breaking: bool
    commitType: string
    scope: string
    subject: string

func stripComments(raw: string): seq[string] =
  ## Blank lines are kept: they are what ends a footer that wraps over several
  ## lines. Leading and trailing ones are not, so the header is always first.
  var lines = raw.splitLines().mapIt(it.strip()).filterIt(not it.startsWith("#"))
  while lines.len > 0 and lines[0].len == 0:
    lines.delete(0)
  while lines.len > 0 and lines[^1].len == 0:
    lines.delete(lines.high)
  lines

const
  ReleaseNoteKeys = ["Release-Note"]
  BreakingKeys = ["BREAKING CHANGE", "BREAKING-CHANGE"]
  FooterKeyChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-'}

func startsAFooter(line: string): bool =
  if BreakingKeys.anyIt(line.startsWith(it & ":")):
    return true
  let colon = line.find(':')
  colon > 0 and line[0 ..< colon].allCharsInSet(FooterKeyChars)

func opensFooter(line: string, keys: openArray[string], caseSensitive: bool): bool =
  if caseSensitive:
    keys.anyIt(line.startsWith(it & ":"))
  else:
    let lowered = line.toLowerAscii()
    keys.anyIt(lowered.startsWith(toLowerAscii(it & ":")))

func footerValue(
    lines: seq[string], keys: openArray[string], caseSensitive = false
): Option[string] =
  var parts: seq[string] = @[]
  var reading = false
  for line in lines[1 .. ^1]:
    if reading:
      if line.len == 0 or line.startsAFooter():
        break
      parts.add(line)
    elif line.opensFooter(keys, caseSensitive):
      reading = true
      parts.add(line[line.find(':') + 1 .. ^1])
  if reading:
    some(parts.join(" ").strip())
  else:
    none(string)

const
  TypeChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '/'}
  ScopeChars = TypeChars + {'.', ','}

func isMadeOf(text: string, allowed: set[char]): bool =
  text.len > 0 and text.allCharsInSet(allowed)

func parsePrefix(prefix: string): Option[ParsedHeader] =
  ## Splits `type`, `(scope)` and `!` out of everything before the first colon.
  var remaining = prefix
  let breaking = remaining.endsWith("!")
  if breaking:
    remaining.setLen(remaining.len - 1)

  var scope = ""
  if remaining.endsWith(")"):
    let scopeStart = remaining.rfind('(')
    if scopeStart == -1:
      return none(ParsedHeader)
    scope = remaining[scopeStart + 1 ..< remaining.len - 1]
    if not scope.isMadeOf(ScopeChars):
      return none(ParsedHeader)
    remaining.setLen(scopeStart)

  if not remaining.isMadeOf(TypeChars):
    return none(ParsedHeader)

  some(ParsedHeader(breaking: breaking, commitType: remaining, scope: scope))

func parseHeaderLine(line: string): Result[ParsedHeader] =
  let malformed = Failure[ParsedHeader](
    "Header '" & line & "' does not match 'type(scope)!: subject'."
  )

  let colonIndex = line.find(':')
  if colonIndex == -1:
    return malformed

  let header = parsePrefix(line[0 ..< colonIndex])
  if header.isNone:
    return malformed

  let subject = line[colonIndex + 1 ..^ 1].strip()
  if subject.len == 0:
    return malformed

  Success(
    ParsedHeader(
      commitType: header.get().commitType,
      breaking: header.get().breaking,
      scope: header.get().scope,
      subject: subject,
    )
  )

func parseCommitMessage*(raw: string): Result[ParsedCommit] =
  let lines = stripComments(raw)
  if lines.len == 0:
    return Failure[ParsedCommit]("Commit message is empty.")

  let parsedHeader = parseHeaderLine(lines[0])
  if isFailure(parsedHeader):
    return Failure[ParsedCommit](parsedHeader.error)

  let commitType = parsedHeader.value.commitType
  let scope = parsedHeader.value.scope
  let breakingFooter = footerValue(lines, BreakingKeys, caseSensitive = true)
  let breaking = parsedHeader.value.breaking or breakingFooter.isSome
  let subject = parsedHeader.value.subject

  let parsed = ParsedCommit(
    commitType: commitType,
    scope: scope,
    breaking: breaking,
    subject: subject,
    releaseNote: footerValue(lines, ReleaseNoteKeys).get(""),
    breakingNote: breakingFooter.get(""),
    rawMessage: raw,
  )
  Success(parsed)
