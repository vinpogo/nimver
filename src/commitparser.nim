import std/[strutils, sequtils, options]
import ./result

type
  ParsedCommit* = object
    commitType*: string
    scope*: string
    breaking*: bool
    subject*: string
    rawMessage*: string ## Full message, comments and trailing blank lines removed.

  ParsedHeader = object
    breaking: bool
    commitType: string
    scope: string
    subject: string

func stripCommentsAndTrailingBlank(raw: string): seq[string] =
  raw.splitLines().mapIt(it.strip()).filterIt(not it.startsWith("#") and it.len > 0)

func hasBreakingFooter(lines: seq[string]): bool =
  lines.anyIt(it.startsWith("BREAKING CHANGE:") or it.startsWith("BREAKING-CHANGE:"))

const
  TypeChars = {'a' .. 'z', '-'}
  ScopeChars = {'a' .. 'z', '-'}

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
  let lines = stripCommentsAndTrailingBlank(raw)
  if lines.len == 0:
    return Failure[ParsedCommit]("Commit message is empty.")

  let parsedHeader = parseHeaderLine(lines[0])
  if isFailure(parsedHeader):
    return Failure[ParsedCommit](parsedHeader.error)

  let commitType = parsedHeader.value.commitType
  let scope = parsedHeader.value.scope
  let breaking = parsedHeader.value.breaking or hasBreakingFooter(lines)
  let subject = parsedHeader.value.subject

  let parsed = ParsedCommit(
    commitType: commitType,
    scope: scope,
    breaking: breaking,
    subject: subject,
    rawMessage: raw,
  )
  Success(parsed)
