import std/[re, strutils, sequtils]
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

let commitHeaderRegex = re"^([a-z-]+)(\(([a-z-]+)\))?(!)?:\s*(.+)$"

func stripCommentsAndTrailingBlank(raw: string): seq[string] =
  raw.splitLines().mapIt(it.strip()).filterIt(not it.startsWith("#") and it.len > 0)

func hasBreakingFooter(lines: seq[string]): bool =
  lines.anyIt(it.startsWith("BREAKING CHANGE:") or it.startsWith("BREAKING-CHANGE:"))

proc parseHeaderLine(line: string): Result[ParsedHeader] =
  ## Groups: 1 type, 2 "(scope)", 3 scope, 4 "!", 5 subject.
  var groups: array[5, string]
  if not line.match(commitHeaderRegex, groups):
    return Failure[ParsedHeader]("Header does not match 'type(scope)!: subject'.")

  Success(
    ParsedHeader(
      commitType: groups[0],
      breaking: groups[3] == "!",
      scope: groups[2],
      subject: groups[4].strip(),
    )
  )

proc parseCommitMessage*(raw: string): Result[ParsedCommit] =
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
