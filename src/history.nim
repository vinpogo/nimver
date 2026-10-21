import std/[algorithm, options, sequtils, strutils, tables]
import ./changes
import ./commitparser
import ./config
import ./effects
import ./gitutils
import ./adapters/manifest
import results
import ./semver
import ./track
import ./workspace

type
  ReleaseNaming* = object
    ## How releases of one package are named, which is also how they are
    ## recognised when reading back: `bump` writes these tags and subjects.
    tagPrefix*: string
      ## `v` on its own, or `<package>-v` when several packages are released apart.
    packageName*: string ## Empty when releases are not namespaced by package.
    legacyPrefix*: string
      ## The alternative prefix accepted alongside `tagPrefix` to survive a
      ## workspace shape change:
      ## - namespaced package: set to `v` so flat-era tags are still found
      ##   after the workspace gains a second package.
      ## - flat package: set to `<name>-v` so namespaced-era tags are still
      ##   found after the workspace drops back to a single package.
      ## Empty when no shape change has occurred.
    track*: Track
      ## The track the version being cut is on, which decides what bounds its
      ## changelog. Empty for a release.

  VersionBoundary* = enum
    ## What a walk back from HEAD is looking for. Known before it starts, so a
    ## walk never has to track two answers at once.
    vbRelease ## Only a release's tag ends it; prerelease tags are passed over.
    vbAnyVersion ## Any version tag does.

  Snapshot* = object
    ## How the repository was set up at some commit: what the types map to, and
    ## which packages a changed file can belong to.
    config: NimverConfig
    workspace: Workspace
    foreign: bool
      ## The commit's tree holds none of the project's manifests: it came in
      ## through a merge from another repository's history, a `git subtree`
      ## mirror's say, and is none of the project's changes.

proc newSnapshot*(config: NimverConfig, workspace: Workspace): Snapshot =
  Snapshot(config: config, workspace: workspace)

proc newReleaseNaming*(
    packageName: string, namespaced: bool, track = noTrack()
): ReleaseNaming =
  if namespaced:
    ReleaseNaming(
      tagPrefix: packageName & "-v",
      packageName: packageName,
      legacyPrefix: "v",
      track: track,
    )
  else:
    ReleaseNaming(
      tagPrefix: "v",
      packageName: "",
      legacyPrefix:
        if packageName.len > 0:
          packageName & "-v"
        else:
          "",
      track: track,
    )

func versionPart(naming: ReleaseNaming, tagName: string): Option[string] =
  ## What follows this package's tag prefix, when the tag carries one.
  ## `v1.2.0` and `web-v1.2.0` are versions; `verify-fix` and `webhooks` are
  ## not, hence the digit.
  func afterPrefix(tag, prefix: string): Option[string] =
    if tag.len > prefix.len and tag.startsWith(prefix) and tag[prefix.len].isDigit():
      some(tag[prefix.len .. ^1])
    else:
      none(string)

  result = tagName.afterPrefix(naming.tagPrefix)
  if result.isNone() and naming.legacyPrefix.len > 0:
    result = tagName.afterPrefix(naming.legacyPrefix)

func tagVersion(naming: ReleaseNaming, tagName: string): Option[SemVer] =
  ## The version a tag names, when it names one at all. `v1.0`, `v2` and
  ## `v20240101` carry this package's prefix and a digit and still yield
  ## nothing: nimver did not write them, and it cannot say which
  ## `major.minor.patch` they stand for.
  let written = naming.versionPart(tagName)
  if written.isNone():
    return none(SemVer)
  let version = parseSemVer(written.get)
  if version.isErr:
    return none(SemVer)
  some(version.value)

func endsRange(
    naming: ReleaseNaming, tagName: string, boundary: VersionBoundary
): Option[SemVer] =
  ## The version a tag ends the range at, or nothing when it does not end it.
  ##
  ## Bounding a range and reading a version used to be two questions, so that a
  ## tag nobody could parse still stopped a walk. It is one question now: a
  ## boundary nimver cannot name a base for is only an invitation to guess one,
  ## and a repository marked with nothing else is untagged as far as a release
  ## is concerned - which `bump` says out loud rather than working around.
  let version = naming.tagVersion(tagName)
  if version.isNone():
    return none(SemVer)
  case boundary
  of vbAnyVersion:
    version
  of vbRelease:
    if version.get.isPrerelease():
      none(SemVer)
    else:
      version

