import std/[options, strutils, sequtils, tables]
import ./sysio
import config
import changes
import adapters/manifest
import changelog
import semver
import track
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
    ## What the changelog section lists: the changes since the last version,
    ## which on a track is the one before this prerelease.
  current*, next*: SemVer
  level*: BumpLevel
    ## Across every commit since the last release, so it decides the core -
    ## a track's second prerelease is still `minor` over the same range, not a
    ## second minor on top of the first.
  trackLevel*: BumpLevel
    ## Across `entries` alone, so it decides whether there is anything to cut.
    ## The two differ only on a track: at `1.2.0-alpha.1`, a lone `docs:` is
    ## `none` here while `level` stays `minor`, and nothing should go out.
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
  release.hasPendingChanges() and release.trackLevel != blNone

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

func claimedBy(entries: seq[ChangeEntry], package: WorkspacePackage): seq[ChangeEntry] =
  entries.filterIt(
    package.name in it.affectedPackages or
    # Before a workspace gains a second package, a lone auto-detected
    # manifest is named `root` (package.json has no name in its filename).
    # Accept those historical changes for whichever package now sits at the
    # repo root so the boundary is not lost on transition.
    (package.rootDirectory.len == 0 and "root" in it.affectedPackages)
  )

proc taggableVersion(manifests: seq[ProjectManifest]): Option[SemVer] =
  ## The version to advise tagging, and nothing at all when there is none worth
  ## advising. A prerelease is no record of a release that happened, and a
  ## manifest nobody can read a version out of is the next complaint `bump`
  ## makes on its own - neither is a reason for a refusal to fail instead of
  ## being printed.
  for manifest in manifests:
    try:
      let version = readVersion(manifest)
      if not version.isPrerelease():
        return some(version)
    except CatchableError:
      discard
  none(SemVer)

func noReleaseToBuildOn(
    naming: ReleaseNaming, track: Track, advisedVersion: Option[SemVer]
): ref IOError =
  ## One refusal with two faces. On a track there is no release to measure the
  ## prerelease from; off one the manifest's version is itself the only record
  ## of an untagged history, so bumping it would charge for those changes twice.
  ##
  ## The tag prefix comes from the naming rather than the package name: a lone
  ## package is released as `v1.2.3`, and advising `pkg-v1.2.3` would hand back
  ## a tag nothing recognises.
  let named =
    if naming.packageName.len > 0:
      "package '" & naming.packageName & "' has"
    else:
      "this repository has"
  let tagName =
    naming.tagPrefix & (
      if advisedVersion.isSome():
        $advisedVersion.get
      else:
        "<version>"
    )
  let rest =
    if track.hasTrack:
      "so a prerelease on track '" & track.name &
        "' has nothing to be based on. Tag the release it builds on (`git tag " & tagName &
        "`), then bump again."
    else:
      "so there is nothing to bump from: the version in the manifest already accounts for that history, and releasing from it would count the same changes twice. Tag the version it is already on (`git tag " &
        tagName & "`), then bump again."
  newException(IOError, named & " no release tag in this branch's history, " & rest)

func baseVersionFor(sinceRelease: PendingChanges, manifestVersion: SemVer): SemVer =
  ## What to bump from.
  ##
  ## The manifest, as long as it holds a release - which is every case there
  ## was before tracks, and the first prerelease after a release too. Once it
  ## holds a prerelease it cannot serve: `1.2.0-alpha.3` already *is* the
  ## result of bumping the release behind it, so bumping it again would pay for
  ## the same minor twice, and coming off the track would give 1.2.1 where
  ## 1.2.0 was meant.
  ##
  ## That leaves the release the walk stopped at, and nothing else will do.
  ## Taking the prerelease's own core would drift the version upward once per
  ## iteration; taking 0.0.0 would quietly rewrite a 3.4.5 project downwards.
  ##
  ## There is always one to take: a walk that met no version at all is refused
  ## before a version is ever planned.
  if not manifestVersion.isPrerelease():
    return manifestVersion
  sinceRelease.boundaryVersion.get.core

