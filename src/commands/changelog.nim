import std/[options, strutils]
import results
import ../config
import ../sysio
import ../effects
import ../changelog
import ../semver
import ../workspace
import ../release

proc parseRequestedVersion(versionArgument: string): Result[SemVer, string] =
  ## Only a version nimver itself could have released: `parseSemVer` reads
  ## `1.2.0-beta` as `1.2.0`, and answering with that release's entry would
  ## be answering a different question.
  let spelled =
    if versionArgument.startsWith("v"):
      versionArgument[1 .. ^1]
    else:
      versionArgument
  let notAVersion = "'" & versionArgument & "' is not a version. Expected e.g. 1.2.0."
  let version = parseSemVer(spelled).valueOr:
    return err(notAVersion)
  if $version != spelled:
    return err(notAVersion)
  ok(version)

proc cmdChangelog*(
    repoRoot: string,
    requestedPackageName: Option[string],
    versionArgument: string,
    effects: var Effects,
): Result[void, string] =
  let version = ?parseRequestedVersion(versionArgument)
  let config = ?loadUserConfig(repoRoot)
  let projectWorkspace = ?loadWorkspace(repoRoot, config, effects)
  let (path, packageLabel) =
    ?releasedChangelogFor(repoRoot, projectWorkspace, requestedPackageName)
  let shownPath = relativePath(path, repoRoot)
  if not fileAt(path):
    return err("no changelog at " & shownPath & ".")

  let label = sectionLabel(version, packageLabel)
  let body = sectionBody(?readFileContents(path), label)
  if body.isNone:
    return err("no entry for " & label & " in " & shownPath & ".")
  if body.get.len > 0:
    effects.add(say(body.get))
  ok()
