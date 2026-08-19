## Detects a supported project manifest and dispatches version operations to
## the corresponding ecosystem adapter.

import std/[os, strutils]
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

proc findProjectManifest*(repoRoot: string): ProjectManifest =
  var nimbleManifestPath = ""
  for directoryEntryKind, directoryEntryPath in walkDir(repoRoot):
    if directoryEntryKind == pcFile and directoryEntryPath.endsWith(".nimble"):
      if nimbleManifestPath.len > 0:
        raise
          newException(IOError, "Multiple .nimble files found at the repository root")
      nimbleManifestPath = directoryEntryPath

  let packageJsonPath = repoRoot / "package.json"
  if nimbleManifestPath.len > 0 and fileExists(packageJsonPath):
    raise newException(
      IOError,
      "Both Nimble and package.json manifests were found. Remove one or configure a single project manifest.",
    )
  if nimbleManifestPath.len > 0:
    return ProjectManifest(manifestKind: mkNimble, filePath: nimbleManifestPath)
  if fileExists(packageJsonPath):
    return ProjectManifest(manifestKind: mkPackageJson, filePath: packageJsonPath)

  raise newException(
    IOError,
    "No supported project manifest found. Expected a .nimble file or package.json.",
  )

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
