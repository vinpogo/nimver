import std/[strutils, sequtils, options]
import ./result

type
  ParsedCommit* = object
    commitType*: string
    scope*: string
    breaking*: bool
    subject*: string
    releaseNote*: string
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

func hasBreakingFooter(lines: seq[string]): bool =
  lines.anyIt(it.startsWith("BREAKING CHANGE:") or it.startsWith("BREAKING-CHANGE:"))

const
  ReleaseNoteKey = "release-note:"
  FooterKeyChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-'}

func startsAFooter(line: string): bool =
  ## A git trailer, `Key: value`, plus the spelling the Conventional Commits
  ## spec gives breaking changes, which has a space in its key.
  if line.startsWith("BREAKING CHANGE:"):
    return true
  let colon = line.find(':')
  colon > 0 and line[0 ..< colon].allCharsInSet(FooterKeyChars)

func releaseNoteFooter(lines: seq[string]): string =
  ## Searched from the second line on, so a subject that reads like the footer
  ## stays a subject. The first footer wins, and it runs on over wrapped lines
  ## until a blank line or the next footer.
  var parts: seq[string] = @[]
  var reading = false
  for line in lines[1 .. ^1]:
    if reading:
      if line.len == 0 or line.startsAFooter():
        break
      parts.add(line)
    elif line.toLowerAscii().startsWith(ReleaseNoteKey):
      reading = true
      parts.add(line[ReleaseNoteKey.len .. ^1])
  parts.join(" ").strip()

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
  let breaking = parsedHeader.value.breaking or hasBreakingFooter(lines)
  let subject = parsedHeader.value.subject

  let parsed = ParsedCommit(
    commitType: commitType,
    scope: scope,
    breaking: breaking,
    subject: subject,
    releaseNote: releaseNoteFooter(lines),
    rawMessage: raw,
  )
  Success(parsed)
