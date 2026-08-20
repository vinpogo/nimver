## Resolves configured packages and attributes changed files to them.
##
## A changed file belongs to the package whose manifest is its nearest
## ancestor: the longest matching package directory wins. A package may narrow
## that with explicit `sourceFiles` patterns, which take precedence.
##
## Packages sharing a directory are only coherent under `fixed`, where every
## package moves to the same version anyway.

import std/[os, sets, strutils, tables]
import ./changes
import ./config
import ./adapters/manifest

type
  WorkspacePackage* = object
    name*: string
    manifest*: ProjectManifest
    manifestRelativePath*: string
    rootDirectory*: string
      ## Repo-relative directory holding the manifest; empty at the repo root.
    sourceFilePatterns*: seq[string]
      ## Optional globs. When empty, the package claims files by nearest
      ## ancestor instead.

  Workspace* = object
    strategy*: WorkspaceStrategy
    sharedChanges*: SharedChangesPolicy
    packages*: seq[WorkspacePackage]

proc normalizeRepoPath(path: string): string =
  result = path.replace('\\', '/')
  while result.startsWith("./"):
    result = result[2 .. ^1]
  if result == ".":
    result = ""

proc manifestRootDirectory(manifestRelativePath: string): string =
  let lastSeparatorIndex = manifestRelativePath.rfind('/')
  if lastSeparatorIndex == -1:
    ""
  else:
    manifestRelativePath[0 ..< lastSeparatorIndex]

proc newWorkspacePackage(
    name, manifestRelativePath: string,
    manifest: ProjectManifest,
    sourceFilePatterns: seq[string] = @[],
): WorkspacePackage =
  WorkspacePackage(
    name: name,
    manifest: manifest,
    manifestRelativePath: manifestRelativePath,
    rootDirectory: manifestRootDirectory(manifestRelativePath),
    sourceFilePatterns: sourceFilePatterns,
  )

proc globMatches(pattern, path: string): bool =
  ## `*` stops at a path separator, `**` crosses them, `?` matches one
  ## non-separator character.
  let normalizedPattern = normalizeRepoPath(pattern)
  let normalizedPath = normalizeRepoPath(path)
  var matchedStates = initTable[(int, int), bool]()

  proc matches(patternIndex, pathIndex: int): bool =
    let state = (patternIndex, pathIndex)
    if matchedStates.hasKey(state):
      return matchedStates[state]

    if patternIndex == normalizedPattern.len:
      result = pathIndex == normalizedPath.len
    elif normalizedPattern[patternIndex] == '*':
      let crossesSeparators =
        patternIndex + 1 < normalizedPattern.len and
        normalizedPattern[patternIndex + 1] == '*'
      if crossesSeparators:
        result =
          matches(patternIndex + 2, pathIndex) or
          (pathIndex < normalizedPath.len and matches(patternIndex, pathIndex + 1))
      else:
        result =
          matches(patternIndex + 1, pathIndex) or (
            pathIndex < normalizedPath.len and normalizedPath[pathIndex] != '/' and
            matches(patternIndex, pathIndex + 1)
          )
    elif normalizedPattern[patternIndex] == '?':
      result =
        pathIndex < normalizedPath.len and normalizedPath[pathIndex] != '/' and
        matches(patternIndex + 1, pathIndex + 1)
    else:
      result =
        pathIndex < normalizedPath.len and
        normalizedPattern[patternIndex] == normalizedPath[pathIndex] and
        matches(patternIndex + 1, pathIndex + 1)

    matchedStates[state] = result

  matches(0, 0)

proc packageNames*(workspace: Workspace): seq[string] =
  for package in workspace.packages:
    result.add(package.name)

proc validateIndependentPackagesAreSeparable(packages: seq[WorkspacePackage]) =
  ## Under `independent` each package is released on its own, so every change
  ## has to belong to exactly one of them. Two manifests in the same directory
  ## make that undecidable, so the configuration is rejected outright.
  var packageNamesByDirectory = initTable[string, string]()
  for package in packages:
    if packageNamesByDirectory.hasKey(package.rootDirectory):
      let directoryLabel =
        if package.rootDirectory.len == 0:
          "the repository root"
        else:
          "'" & package.rootDirectory & "'"
      raise newException(
        IOError,
        "Invalid configuration: packages '" &
          packageNamesByDirectory[package.rootDirectory] & "' and '" & package.name &
          "' both live in " & directoryLabel &
          ". With strategy = independent each package is released separately, so a change in that directory could belong to either one and nimver cannot tell them apart. Give each package its own directory, or use strategy = fixed to release them together.",
      )
    packageNamesByDirectory[package.rootDirectory] = package.name

