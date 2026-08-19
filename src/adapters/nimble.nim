## Reads and rewrites the `version` field of the project's `.nimble` file.

import std/[os, strutils]
import ./sourceedit
import ../semver

proc findNimbleFile*(repoRoot: string): string =
  for directoryEntryKind, directoryEntryPath in walkDir(repoRoot):
    if directoryEntryKind == pcFile and directoryEntryPath.endsWith(".nimble"):
      return directoryEntryPath
  raise newException(IOError, "No .nimble file found in " & repoRoot)

proc isVersionLine(manifestLine: string): bool =
  let trimmedLine = manifestLine.strip()
  trimmedLine.startsWith("version") and trimmedLine.find('=') != -1

proc versionValueSpan(nimbleFilePath, sourceContent: string): SourceSpan =
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
        raise newException(
          IOError, "The 'version' field in " & nimbleFilePath & " must be quoted"
        )

      let quoteCharacter = manifestLine[openingQuoteIndex]
      let closingQuoteIndex = manifestLine.find(quoteCharacter, openingQuoteIndex + 1)
      if closingQuoteIndex == -1:
        raise newException(
          IOError, "The 'version' field in " & nimbleFilePath & " is unterminated"
        )
      return SourceSpan(
        startIndex: lineStartIndex + openingQuoteIndex + 1,
        endIndex: lineStartIndex + closingQuoteIndex,
      )
    lineStartIndex = lineEndIndex + 1

  raise newException(IOError, "Could not find a 'version' field in " & nimbleFilePath)

proc readVersion*(nimbleFilePath: string): SemVer =
  let sourceContent = readFile(nimbleFilePath)
  let versionSpan = versionValueSpan(nimbleFilePath, sourceContent)
  parseSemVer(sourceContent[versionSpan.startIndex ..< versionSpan.endIndex])

proc writeVersion*(nimbleFilePath: string, newVersion: SemVer) =
  let sourceContent = readFile(nimbleFilePath)
  let versionSpan = versionValueSpan(nimbleFilePath, sourceContent)
  writeFile(nimbleFilePath, replaceSpan(sourceContent, versionSpan, $newVersion))
