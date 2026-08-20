## Resolves configured packages and attributes changed files to them.
##
## A changed file belongs to the package whose manifest is its nearest
## ancestor. Since packages own distinct directories, that is unambiguous:
## the longest matching package directory wins.

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

  Workspace* = object
    strategy*: WorkspaceStrategy
    sharedChanges*: SharedChangesPolicy
    packages*: seq[WorkspacePackage]
    hasExplicitPackages*: bool
      ## False when the single package was detected rather than configured, in
      ## which case releases keep the flat `vX.Y.Z` naming.

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
    name, manifestRelativePath: string, manifest: ProjectManifest
): WorkspacePackage =
  WorkspacePackage(
    name: name,
    manifest: manifest,
    manifestRelativePath: manifestRelativePath,
    rootDirectory: manifestRootDirectory(manifestRelativePath),
  )

proc validateDistinctRootDirectories(packages: seq[WorkspacePackage]) =
  ## Two manifests in one directory would make nearest-ancestor attribution
  ## ambiguous, so they are rejected rather than resolved arbitrarily.
  var packageNamesByDirectory = initTable[string, string]()
  for package in packages:
    if packageNamesByDirectory.hasKey(package.rootDirectory):
      raise newException(
        IOError,
        "Packages '" & packageNamesByDirectory[package.rootDirectory] & "' and '" &
          package.name & "' share the same directory. Each package needs its own.",
      )
    packageNamesByDirectory[package.rootDirectory] = package.name

proc loadWorkspace*(repoRoot: string, config: Config): Workspace =
  result =
    Workspace(strategy: config.workspaceStrategy, sharedChanges: config.sharedChanges)

  result.hasExplicitPackages = config.packages.len > 0

  if config.packages.len == 0:
    let detectedManifest = findProjectManifest(repoRoot)
    result.packages.add(
      newWorkspacePackage(
        "root",
        normalizeRepoPath(relativePath(detectedManifest.filePath, repoRoot)),
        detectedManifest,
      )
    )
    return

  for packageConfig in config.packages:
    let manifestRelativePath = normalizeRepoPath(packageConfig.manifestPath)
    result.packages.add(
      newWorkspacePackage(
        packageConfig.name,
        manifestRelativePath,
        manifestFromPath(repoRoot / manifestRelativePath),
      )
    )

  validateDistinctRootDirectories(result.packages)

proc packageNames*(workspace: Workspace): seq[string] =
  for package in workspace.packages:
    result.add(package.name)

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

proc affectedPackageNames*(
    workspace: Workspace, changedPaths: seq[string]
): seq[string] =
  var affectedPackageNames = initHashSet[string]()

  for rawChangedPath in changedPaths:
    let changedPath = normalizeRepoPath(rawChangedPath)
    if changedPath.startsWith(ChangesRelPrefix):
      continue

    let nearestIndex = workspace.nearestPackageIndex(changedPath)
    if nearestIndex >= 0:
      affectedPackageNames.incl(workspace.packages[nearestIndex].name)
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
