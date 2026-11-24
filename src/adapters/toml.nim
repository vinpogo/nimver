## Reads and rewrites the version of a TOML manifest: a top-level `version`
## (a Zed extension's `extension.toml`), or the one under `[package]`
## (`Cargo.toml`).

import std/strutils
import results
import ../sysio
import ./sourceedit
import ../semver

const VersionTables = ["", "package"]
  ## The tables a version is looked for in, in this order; `""` is the top.

func tableName(headerLine: string): string =
  ## The table a header opens. An array of tables (`[[bin]]`) is never one a
  ## version is looked for in, so it keeps its brackets.
  if headerLine.startsWith("[["):
    return headerLine
  let close = headerLine.find(']')
  if close == -1:
    return headerLine
  headerLine[1 ..< close].strip()

proc versionValue(
    manifestPath, line: string, lineStartIndex: int
): Result[SourceSpan, string] =
  ## The span of the quoted value of a `version = "..."` line.
  let equalsSignIndex = line.find('=')
  var openingQuoteIndex = equalsSignIndex + 1
  while openingQuoteIndex < line.len and line[openingQuoteIndex] in Whitespace:
    inc openingQuoteIndex
  if openingQuoteIndex >= line.len or line[openingQuoteIndex] notin {'"', '\''}:
    return err("The 'version' field in " & manifestPath & " must be a quoted string")
  let quoteCharacter = line[openingQuoteIndex]
  if line.continuesWith($quoteCharacter & $quoteCharacter, openingQuoteIndex + 1):
    return err("The 'version' field in " & manifestPath & " must be on one line")
  let closingQuoteIndex = line.find(quoteCharacter, openingQuoteIndex + 1)
  if closingQuoteIndex == -1:
    return err("The 'version' field in " & manifestPath & " is unterminated")
  ok(
    SourceSpan(
      startIndex: lineStartIndex + openingQuoteIndex + 1,
      endIndex: lineStartIndex + closingQuoteIndex,
    )
  )

func isVersionKey(line: string): bool =
  let equalsSignIndex = line.find('=')
  equalsSignIndex != -1 and
    line[0 ..< equalsSignIndex].strip() in ["version", "\"version\"", "'version'"]

proc versionValueSpan(manifestPath, sourceContent: string): Result[SourceSpan, string] =
  var found: array[VersionTables.len, SourceSpan]
  var foundAny: array[VersionTables.len, bool]
  var table = ""
  var lineStartIndex = 0
  while lineStartIndex < sourceContent.len:
    var lineEndIndex = sourceContent.find('\n', lineStartIndex)
    if lineEndIndex == -1:
      lineEndIndex = sourceContent.len
    let line = sourceContent[lineStartIndex ..< lineEndIndex]
    let trimmed = line.strip()
    if trimmed.startsWith("["):
      table = tableName(trimmed)
    elif isVersionKey(trimmed):
      let tableIndex = VersionTables.find(table)
      if tableIndex != -1 and not foundAny[tableIndex]:
        found[tableIndex] = ?versionValue(manifestPath, line, lineStartIndex)
        foundAny[tableIndex] = true
    lineStartIndex = lineEndIndex + 1

  for tableIndex in 0 ..< VersionTables.len:
    if foundAny[tableIndex]:
      return ok(found[tableIndex])
  err(
    "Could not find a 'version' field in " & manifestPath &
      ", at the top or under [package]"
  )

proc readTomlVersion*(manifestPath: string): Result[SemVer, string] =
  let sourceContent = ?readFileContents(manifestPath)
  let versionSpan = ?versionValueSpan(manifestPath, sourceContent)
  parseSemVer(sourceContent[versionSpan.startIndex ..< versionSpan.endIndex])

proc tomlVersionWritten*(
    manifestPath: string, newVersion: SemVer
): Result[string, string] =
  let sourceContent = ?readFileContents(manifestPath)
  let versionSpan = ?versionValueSpan(manifestPath, sourceContent)
  ok(replaceSpan(sourceContent, versionSpan, $newVersion))
