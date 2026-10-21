## Reads and rewrites the top-level `version` field of a `package.json` file.

import std/json
import results
import ../sysio
import ./jsonsource
import ./sourceedit
import ../semver

proc parsePackageJson(
    packageJsonPath, sourceContent: string
): Result[JsonNode, string] =
  let parsed = catch(parseJson(sourceContent)).valueOr:
    return err("Could not parse " & packageJsonPath & ": " & error.msg)
  if parsed.kind != JObject:
    return err(packageJsonPath & " must contain a JSON object")
  ok(parsed)

proc versionNode(packageJsonPath, sourceContent: string): Result[JsonNode, string] =
  let rootObject = ?parsePackageJson(packageJsonPath, sourceContent)
  if not rootObject.hasKey("version") or rootObject["version"].kind != JString:
    return
      err("Could not find a top-level string 'version' field in " & packageJsonPath)
  ok(rootObject["version"])

proc readPackageVersion*(packageJsonPath: string): Result[SemVer, string] =
  let sourceContent = ?readFileContents(packageJsonPath)
  parseSemVer((?versionNode(packageJsonPath, sourceContent)).getStr())

proc packageVersionWritten*(
    packageJsonPath: string, newVersion: SemVer
): Result[string, string] =
  let sourceContent = ?readFileContents(packageJsonPath)
  discard ?versionNode(packageJsonPath, sourceContent)
  let versionSpan = ?findTopLevelValueSpan(sourceContent, "version")
  let serializedVersion = $(%($newVersion))
  ok(replaceSpan(sourceContent, versionSpan, serializedVersion))
