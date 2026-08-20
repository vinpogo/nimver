## Detects a supported project manifest and dispatches version operations to
## the corresponding ecosystem adapter.

import std/[os, algorithm, strutils]
import ./nimble
import ./packagejson
import ../semver

type
  ManifestKind* = enum
    mkNimble
    mkPackageJson

  ProjectManifest* = object
    manifestKind*: ManifestKind
    filePath*: string

proc displayName*(manifest: ProjectManifest): string =
  case manifest.manifestKind
  of mkNimble: "Nimble"
  of mkPackageJson: "package.json"

proc manifestFromPath*(filePath: string): ProjectManifest =
  if not fileExists(filePath):
    raise newException(IOError, "Manifest not found at " & filePath)
  if filePath.endsWith(".nimble"):
    ProjectManifest(manifestKind: mkNimble, filePath: filePath)
  elif filePath.extractFilename() == "package.json":
    ProjectManifest(manifestKind: mkPackageJson, filePath: filePath)
  else:
    raise newException(IOError, "Unsupported project manifest: " & filePath)

proc findRootManifests*(repoRoot: string): seq[ProjectManifest] =
  ## Every supported manifest sitting directly in the repository root, in a
  ## stable order. More than one means the repository versions several packages
  ## from the same directory, which the caller has to make sense of.
  var nimbleManifestPaths: seq[string] = @[]
  for directoryEntryKind, directoryEntryPath in walkDir(repoRoot):
    if directoryEntryKind == pcFile and directoryEntryPath.endsWith(".nimble"):
      nimbleManifestPaths.add(directoryEntryPath)
  sort(nimbleManifestPaths)

  for nimbleManifestPath in nimbleManifestPaths:
    result.add(ProjectManifest(manifestKind: mkNimble, filePath: nimbleManifestPath))

  let packageJsonPath = repoRoot / "package.json"
  if fileExists(packageJsonPath):
    result.add(ProjectManifest(manifestKind: mkPackageJson, filePath: packageJsonPath))

proc readVersion*(manifest: ProjectManifest): SemVer =
  case manifest.manifestKind
  of mkNimble:
    nimble.readVersion(manifest.filePath)
  of mkPackageJson:
    readPackageVersion(manifest.filePath)

proc writeVersion*(manifest: ProjectManifest, newVersion: SemVer) =
  case manifest.manifestKind
  of mkNimble:
    nimble.writeVersion(manifest.filePath, newVersion)
  of mkPackageJson:
    writePackageVersion(manifest.filePath, newVersion)