func endsTheRange(
    naming: ReleaseNaming,
    record: CommitRecord,
    tagsByCommit: Table[string, seq[string]],
    boundary: VersionBoundary,
): Option[SemVer] =
  ## A commit may carry several tags, and the first of them that ends the range
  ## decides. Nothing is lost by stopping there: a tag that ends a range now
  ## always carries the version it ends it at.
  for tagName in tagsByCommit.getOrDefault(record.hash):
    let version = naming.endsRange(tagName, boundary)
    if version.isSome():
      return version
  none(SemVer)

proc snapshotAt(
    repoRoot, revision: string, currentConfig: NimverConfig, effects: var Effects
): Result[Snapshot, string] =
  ## How the repository stood at a commit, read from that commit's own tree.
  ##
  ## Commits made before nimver was set up - or carrying a config that no
  ## longer parses, which a release is not the place to give up over - are read
  ## under the configuration as it is now.
  var snapshot = Snapshot(config: currentConfig)
  let contents = ?gitFileAtRevision(repoRoot, revision, ConfigRelPath)
  if contents.isSome():
    let config = parseConfig(contents.get, revision & ":" & ConfigRelPath)
    if config.isOk:
      snapshot.config = config.value
    else:
      effects.add(
        warn(
          "nimver: keeping the current configuration for " & revision[0 ..< 8] & ": " &
            config.error
        )
      )

  var detectedManifestNames: seq[string] = @[]
  if snapshot.config.packages.len == 0:
    detectedManifestNames = rootManifestNames(?gitRootEntryNames(repoRoot, revision))
  snapshot.workspace = workspaceLayout(repoRoot, snapshot.config, detectedManifestNames)
  snapshot.foreign =
    if snapshot.config.packages.len == 0:
      detectedManifestNames.len == 0
    else:
      (
        ?gitPathsAtRevision(
          repoRoot, revision, snapshot.workspace.packages.mapIt(it.manifestRelativePath)
        )
      ).len == 0
  ok(snapshot)

proc changesTheSetup(snapshot: Snapshot, record: CommitRecord): bool =
  ## Whether a commit is one the snapshot has to be re-read after. Reading it
  ## per commit would mean a couple of `git` calls each, which is most of the
  ## time a release spends; the config and the manifests change rarely, and a
  ## commit that changes none of them cannot have changed how its parent is
  ## read.
  for path in record.changedPaths:
    if path == ConfigRelPath:
      return true
    if snapshot.config.packages.len == 0:
      # Only a root entry can be part of the root listing.
      if '/' notin path and rootManifestNames(@[path]).len > 0:
        return true
    elif snapshot.workspace.packages.anyIt(it.manifestRelativePath == path):
      return true
  false

proc changeFor*(
    snapshot: Snapshot, record: CommitRecord, effects: var Effects
): Result[Option[ChangeEntry], string] =
  ## The change a commit stands for, or nothing when it is not one: an
  ## `ignore`d type, a message that is not a Conventional Commit, or a commit
  ## touching no package's files.
  let parsed = parseCommitMessage(record.message)
  if parsed.isErr:
    # Silent on purpose. Merges are already left out, and what is left is
    # history from before the hook was installed or from around it - not
    # something a release can do anything about.
    return ok(none(ChangeEntry))

  let maybeLevel = validateAndLookup(snapshot.config, parsed.value)
  if isNone(maybeLevel):
    effects.add(
      warn(
        "nimver: skipping " & record.hash[0 ..< 8] & ": unknown commit type '" &
          parsed.value.commitType & "'"
      )
    )
    return ok(none(ChangeEntry))
  if maybeLevel.get == blIgnore:
    return ok(none(ChangeEntry))

  let affected = ?affectedPackageNames(snapshot.workspace, record.changedPaths)
  if affected.len == 0:
    return ok(none(ChangeEntry))

  ok(
    some(
      ChangeEntry(
        commitType: parsed.value.commitType,
        scope: parsed.value.scope,
        bumpLevel: maybeLevel.get,
        breaking: parsed.value.breaking,
        affectedPackages: affected,
        message: parsed.value.rawMessage,
        releaseNote: parsed.value.releaseNote,
        breakingNote: parsed.value.breakingNote,
      )
    )
  )

