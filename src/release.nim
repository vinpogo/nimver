import std/[os, strutils, sequtils, tables]
import config
import changes
import adapters/manifest
import changelog
import semver
import workspace
import history

const ChangelogName = "CHANGELOG.md"

type PackageRelease* = object
  ## One planned release: what it moves to, the changes that say so, and every
  ## manifest that carries the new version. Planning every release before
  ## writing anything keeps a release of several packages a single commit.
  name*: string
    ## The package being released, empty when the release covers the repository
    ## as a whole.
  manifests*: seq[ProjectManifest]
    ## Plural because a fixed workspace moves every manifest to one version.
  entries*: seq[ChangeEntry]
  current*, next*: SemVer
  level*: BumpLevel
  section*: string
  changelogPath*: string
  tag*: string

type ChangelogWrite* = object
  ## One changelog file and everything this run prepends to it. Packages that
  ## share a file are folded into a single write: prepending once per release
  ## would push each section above the one written a moment earlier, so the
  ## file would end up in reverse order.
  path*: string
  text*: string

func releasesPackagesApart(projectWorkspace: Workspace): bool =
  ## Only then does a release have to name its package - in its tag, in the
  ## commit subject, and in the progress line.
  projectWorkspace.strategy == wsIndependent and projectWorkspace.packages.len > 1

func highestBumpLevel*(entries: seq[ChangeEntry]): BumpLevel =
  entries.foldl(if b.bumpLevel > a: b.bumpLevel else: a, blNone)

func hasPendingChanges*(release: PackageRelease): bool =
  release.entries.len > 0

func isReleasable*(release: PackageRelease): bool =
  release.hasPendingChanges() and release.level != blNone

func releaseLabelFor*(projectWorkspace: Workspace, release: PackageRelease): string =
  if projectWorkspace.releasesPackagesApart(): release.name else: "version"

func releaseTagFor(
    projectWorkspace: Workspace, packageName: string, version: SemVer
): string =
  if projectWorkspace.releasesPackagesApart():
    packageName & "-v" & $version
  else:
    "v" & $version

proc changelogPathFor(repoRoot: string, package: WorkspacePackage): string =
  ## An independently versioned package keeps its changelog next to its
  ## manifest, since its version moves on its own schedule. Sibling manifests
  ## resolve to the same path and therefore share one changelog.
  if package.rootDirectory.len == 0:
    repoRoot / ChangelogName
  else:
    repoRoot / package.rootDirectory / ChangelogName

proc changelogPackageLabelFor(
    repoRoot: string, projectWorkspace: Workspace, package: WorkspacePackage
): string =
  ## Packages sharing a changelog have to name themselves in it: a bare version
  ## would not say which of them moved. A package with a changelog of its own
  ## keeps the plain `## [1.2.0]` heading.
  let changelogPath = changelogPathFor(repoRoot, package)
  for other in projectWorkspace.packages:
    if other.name != package.name and changelogPathFor(repoRoot, other) == changelogPath:
      return package.name
  ""

proc planRelease*(
    repoRoot: string,
    projectWorkspace: Workspace,
    currentConfig: NimverConfig,
    package: WorkspacePackage,
): PackageRelease =
  ## Every package reads its own stretch of history, ending at its own last
  ## release. A change touching two packages is therefore counted once for
  ## each, however far apart the two last went out - which is the whole point
  ## of releasing them independently.
  result.name = package.name
  result.manifests = @[package.manifest]
  result.entries = pendingChanges(
      repoRoot,
      currentConfig,
      newReleaseNaming(package.name, projectWorkspace.releasesPackagesApart()),
    )
    .filterIt(
      package.name in it.affectedPackages or
      # Before a workspace gains a second package, a lone auto-detected
      # manifest is named `root` (package.json has no name in its filename).
      # Accept those historical changes for whichever package now sits at the
      # repo root so the boundary is not lost on transition.
      (package.rootDirectory.len == 0 and "root" in it.affectedPackages)
    )
  result.level = highestBumpLevel(result.entries)
  if not result.isReleasable():
    return

  result.current = readVersion(package.manifest)
  result.next = bump(result.current, result.level)
  result.section = buildSection(
    result.next,
    result.entries,
    changelogPackageLabelFor(repoRoot, projectWorkspace, package),
  )
  result.changelogPath = changelogPathFor(repoRoot, package)
  result.tag = releaseTagFor(projectWorkspace, package.name, result.next)

proc fixedReleaseNaming(projectWorkspace: Workspace): ReleaseNaming =
  ## One version for the whole repository, so one stretch of history behind it.
  ## A lone package's name is still worth knowing: the namespaced tags it wrote
  ## while the workspace had siblings end the range too.
  let survivingName =
    if projectWorkspace.packages.len == 1:
      projectWorkspace.packages[0].name
    else:
      ""
  newReleaseNaming(survivingName, namespaced = false)

proc sharedCurrentVersion(packages: seq[WorkspacePackage]): SemVer =
  ## The one version a fixed workspace is on. Manifests that disagree have to be
  ## reconciled by hand: picking one of them would silently move the others.
  result = readVersion(packages[0].manifest)
  for package in packages[1 .. ^1]:
    let packageVersion = readVersion(package.manifest)
    if packageVersion != result:
      raise newException(
        IOError,
        "Fixed workspace manifests must have the same version: package '" &
          packages[0].name & "' is " & $result & ", package '" & package.name & "' is " &
          $packageVersion,
      )

proc planFixedRelease*(
    repoRoot: string, projectWorkspace: Workspace, currentConfig: NimverConfig
): PackageRelease =
  ## The whole repository moving at once: one version across every manifest, one
  ## changelog section at the repository root, one tag.
  result.manifests = projectWorkspace.packages.mapIt(it.manifest)
  result.entries =
    pendingChanges(repoRoot, currentConfig, fixedReleaseNaming(projectWorkspace))
  result.level = highestBumpLevel(result.entries)
  if not result.isReleasable():
    return

  result.current = sharedCurrentVersion(projectWorkspace.packages)
  result.next = bump(result.current, result.level)
  result.section = buildSection(result.next, result.entries)
  result.changelogPath = repoRoot / ChangelogName
  result.tag = releaseTagFor(projectWorkspace, result.name, result.next)

proc changelogWrites*(releases: seq[PackageRelease]): seq[ChangelogWrite] =
  var writeIndexByPath = initTable[string, int]()
  for release in releases:
    if writeIndexByPath.hasKey(release.changelogPath):
      result[writeIndexByPath[release.changelogPath]].text.add("\n" & release.section)
    else:
      writeIndexByPath[release.changelogPath] = result.len
      result.add(ChangelogWrite(path: release.changelogPath, text: release.section))

proc releaseCommitSubject*(
    projectWorkspace: Workspace, releases: seq[PackageRelease]
): string =
  ## Releasing several independently versioned packages has no single version
  ## to name, so the subject lists the tags the commit is about to carry.
  if releases.len != 1:
    "version: " & releases.mapIt(it.tag).join(", ")
  elif projectWorkspace.releasesPackagesApart():
    "version(" & releases[0].name & "): v" & $releases[0].next
  else:
    "version: v" & $releases[0].next
