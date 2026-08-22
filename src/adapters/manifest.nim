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

proc rootManifestNames*(entryNames: seq[string]): seq[string] =
  ## The supported manifests among the names of a repository root's entries, in
  ## a stable order. Taking names rather than reading a directory is what lets a
  ## release ask the same question of a past commit's tree.
  var nimbleManifestNames: seq[string] = @[]
  for entryName in entryNames:
    if entryName.endsWith(".nimble"):
      nimbleManifestNames.add(entryName)
  sort(nimbleManifestNames)

  result = nimbleManifestNames
  if "package.json" in entryNames:
    result.add("package.json")

proc manifestAt*(filePath: string): ProjectManifest =
  ## The manifest a path names, going by the name alone. Unlike
  ## `manifestFromPath` this does not require the file to be there, which a
  ## past commit's manifest need no longer be.
  if filePath.endsWith(".nimble"):
    ProjectManifest(manifestKind: mkNimble, filePath: filePath)
  else:
    ProjectManifest(manifestKind: mkPackageJson, filePath: filePath)

proc findRootManifests*(repoRoot: string): seq[ProjectManifest] =
  ## Every supported manifest sitting directly in the repository root, in a
  ## stable order. More than one means the repository versions several packages
  ## from the same directory, which the caller has to make sense of.
  var entryNames: seq[string] = @[]
  for directoryEntryKind, directoryEntryPath in walkDir(repoRoot):
    if directoryEntryKind == pcFile:
      entryNames.add(directoryEntryPath.extractFilename())

  for manifestName in rootManifestNames(entryNames):
    result.add(manifestAt(repoRoot / manifestName))

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
