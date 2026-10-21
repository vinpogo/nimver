## Locates values in JSON source without serializing and reformatting the file.
## Semantic validation remains the responsibility of `std/json`.

import std/[json, strutils, sugar]
import ./sourceedit
import results

type ParsedJsonProperty = object
  name: string
  valueSpan: SourceSpan
  nextPropertyIndex: int

proc findJsonStringEnd(
    sourceContent: string, openingQuoteIndex: int
): Result[int, string] =
  ## Returns the index immediately after a JSON string.
  if openingQuoteIndex >= sourceContent.len or sourceContent[openingQuoteIndex] != '"':
    return err("Expected a JSON string")

  var previousCharacterEscaped = false
  var cursorIndex = openingQuoteIndex + 1
  while cursorIndex < sourceContent.len:
    if previousCharacterEscaped:
      previousCharacterEscaped = false
    elif sourceContent[cursorIndex] == '\\':
      previousCharacterEscaped = true
    elif sourceContent[cursorIndex] == '"':
      return ok(cursorIndex + 1)
    inc cursorIndex

  err("Unterminated JSON string")

proc skipJsonWhitespace(sourceContent: string, startIndex: int): int =
  result = startIndex
  while result < sourceContent.len and sourceContent[result] in Whitespace:
    inc result

proc findJsonValueEnd(
    sourceContent: string, valueStartIndex: int
): Result[int, string] =
  ## Returns the end of an object property's value, excluding the following
  ## comma or closing brace.
  var cursorIndex = valueStartIndex
  var nestingDepth = 0
  while cursorIndex < sourceContent.len:
    case sourceContent[cursorIndex]
    of '"':
      cursorIndex = ?findJsonStringEnd(sourceContent, cursorIndex)
      continue
    of '[', '{':
      inc nestingDepth
    of ']', '}':
      if nestingDepth == 0:
        return ok(cursorIndex)
      dec nestingDepth
    of ',':
      if nestingDepth == 0:
        return ok(cursorIndex)
    else:
      discard
    inc cursorIndex

  err("Unterminated JSON value")

proc parseJsonProperty(
    sourceContent: string, propertyNameStartIndex: int
): Result[ParsedJsonProperty, string] =
  var property: ParsedJsonProperty
  let propertyNameEndIndex = ?findJsonStringEnd(sourceContent, propertyNameStartIndex)
  property.name = (
    ?catch(parseJson(sourceContent[propertyNameStartIndex ..< propertyNameEndIndex]))
      .mapErr(e => e.msg)
  ).getStr()

  var cursorIndex = skipJsonWhitespace(sourceContent, propertyNameEndIndex)
  if cursorIndex >= sourceContent.len or sourceContent[cursorIndex] != ':':
    return err("Expected ':' after a JSON property")
  cursorIndex = skipJsonWhitespace(sourceContent, cursorIndex + 1)

  property.valueSpan.startIndex = cursorIndex
  property.valueSpan.endIndex = ?findJsonValueEnd(sourceContent, cursorIndex)
  while property.valueSpan.endIndex > property.valueSpan.startIndex and
      sourceContent[property.valueSpan.endIndex - 1] in Whitespace:
    dec property.valueSpan.endIndex

  cursorIndex = skipJsonWhitespace(sourceContent, property.valueSpan.endIndex)
  if cursorIndex < sourceContent.len and sourceContent[cursorIndex] == ',':
    property.nextPropertyIndex = cursorIndex + 1
  elif cursorIndex < sourceContent.len and sourceContent[cursorIndex] == '}':
    property.nextPropertyIndex = cursorIndex
  else:
    return err("Expected ',' or '}' in JSON object")
  ok(property)

proc findTopLevelValueSpan*(
    sourceContent, targetPropertyName: string
): Result[SourceSpan, string] =
  ## Finds a property value in a top-level JSON object. The source should first
  ## be validated with `std/json`; this procedure only retains source offsets.
  var cursorIndex = skipJsonWhitespace(sourceContent, 0)
  if cursorIndex >= sourceContent.len or sourceContent[cursorIndex] != '{':
    return err("Expected a top-level JSON object")
  inc cursorIndex

  while true:
    cursorIndex = skipJsonWhitespace(sourceContent, cursorIndex)
    if cursorIndex >= sourceContent.len or sourceContent[cursorIndex] == '}':
      break

    let parsedProperty = ?parseJsonProperty(sourceContent, cursorIndex)
    if parsedProperty.name == targetPropertyName:
      return ok(parsedProperty.valueSpan)
    cursorIndex = parsedProperty.nextPropertyIndex

  err("Could not find top-level JSON property: " & targetPropertyName)
