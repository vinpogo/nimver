import std/strutils
import ./result

type ParsedCommit* = object
  commitType*: string
  scope*: string
  breaking*: bool
  subject*: string
  rawMessage*: string ## Full message, comments and trailing blank lines removed.

proc stripCommentsAndTrailingBlank(raw: string): string =
  var lines: seq[string] = @[]
  for line in raw.splitLines():
    if line.startsWith("#"):
      continue
    lines.add(line)
  while lines.len > 0 and lines[^1].strip().len == 0:
    discard lines.pop()
  lines.join("\n")

proc hasBreakingFooter(message: string): bool =
  for line in message.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("BREAKING CHANGE:") or trimmed.startsWith("BREAKING-CHANGE:"):
      return true
  false

proc isValidTypeToken(s: string): bool =
  if s.len == 0:
    return false
  for c in s:
    if not (c.isAlphaAscii() or c == '-'):
      return false
  true

proc parseCommitMessage*(raw: string): Result[ParsedCommit] =
  let cleaned = stripCommentsAndTrailingBlank(raw)
  if cleaned.strip().len == 0:
    return Failure[ParsedCommit]("Commit message is empty.")

  let headerLine = cleaned.splitLines()[0]
  let sepIdx = headerLine.find(": ")
  if sepIdx == -1:
    return Failure[ParsedCommit](
      "Header must match 'type(scope)!: subject' (missing a ': ' separator)."
    )

  var prefix = headerLine[0 ..< sepIdx]
  let subject = headerLine[sepIdx + 2 .. ^1].strip()
  if subject.len == 0:
    return Failure[ParsedCommit]("Commit subject must not be empty.")

  var breaking = false
  if prefix.endsWith("!"):
    breaking = true
    prefix = prefix[0 ..< prefix.high]

  var commitType = prefix
  var scope = ""
  let parenStart = prefix.find('(')
  if parenStart != -1:
    if not prefix.endsWith(")"):
      return Failure[ParsedCommit]("Unbalanced parentheses in commit scope.")
    commitType = prefix[0 ..< parenStart]
    scope = prefix[parenStart + 1 ..< prefix.high]

  if not isValidTypeToken(commitType):
    return Failure[ParsedCommit](
      "Commit type must be alphabetic (e.g. 'feat', 'fix'), got: '" & commitType & "'."
    )

  if hasBreakingFooter(cleaned):
    breaking = true

  let parsed = ParsedCommit(
    commitType: commitType.toLowerAscii(),
    scope: scope,
    breaking: breaking,
    subject: subject,
    rawMessage: cleaned,
  )
  Success(parsed)
