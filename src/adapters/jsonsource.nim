## Locates values in JSON source without serializing and reformatting the file.
## Semantic validation remains the responsibility of `std/json`.

import std/[json, strutils]
import ./sourceedit

type ParsedJsonProperty = object
  name: string
  valueSpan: SourceSpan
  nextPropertyIndex: int

proc findJsonStringEnd(sourceContent: string, openingQuoteIndex: int): int =
  ## Returns the index immediately after a JSON string.
  if openingQuoteIndex >= sourceContent.len or sourceContent[openingQuoteIndex] != '"':
    raise newException(ValueError, "Expected a JSON string")

  var previousCharacterEscaped = false
  var cursorIndex = openingQuoteIndex + 1
  while cursorIndex < sourceContent.len:
    if previousCharacterEscaped:
      previousCharacterEscaped = false
    elif sourceContent[cursorIndex] == '\\':
      previousCharacterEscaped = true
    elif sourceContent[cursorIndex] == '"':
      return cursorIndex + 1
    inc cursorIndex

  raise newException(ValueError, "Unterminated JSON string")

proc skipJsonWhitespace(sourceContent: string, startIndex: int): int =
  result = startIndex
  while result < sourceContent.len and sourceContent[result] in Whitespace:
    inc result

proc findJsonValueEnd(sourceContent: string, valueStartIndex: int): int =
  ## Returns the end of an object property's value, excluding the following
  ## comma or closing brace.
  var cursorIndex = valueStartIndex
  var nestingDepth = 0
  while cursorIndex < sourceContent.len:
    case sourceContent[cursorIndex]
    of '"':
      cursorIndex = findJsonStringEnd(sourceContent, cursorIndex)
      continue
    of '[', '{':
      inc nestingDepth
    of ']', '}':
      if nestingDepth == 0:
        return cursorIndex
      dec nestingDepth
    of ',':
      if nestingDepth == 0:
        return cursorIndex
    else:
      discard
    inc cursorIndex

  raise newException(ValueError, "Unterminated JSON value")

proc parseJsonProperty(
    sourceContent: string, propertyNameStartIndex: int
): ParsedJsonProperty =
  let propertyNameEndIndex = findJsonStringEnd(sourceContent, propertyNameStartIndex)
  result.name =
    parseJson(sourceContent[propertyNameStartIndex ..< propertyNameEndIndex]).getStr()

  var cursorIndex = skipJsonWhitespace(sourceContent, propertyNameEndIndex)
  if cursorIndex >= sourceContent.len or sourceContent[cursorIndex] != ':':
    raise newException(ValueError, "Expected ':' after a JSON property")
  cursorIndex = skipJsonWhitespace(sourceContent, cursorIndex + 1)

  result.valueSpan.startIndex = cursorIndex
  result.valueSpan.endIndex = findJsonValueEnd(sourceContent, cursorIndex)
  while result.valueSpan.endIndex > result.valueSpan.startIndex and
      sourceContent[result.valueSpan.endIndex - 1] in Whitespace:
    dec result.valueSpan.endIndex

  cursorIndex = skipJsonWhitespace(sourceContent, result.valueSpan.endIndex)
  if cursorIndex < sourceContent.len and sourceContent[cursorIndex] == ',':
    result.nextPropertyIndex = cursorIndex + 1
  elif cursorIndex < sourceContent.len and sourceContent[cursorIndex] == '}':
    result.nextPropertyIndex = cursorIndex
  else:
    raise newException(ValueError, "Expected ',' or '}' in JSON object")

proc findTopLevelValueSpan*(sourceContent, targetPropertyName: string): SourceSpan =
  ## Finds a property value in a top-level JSON object. The source should first
  ## be validated with `std/json`; this procedure only retains source offsets.
  var cursorIndex = skipJsonWhitespace(sourceContent, 0)
  if cursorIndex >= sourceContent.len or sourceContent[cursorIndex] != '{':
    raise newException(ValueError, "Expected a top-level JSON object")
  inc cursorIndex

  while true:
    cursorIndex = skipJsonWhitespace(sourceContent, cursorIndex)
    if cursorIndex >= sourceContent.len or sourceContent[cursorIndex] == '}':
      break

    let parsedProperty = parseJsonProperty(sourceContent, cursorIndex)
    if parsedProperty.name == targetPropertyName:
      return parsedProperty.valueSpan
    cursorIndex = parsedProperty.nextPropertyIndex

  raise newException(
    KeyError, "Could not find top-level JSON property: " & targetPropertyName
  )