proc loadWorkspace*(repoRoot: string, config: Config): Workspace =
  result =
    Workspace(strategy: config.workspaceStrategy, sharedChanges: config.sharedChanges)

  if config.packages.len == 0:
    let detectedManifests = findRootManifests(repoRoot)
    if detectedManifests.len == 0:
      raise newException(
        IOError,
        "No supported project manifest found. Expected a .nimble file or package.json.",
      )

    for detectedManifest in detectedManifests:
      let manifestRelativePath =
        normalizeRepoPath(relativePath(detectedManifest.filePath, repoRoot))
      # A lone manifest keeps the name `root`, which is what release naming and
      # `sharedChanges = package.root` refer to.
      let packageName = if detectedManifests.len == 1: "root" else: manifestRelativePath
      result.packages.add(
        newWorkspacePackage(packageName, manifestRelativePath, detectedManifest)
      )

    if detectedManifests.len > 1:
      # Siblings cannot be told apart by nearest ancestor, so they can only be
      # released together. Say so rather than guessing silently.
      if config.strategyWasSpecified and config.workspaceStrategy == wsIndependent:
        validateIndependentPackagesAreSeparable(result.packages)
      result.strategy = wsFixed
      stderr.writeLine(
        "nimver: found " & $detectedManifests.len & " manifests in the repository root (" &
          result.packageNames().join(", ") &
          "); assuming strategy = fixed. Declare them under [workspace] in .nimver/config.ini to silence this."
      )
    return

  for packageConfig in config.packages:
    let manifestRelativePath = normalizeRepoPath(packageConfig.manifestPath)
    result.packages.add(
      newWorkspacePackage(
        packageConfig.name,
        manifestRelativePath,
        manifestFromPath(repoRoot / manifestRelativePath),
        packageConfig.sourceFilePatterns,
      )
    )

  if result.strategy == wsIndependent:
    validateIndependentPackagesAreSeparable(result.packages)

proc findPackage*(workspace: Workspace, name: string): WorkspacePackage =
  for package in workspace.packages:
    if package.name == name:
      return package
  raise newException(
    IOError,
    "Unknown package '" & name & "'. Configured packages: " &
      workspace.packageNames().join(", "),
  )

proc effectivePackages*(workspace: Workspace, entry: ChangeEntry): seq[string] =
  ## Notes recorded before per-package attribution existed carry no `packages`
  ## list, so they count for every package.
  if entry.affectedPackages.len == 0:
    workspace.packageNames()
  else:
    entry.affectedPackages

proc containsPath(packageRootDirectory, changedPath: string): bool =
  packageRootDirectory.len == 0 or changedPath.startsWith(packageRootDirectory & "/")

proc nearestPackageIndex(workspace: Workspace, changedPath: string): int =
  ## Index of the package whose manifest is the nearest ancestor of
  ## `changedPath`, or -1 when the file sits outside every package.
  result = -1
  for packageIndex, package in workspace.packages:
    if package.rootDirectory.containsPath(changedPath) and (
      result == -1 or
      package.rootDirectory.len > workspace.packages[result].rootDirectory.len
    ):
      result = packageIndex

proc owningPackageIndex(workspace: Workspace, changedPath: string): int =
  ## Explicit `sourceFiles` win, then the manifest itself, then the nearest
  ## ancestor. Returns -1 for a file no package claims.
  var matchingPackageIndexes: seq[int] = @[]
  for packageIndex, package in workspace.packages:
    for sourceFilePattern in package.sourceFilePatterns:
      if globMatches(sourceFilePattern, changedPath):
        matchingPackageIndexes.add(packageIndex)
        break

  if matchingPackageIndexes.len > 1:
    var matchingPackageNames: seq[string] = @[]
    for packageIndex in matchingPackageIndexes:
      matchingPackageNames.add(workspace.packages[packageIndex].name)
    raise newException(
      IOError,
      "Changed path '" & changedPath & "' matches the sourceFiles of " &
        matchingPackageNames.join(" and ") & ". Patterns must not overlap.",
    )
  if matchingPackageIndexes.len == 1:
    return matchingPackageIndexes[0]

  for packageIndex, package in workspace.packages:
    if changedPath == package.manifestRelativePath:
      return packageIndex

  workspace.nearestPackageIndex(changedPath)

proc affectedPackageNames*(
    workspace: Workspace, changedPaths: seq[string]
): seq[string] =
  var affectedPackageNames = initHashSet[string]()

  for rawChangedPath in changedPaths:
    let changedPath = normalizeRepoPath(rawChangedPath)
    if changedPath.startsWith(ChangesRelPrefix):
      continue

    let owningIndex = workspace.owningPackageIndex(changedPath)
    if owningIndex >= 0:
      affectedPackageNames.incl(workspace.packages[owningIndex].name)
    else:
      case workspace.sharedChanges.kind
      of scAll:
        for package in workspace.packages:
          affectedPackageNames.incl(package.name)
      of scNone:
        discard
      of scPackage:
        affectedPackageNames.incl(workspace.sharedChanges.packageName)

  for package in workspace.packages:
    if package.name in affectedPackageNames:
      result.add(package.name)
