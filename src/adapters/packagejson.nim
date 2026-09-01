## Reads and rewrites the top-level `version` field of a `package.json` file.

import std/json
import ../sysio
import ./jsonsource
import ./sourceedit
import ../semver

proc parsePackageJson(packageJsonPath, sourceContent: string): JsonNode =
  try:
    result = parseJson(sourceContent)
  except JsonParsingError as parsingError:
    raise newException(
      IOError, "Could not parse " & packageJsonPath & ": " & parsingError.msg
    )

  if result.kind != JObject:
    raise newException(IOError, packageJsonPath & " must contain a JSON object")

proc readPackageVersion*(packageJsonPath: string): SemVer =
  let sourceContent = readFileContents(packageJsonPath)
  let rootObject = parsePackageJson(packageJsonPath, sourceContent)
  if not rootObject.hasKey("version") or rootObject["version"].kind != JString:
    raise newException(
      IOError, "Could not find a top-level string 'version' field in " & packageJsonPath
    )
  parseSemVer(rootObject["version"].getStr())

proc writePackageVersion*(packageJsonPath: string, newVersion: SemVer) =
  let sourceContent = readFileContents(packageJsonPath)
  let rootObject = parsePackageJson(packageJsonPath, sourceContent)
  if not rootObject.hasKey("version") or rootObject["version"].kind != JString:
    raise newException(
      IOError, "Could not find a top-level string 'version' field in " & packageJsonPath
    )

  let versionSpan = findTopLevelValueSpan(sourceContent, "version")
  let serializedVersion = $(%($newVersion))
  writeFileContents(
    packageJsonPath, replaceSpan(sourceContent, versionSpan, serializedVersion)
  )
