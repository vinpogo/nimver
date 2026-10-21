import std/[options, strutils]
import ../config
import ../sysio
import ../changelog
import ../semver
import ../workspace
import ../release

proc parseRequestedVersion(versionArgument: string): SemVer =
  ## Only a version nimver itself could have released: `parseSemVer` reads
  ## `1.2.0-beta` as `1.2.0`, and answering with that release's entry would
  ## be answering a different question.
  let spelled =
    if versionArgument.startsWith("v"):
      versionArgument[1 .. ^1]
    else:
      versionArgument
  let notAVersion = newException(
    IOError, "'" & versionArgument & "' is not a version. Expected e.g. 1.2.0."
  )
  try:
    result = parseSemVer(spelled)
  except ValueError:
    raise notAVersion
  if $result != spelled:
    raise notAVersion

proc cmdChangelog*(
    repoRoot: string, requestedPackageName: Option[string], versionArgument: string
) =
  let version = parseRequestedVersion(versionArgument)
  let config = loadUserConfig(repoRoot)
  let projectWorkspace = loadWorkspace(repoRoot, config)
  let (path, packageLabel) =
    releasedChangelogFor(repoRoot, projectWorkspace, requestedPackageName)
  let shownPath = relativePath(path, repoRoot)
  if not fileAt(path):
    raise newException(IOError, "no changelog at " & shownPath & ".")

  let label = sectionLabel(version, packageLabel)
  let body = sectionBody(readFileContents(path), label)
  if body.isNone:
    raise newException(IOError, "no entry for " & label & " in " & shownPath & ".")
  if body.get.len > 0:
    echo body.get
