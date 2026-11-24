## Detects a supported project manifest and dispatches version operations to
## the adapter for its format: a `.nimble` file, JSON or TOML.

import std/[algorithm, options, strutils, sequtils]
import results
import ../sysio
import ./nimble
import ./jsonmanifest
import ./toml
import ../semver

type
  ManifestKind* = enum
    mkNimble
    mkJson
    mkToml

  ProjectManifest* = object
    manifestKind*: ManifestKind
    filePath*: string

proc displayName*(manifest: ProjectManifest): string =
  case manifest.manifestKind
  of mkNimble:
    "Nimble"
  of mkJson, mkToml:
    manifest.filePath.extractFilename()

func manifestKindOf(filePath: string): Option[ManifestKind] =
  if filePath.endsWith(".nimble"):
    some(mkNimble)
  elif filePath.endsWith(".json"):
    some(mkJson)
  elif filePath.endsWith(".toml"):
    some(mkToml)
  else:
    none(ManifestKind)

proc manifestFromPath*(filePath: string): Result[ProjectManifest, string] =
  if not fileAt(filePath):
    return err("Manifest not found at " & filePath)
  let maybeKind = manifestKindOf(filePath)
  if maybeKind.isNone:
    return err(
      "Unsupported project manifest: " & filePath &
        ". A manifest is a .nimble, .json or .toml file."
    )
  ok(ProjectManifest(manifestKind: maybeKind.get, filePath: filePath))

const KnownManifestNames =
  ["package.json", "tree-sitter.json", "Cargo.toml", "extension.toml"]
  ## The JSON and TOML manifests found in a repository root by name. Their
  ## extensions alone would also find configuration files without a version.

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
  for knownName in KnownManifestNames:
    if knownName in entryNames:
      result.add(knownName)

proc manifestAt*(filePath: string): ProjectManifest =
  ## The manifest a path names, going by the name alone. Unlike
  ## `manifestFromPath` this does not require the file to be there, which a
  ## past commit's manifest need no longer be.
  ProjectManifest(
    manifestKind: manifestKindOf(filePath).get(mkJson), filePath: filePath
  )

proc findRootManifests*(repoRoot: string): Result[seq[ProjectManifest], string] =
  ## Every supported manifest sitting directly in the repository root, in a
  ## stable order. More than one means the repository versions several packages
  ## from the same directory, which the caller has to make sense of.
  let entryNames = (?filesIn(repoRoot)).mapIt(it.extractFilename())
  ok(rootManifestNames(entryNames).mapIt(manifestAt(repoRoot / it)))

proc readVersion*(manifest: ProjectManifest): Result[SemVer, string] =
  case manifest.manifestKind
  of mkNimble:
    nimble.readVersion(manifest.filePath)
  of mkJson:
    readJsonVersion(manifest.filePath)
  of mkToml:
    readTomlVersion(manifest.filePath)

proc versionWritten*(
    manifest: ProjectManifest, newVersion: SemVer
): Result[string, string] =
  ## The manifest's contents with `newVersion` written in, everything else left
  ## as it was.
  case manifest.manifestKind
  of mkNimble:
    nimble.versionWritten(manifest.filePath, newVersion)
  of mkJson:
    jsonVersionWritten(manifest.filePath, newVersion)
  of mkToml:
    tomlVersionWritten(manifest.filePath, newVersion)