type VersionRange = object
  records: seq[CommitRecord] ## Newest first.
  boundaryVersion: Option[SemVer]

proc commitsSinceLastVersion(
    repoRoot: string, naming: ReleaseNaming, boundary: VersionBoundary
): Result[VersionRange, string] =
  ## Newest first, stopping before the commit a version of this package went
  ## out with - which version counts as one is `boundary`'s question, and it is
  ## settled before the walk begins.
  var versionRange: VersionRange
  let tagsByCommit = ?gitTagsByCommit(repoRoot)
  for record in ?gitCommitsIn(repoRoot, "HEAD"):
    let boundaryVersion = naming.endsTheRange(record, tagsByCommit, boundary)
    if boundaryVersion.isSome():
      versionRange.boundaryVersion = boundaryVersion
      break
    versionRange.records.add(record)
  ok(versionRange)

type PendingChanges* = object
  entries*: seq[ChangeEntry] ## Oldest first - the order a changelog reads in.
  boundaryVersion*: Option[SemVer]
    ## The version of the tag the walk stopped at, and the only thing a base may
    ## be taken from. None means the walk ran out of history without meeting a
    ## version tag at all - there is no release behind these changes, and
    ## nothing to guess one from.

proc pendingChanges*(
    repoRoot: string,
    currentConfig: NimverConfig,
    naming: ReleaseNaming,
    effects: var Effects,
    boundary = vbRelease,
): Result[PendingChanges, string] =
  ## Every change since the last version of the package `naming` describes,
  ## oldest first - the order a changelog section reads in.
  ##
  ## The range ends at the first commit going back that such a version went out
  ## with. With none to be found the walk covers the whole history and
  ## `boundaryVersion` stays empty, which is no release anyone can plan: the
  ## version in the manifest already accounts for that history, so the planner
  ## refuses rather than counting it a second time. A repository adopting
  ## nimver says where its past ends by tagging the version it is already on.
  ##
  ## Nothing subtler than that on purpose. Cutting the range at, say, the
  ## commit that introduced `.nimver/config.ini` reads well until a rebase
  ## reorders that commit past its neighbours, at which point the changes
  ## behind it disappear from the release without a word.
  ##
  ## `boundary` is what a track changes: on one, the newest version tag of any
  ## kind ends the range, so a prerelease lists only what is new since the one
  ## before it. Off one, only a release does, so prerelease tags are passed over
  ## and the release covers the whole cycle.
  let versionRange = ?commitsSinceLastVersion(repoRoot, naming, boundary)

  var newestFirst: seq[ChangeEntry] = @[]
  var snapshot: Snapshot
  # A snapshot carries over only to the parent of the commit it was read at,
  # and only when that commit left the setup alone. The walk goes by date, so
  # after a merge the next commit may be on another line of history entirely.
  var snapshotHoldsFor = ""
  for record in versionRange.records:
    if record.hash != snapshotHoldsFor:
      snapshot = ?snapshotAt(repoRoot, record.hash, currentConfig, effects)
    if not snapshot.foreign:
      let change = ?snapshot.changeFor(record, effects)
      if change.isSome():
        newestFirst.add(change.get())
    snapshotHoldsFor = if snapshot.changesTheSetup(record): "" else: record.parentHash

  ok(
    PendingChanges(
      entries: newestFirst.reversed(), boundaryVersion: versionRange.boundaryVersion
    )
  )

proc nextIteration*(
    repoRoot: string, naming: ReleaseNaming, core: SemVer
): Result[int, string] =
  ## One past the highest iteration this package has already cut on this track
  ## at this core version.
  ##
  ## Every tag is scanned, not only those behind HEAD: a tag name is a
  ## repository-wide resource, and `git tag` refusing a name it already knows
  ## would fail after the release commit was made, leaving a moved manifest
  ## behind an untagged commit. Both prefixes count, so numbering stays
  ## continuous across a workspace shape change.
  var iteration = 1
  for _, tagNames in ?gitTagsByCommit(repoRoot):
    for tagName in tagNames:
      let version = naming.tagVersion(tagName)
      if version.isNone():
        continue
      if version.get.track == naming.track.name and version.get.core == core:
        iteration = max(iteration, version.get.iteration + 1)
  ok(iteration)