proc planVersion(
    repoRoot: string,
    naming: ReleaseNaming,
    currentConfig: NimverConfig,
    track: Track,
    package: WorkspacePackage,
    release: var PackageRelease,
) =
  ## The two walks a version needs, and what each answers. Off a track they are
  ## the same walk: the boundaries coincide, so there is nothing to ask twice.
  let notesBoundary = if track.hasTrack: vbAnyVersion else: vbRelease
  let notes = pendingChanges(repoRoot, currentConfig, naming, notesBoundary)
  release.entries = notes.entries.claimedBy(package)
  release.trackLevel = highestBumpLevel(release.entries)

  let sinceRelease =
    if track.hasTrack:
      pendingChanges(repoRoot, currentConfig, naming, vbRelease)
    else:
      notes
  # Before releasability: having a release behind you is a property of the
  # repository, not of what happens to be pending. Asked the other way round, a
  # repository of nothing but `chore:` commits would report nothing to bump and
  # then refuse the moment a `feat:` landed.
  if sinceRelease.boundaryVersion.isNone():
    raise noReleaseToBuildOn(naming, track, taggableVersion(@[package.manifest]))
  release.level = highestBumpLevel(sinceRelease.entries.claimedBy(package))
  if not release.isReleasable():
    return

  release.current = readVersion(package.manifest)
  let core = bump(baseVersionFor(sinceRelease, release.current), release.level)
  release.next =
    if track.hasTrack:
      core.onTrack(track.name, nextIteration(repoRoot, naming, core))
    else:
      core

proc planRelease*(
    repoRoot: string,
    projectWorkspace: Workspace,
    currentConfig: NimverConfig,
    package: WorkspacePackage,
    track = noTrack(),
): PackageRelease =
  ## Every package reads its own stretch of history, ending at its own last
  ## release. A change touching two packages is therefore counted once for
  ## each, however far apart the two last went out - which is the whole point
  ## of releasing them independently.
  result.name = package.name
  result.manifests = @[package.manifest]
  let naming =
    newReleaseNaming(package.name, projectWorkspace.releasesPackagesApart(), track)
  planVersion(repoRoot, naming, currentConfig, track, package, result)
  if not result.isReleasable():
    return

  result.section = buildSection(
    result.next,
    result.entries,
    changelogPackageLabelFor(repoRoot, projectWorkspace, package),
  )
  result.changelogPath = changelogPathFor(repoRoot, package)
  result.tag = releaseTagFor(projectWorkspace, package.name, result.next)

proc fixedReleaseNaming(projectWorkspace: Workspace, track: Track): ReleaseNaming =
  ## One version for the whole repository, so one stretch of history behind it.
  ## A lone package's name is still worth knowing: the namespaced tags it wrote
  ## while the workspace had siblings end the range too.
  let survivingName =
    if projectWorkspace.packages.len == 1:
      projectWorkspace.packages[0].name
    else:
      ""
  newReleaseNaming(survivingName, namespaced = false, track = track)

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
    repoRoot: string,
    projectWorkspace: Workspace,
    currentConfig: NimverConfig,
    track = noTrack(),
): PackageRelease =
  ## The whole repository moving at once: one version across every manifest, one
  ## changelog section at the repository root, one tag - and therefore one
  ## track, whatever any package might have asked for.
  result.manifests = projectWorkspace.packages.mapIt(it.manifest)
  let naming = fixedReleaseNaming(projectWorkspace, track)
  let notesBoundary = if track.hasTrack: vbAnyVersion else: vbRelease
  let notes = pendingChanges(repoRoot, currentConfig, naming, notesBoundary)
  result.entries = notes.entries
  result.trackLevel = highestBumpLevel(result.entries)

  let sinceRelease =
    if track.hasTrack:
      pendingChanges(repoRoot, currentConfig, naming, vbRelease)
    else:
      notes
  if sinceRelease.boundaryVersion.isNone():
    raise noReleaseToBuildOn(naming, track, taggableVersion(result.manifests))
  result.level = highestBumpLevel(sinceRelease.entries)
  if not result.isReleasable():
    return

  result.current = sharedCurrentVersion(projectWorkspace.packages)
  let core = bump(baseVersionFor(sinceRelease, result.current), result.level)
  result.next =
    if track.hasTrack:
      core.onTrack(track.name, nextIteration(repoRoot, naming, core))
    else:
      core
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
