## Reads and rewrites the version of a Zig package manifest, `build.zig.zon`:
## the `.version` field of its top-level struct. A dependency's fields sit in
## nested structs and are never taken for it.

import std/[options, strutils]
import results
import ../sysio
import ./sourceedit
import ../semver

const IdentifierStart = Letters + {'_'}
const IdentifierCharacters = IdentifierStart + Digits

func lineEnd(sourceContent: string, startIndex: int): int =
  result = sourceContent.find('\n', startIndex)
  if result == -1:
    result = sourceContent.len

func quotedEnd(sourceContent: string, openingQuoteIndex: int): Result[int, string] =
  ## The index just past a string or character literal. Neither may span lines.
  let quoteCharacter = sourceContent[openingQuoteIndex]
  var cursorIndex = openingQuoteIndex + 1
  while cursorIndex < sourceContent.len:
    case sourceContent[cursorIndex]
    of '\\':
      if cursorIndex + 1 < sourceContent.len and sourceContent[cursorIndex + 1] == '\n':
        break
      cursorIndex += 2
      continue
    of '\n':
      break
    else:
      if sourceContent[cursorIndex] == quoteCharacter:
        return ok(cursorIndex + 1)
    inc cursorIndex
  err("is unterminated")

func skipTrivia(sourceContent: string, startIndex: int): int =
  ## Past whitespace and `//` comments.
  result = startIndex
  while result < sourceContent.len:
    if sourceContent[result] in Whitespace:
      inc result
    elif sourceContent.continuesWith("//", result):
      result = lineEnd(sourceContent, result)
    else:
      break

func fieldName(
    sourceContent: string, nameStartIndex: int
): Option[tuple[name: string, endIndex: int]] =
  ## The name after a field's leading `.`: a bare identifier or `@"..."`.
  ## Anything else, such as the `{` of `.{`, is no name.
  if nameStartIndex >= sourceContent.len:
    return none(tuple[name: string, endIndex: int])
  if sourceContent[nameStartIndex] in IdentifierStart:
    var nameEndIndex = nameStartIndex
    while nameEndIndex < sourceContent.len and
        sourceContent[nameEndIndex] in IdentifierCharacters:
      inc nameEndIndex
    return some((sourceContent[nameStartIndex ..< nameEndIndex], nameEndIndex))
  if sourceContent.continuesWith("@\"", nameStartIndex):
    let maybeNameEndIndex = quotedEnd(sourceContent, nameStartIndex + 1)
    if maybeNameEndIndex.isOk:
      let nameEndIndex = maybeNameEndIndex.value
      return
        some((sourceContent[nameStartIndex + 2 ..< nameEndIndex - 1], nameEndIndex))
  none(tuple[name: string, endIndex: int])

proc versionValueSpan(manifestPath, sourceContent: string): Result[SourceSpan, string] =
  template failure(reason: string): untyped =
    err("The 'version' field in " & manifestPath & " " & reason)

  var nestingDepth = 0
  var cursorIndex = 0
  while cursorIndex < sourceContent.len:
    if sourceContent.continuesWith("//", cursorIndex) or
        sourceContent.continuesWith("\\\\", cursorIndex):
      cursorIndex = lineEnd(sourceContent, cursorIndex)
      continue
    case sourceContent[cursorIndex]
    of '"', '\'':
      cursorIndex = quotedEnd(sourceContent, cursorIndex).valueOr:
        return err("Could not parse " & manifestPath & ": a string " & error)
      continue
    of '{':
      inc nestingDepth
    of '}':
      dec nestingDepth
    of '.':
      let maybeField = fieldName(sourceContent, cursorIndex + 1)
      if maybeField.isSome:
        let (name, nameEndIndex) = maybeField.get
        let afterNameIndex = skipTrivia(sourceContent, nameEndIndex)
        let isField =
          afterNameIndex < sourceContent.len and sourceContent[afterNameIndex] == '='
        if nestingDepth == 1 and isField and name == "version":
          let valueStartIndex = skipTrivia(sourceContent, afterNameIndex + 1)
          if valueStartIndex >= sourceContent.len or
              sourceContent[valueStartIndex] != '"':
            return failure("must be a quoted string")
          let valueEndIndex = quotedEnd(sourceContent, valueStartIndex).valueOr:
            return failure(error)
          return
            ok(SourceSpan(startIndex: valueStartIndex + 1, endIndex: valueEndIndex - 1))
        cursorIndex = nameEndIndex
        continue
    else:
      discard
    inc cursorIndex

  err("Could not find a top-level '.version' field in " & manifestPath)

proc readZonVersion*(manifestPath: string): Result[SemVer, string] =
  let sourceContent = ?readFileContents(manifestPath)
  let versionSpan = ?versionValueSpan(manifestPath, sourceContent)
  parseSemVer(sourceContent[versionSpan.startIndex ..< versionSpan.endIndex])

proc zonVersionWritten*(
    manifestPath: string, newVersion: SemVer
): Result[string, string] =
  let sourceContent = ?readFileContents(manifestPath)
  let versionSpan = ?versionValueSpan(manifestPath, sourceContent)
  ok(replaceSpan(sourceContent, versionSpan, $newVersion))
