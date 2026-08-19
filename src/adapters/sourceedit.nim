## Applies precise edits to source files without reformatting unrelated text.

type SourceSpan* = object
  startIndex*: int
  endIndex*: int ## Exclusive.

proc replaceSpan*(
    sourceContent: string, sourceSpan: SourceSpan, replacement: string
): string =
  if sourceSpan.startIndex < 0 or sourceSpan.endIndex < sourceSpan.startIndex or
      sourceSpan.endIndex > sourceContent.len:
    raise newException(IndexDefect, "Invalid source span")

  let contentBeforeSpan = sourceContent[0 ..< sourceSpan.startIndex]
  let contentAfterSpan = sourceContent[sourceSpan.endIndex .. ^1]
  contentBeforeSpan & replacement & contentAfterSpan
