## Reads and rewrites the version of a JSON manifest: the top-level `version`
## field (`package.json`), or `metadata.version` where a tool keeps its own
## metadata under one key (`tree-sitter.json`).

import std/json
import results
import ../sysio
import ./jsonsource
import ./sourceedit
import ../semver

const VersionPaths = [@["version"], @["metadata", "version"]]
  ## Where a version is looked for, in this order.

proc parseManifest(manifestPath, sourceContent: string): Result[JsonNode, string] =
  let parsed = catch(parseJson(sourceContent)).valueOr:
    return err("Could not parse " & manifestPath & ": " & error.msg)
  if parsed.kind != JObject:
    return err(manifestPath & " must contain a JSON object")
  ok(parsed)

proc versionPath(manifestPath, sourceContent: string): Result[seq[string], string] =
  ## The first of `VersionPaths` that holds a string.
  let rootObject = ?parseManifest(manifestPath, sourceContent)
  for path in VersionPaths:
    var node = rootObject
    for name in path:
      if node.kind != JObject or not node.hasKey(name):
        node = nil
        break
      node = node[name]
    if node != nil and node.kind == JString:
      return ok(path)
  err(
    "Could not find a string 'version' field in " & manifestPath &
      ", at the top level or under 'metadata'"
  )

proc readJsonVersion*(manifestPath: string): Result[SemVer, string] =
  let sourceContent = ?readFileContents(manifestPath)
  var node = ?parseManifest(manifestPath, sourceContent)
  for name in ?versionPath(manifestPath, sourceContent):
    node = node[name]
  parseSemVer(node.getStr())

proc jsonVersionWritten*(
    manifestPath: string, newVersion: SemVer
): Result[string, string] =
  let sourceContent = ?readFileContents(manifestPath)
  let path = ?versionPath(manifestPath, sourceContent)
  let versionSpan = ?findNestedValueSpan(sourceContent, path)
  ok(replaceSpan(sourceContent, versionSpan, $(%($newVersion))))
