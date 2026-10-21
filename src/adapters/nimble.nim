## Reads and rewrites the `version` field of the project's `.nimble` file.

import std/strutils
import results
import ../sysio
import ./sourceedit
import ../semver

proc isVersionLine(manifestLine: string): bool =
  let trimmedLine = manifestLine.strip()
  trimmedLine.startsWith("version") and trimmedLine.find('=') != -1

proc versionValueSpan(
    nimbleFilePath, sourceContent: string
): Result[SourceSpan, string] =
  var lineStartIndex = 0
  while lineStartIndex < sourceContent.len:
    var lineEndIndex = sourceContent.find('\n', lineStartIndex)
    if lineEndIndex == -1:
      lineEndIndex = sourceContent.len
    let manifestLine = sourceContent[lineStartIndex ..< lineEndIndex]
    if isVersionLine(manifestLine):
      let equalsSignIndex = manifestLine.find('=')
      var openingQuoteIndex = equalsSignIndex + 1
      while openingQuoteIndex < manifestLine.len and
          manifestLine[openingQuoteIndex] in Whitespace:
        inc openingQuoteIndex
      if openingQuoteIndex >= manifestLine.len or
          manifestLine[openingQuoteIndex] notin {'"', '\''}:
        return err("The 'version' field in " & nimbleFilePath & " must be quoted")

      let quoteCharacter = manifestLine[openingQuoteIndex]
      let closingQuoteIndex = manifestLine.find(quoteCharacter, openingQuoteIndex + 1)
      if closingQuoteIndex == -1:
        return err("The 'version' field in " & nimbleFilePath & " is unterminated")
      return ok(
        SourceSpan(
          startIndex: lineStartIndex + openingQuoteIndex + 1,
          endIndex: lineStartIndex + closingQuoteIndex,
        )
      )
    lineStartIndex = lineEndIndex + 1

  err("Could not find a 'version' field in " & nimbleFilePath)

proc readVersion*(nimbleFilePath: string): Result[SemVer, string] =
  let sourceContent = ?readFileContents(nimbleFilePath)
  let versionSpan = ?versionValueSpan(nimbleFilePath, sourceContent)
  parseSemVer(sourceContent[versionSpan.startIndex ..< versionSpan.endIndex])

proc versionWritten*(
    nimbleFilePath: string, newVersion: SemVer
): Result[string, string] =
  let sourceContent = ?readFileContents(nimbleFilePath)
  let versionSpan = ?versionValueSpan(nimbleFilePath, sourceContent)
  ok(replaceSpan(sourceContent, versionSpan, $newVersion))
