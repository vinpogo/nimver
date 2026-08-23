import std/[os, sets, strutils, tables, options]
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
    sourceFilePatterns*: Option[seq[string]]
      ## Optional globs. When empty, the package claims files by nearest
      ## ancestor instead.

  Workspace* = object
    strategy*: WorkspaceStrategy
    sharedChanges*: SharedChangesKind
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
    sourceFilePatterns: Option[seq[string]] = none[seq[string]](),
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

proc workspaceLayout*(
    repoRoot: string,
    config: NimverConfig,
    detectedManifestNames: seq[string],
    quiet = false,
): Workspace =
  ## The packages a configuration describes, and how changed files map onto
  ## them. `detectedManifestNames` supplies the repository root's manifests for
  ## the case where the config declares no packages of its own; it comes from
  ## the working tree for a release, and from a commit's own tree when reading
  ## history back, so that a change is attributed the way the repository was
  ## laid out when it was made.
  ##
  ## Manifests are not required to exist: one that a past commit had may be
  ## long gone. Only a package actually being released is read from disk.
  ## `quiet` silences the advice about detected siblings, which is worth saying
  ## once about the working tree and never about each commit behind it.
  result =
    Workspace(strategy: config.workspaceStrategy, sharedChanges: config.sharedChanges)

  if config.packages.len == 0:
    if detectedManifestNames.len == 0:
      raise newException(
        IOError,
        "No supported project manifest found. Expected a .nimble file or package.json.",
      )

    for manifestName in detectedManifestNames:
      # Derive a stable package name so history attribution survives a
      # transition from single-package to multi-package. A nimble file
      # contributes its stem (`cli.nimble` -> `cli`); `package.json` cannot
      # be named from the filename alone, so it falls back to `root`.
      let packageName =
        if detectedManifestNames.len != 1:
          manifestName
        elif manifestName.endsWith(".nimble"):
          manifestName[0 ..< manifestName.len - ".nimble".len]
        else:
          "root"
      result.packages.add(
        newWorkspacePackage(
          packageName, manifestName, manifestAt(repoRoot / manifestName)
        )
      )

    if detectedManifestNames.len > 1:
      # Nothing in the config says how detected siblings relate, and nearest
      # ancestor cannot tell them apart, so release them together unless the
      # config asked for separate releases outright.
      if config.strategyWasSpecified and config.workspaceStrategy == wsIndependent:
        if not quiet:
          stderr.writeLine(
            "nimver: found " & $detectedManifestNames.len &
              " manifests in the repository root (" & result.packageNames().join(", ") &
              "); releasing them independently. They share a directory, so every change follows sharedChanges. Declare them under [workspace] in .nimver/config.ini with sourceFiles to attribute changes per package."
          )
      else:
        result.strategy = wsFixed
        if not quiet:
          stderr.writeLine(
            "nimver: found " & $detectedManifestNames.len &
              " manifests in the repository root (" & result.packageNames().join(", ") &
              "); assuming strategy = fixed. Declare them under [workspace] in .nimver/config.ini to silence this."
          )
    return

  for packageConfig in config.packages:
    let manifestRelativePath = normalizeRepoPath(packageConfig.manifestPath)
    result.packages.add(
      newWorkspacePackage(
        packageConfig.name,
        manifestRelativePath,
        manifestAt(repoRoot / manifestRelativePath),
        packageConfig.sourceFilePatterns,
      )
    )

proc loadWorkspace*(repoRoot: string, config: NimverConfig): Workspace =
  ## The workspace as the working tree has it, which is the one a release acts
  ## on: every manifest it names has to be there to be read and rewritten.
  var detectedManifestNames: seq[string] = @[]
  for detectedManifest in findRootManifests(repoRoot):
    detectedManifestNames.add(
      normalizeRepoPath(relativePath(detectedManifest.filePath, repoRoot))
    )

  result = workspaceLayout(repoRoot, config, detectedManifestNames)
  for package in result.packages:
    discard manifestFromPath(package.manifest.filePath)

proc findPackage*(workspace: Workspace, name: string): WorkspacePackage =
  for package in workspace.packages:
    if package.name == name:
      return package
  raise newException(
    IOError,
    "Unknown package '" & name & "'. Configured packages: " &
      workspace.packageNames().join(", "),
  )

proc containsPath(packageRootDirectory, changedPath: string): bool =
  packageRootDirectory.len == 0 or changedPath.startsWith(packageRootDirectory & "/")

proc nearestPackageIndex(workspace: Workspace, changedPath: string): int =
  ## Index of the package whose manifest is the nearest ancestor of
  ## `changedPath`, or -1 when the file sits outside every package - or when
  ## packages sharing a directory tie for nearest, which leaves the file
  ## unattributable and hands it to `sharedChanges`.
  result = -1
  var nearestDepth = -1
  var tied = false
  for packageIndex, package in workspace.packages:
    if not package.rootDirectory.containsPath(changedPath):
      continue
    let depth = package.rootDirectory.len
    if depth > nearestDepth:
      nearestDepth = depth
      result = packageIndex
      tied = false
    elif depth == nearestDepth:
      tied = true
  if tied:
    result = -1

proc owningPackageIndex(workspace: Workspace, changedPath: string): int =
  ## Explicit `sourceFiles` win, then the manifest itself, then the nearest
  ## ancestor. Returns -1 for a file no package claims.
  var matchingPackageIndexes: seq[int] = @[]
  for packageIndex, package in workspace.packages:
    if package.sourceFilePatterns.isSome:
      for sourceFilePattern in package.sourceFilePatterns.get:
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
      case workspace.sharedChanges
      of scAll:
        for package in workspace.packages:
          affectedPackageNames.incl(package.name)
      of scNone:
        discard

  for package in workspace.packages:
    if package.name in affectedPackageNames:
      result.add(package.name)
