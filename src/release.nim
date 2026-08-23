import std/[os, strutils, sequtils, tables]
import config
import changes
import adapters/manifest
import changelog
import semver
import workspace
import history

type PackageRelease* = object
  ## One package's planned release: what it moves to, and the changes that say
  ## so. Planning every package before writing anything keeps a release of
  ## several packages a single commit.
  package*: WorkspacePackage
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

func hasSeveralPackages(projectWorkspace: Workspace): bool =
  projectWorkspace.packages.len > 1

func releaseNamingFor(
    projectWorkspace: Workspace, package: WorkspacePackage
): ReleaseNaming =
  newReleaseNaming(package.name, projectWorkspace.hasSeveralPackages())

func highestBumpLevel*(entries: seq[ChangeEntry]): BumpLevel =
  entries.foldl(if b.bumpLevel > a: b.bumpLevel else: a, blNone)

proc changelogPathFor(repoRoot: string, package: WorkspacePackage): string =
  ## An independently versioned package keeps its changelog next to its
  ## manifest, since its version moves on its own schedule. Sibling manifests
  ## resolve to the same path and therefore share one changelog.
  if package.rootDirectory.len == 0:
    repoRoot / "CHANGELOG.md"
  else:
    repoRoot / package.rootDirectory / "CHANGELOG.md"

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

proc releaseTagFor(
    projectWorkspace: Workspace, package: WorkspacePackage, version: SemVer
): string =
  if projectWorkspace.hasSeveralPackages():
    package.name & "-v" & $version
  else:
    "v" & $version

proc releaseCommitSubjectFor(
    projectWorkspace: Workspace, package: WorkspacePackage, version: SemVer
): string =
  if projectWorkspace.hasSeveralPackages():
    "version(" & package.name & "): v" & $version
  else:
    "version: v" & $version

proc releaseLabelFor*(projectWorkspace: Workspace, package: WorkspacePackage): string =
  ## What the release is called in progress output: the package name when
  ## several exist, otherwise the same wording as a fixed release.
  if projectWorkspace.hasSeveralPackages(): package.name else: "version"

proc hasPendingChanges*(release: PackageRelease): bool =
  release.entries.len > 0

proc isReleasable*(release: PackageRelease): bool =
  release.hasPendingChanges() and release.level != blNone

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
  result.package = package
  result.entries = pendingChanges(
      repoRoot, currentConfig, releaseNamingFor(projectWorkspace, package)
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
  result.tag = releaseTagFor(projectWorkspace, package, result.next)

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
  if releases.len == 1:
    releaseCommitSubjectFor(projectWorkspace, releases[0].package, releases[0].next)
  else:
    "version: " & releases.mapIt(it.tag).join(", ")
