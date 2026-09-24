import std/[algorithm, options, strutils, tables]
import ./changes
import ./commitparser
import ./config
import ./sysio
import ./gitutils
import ./adapters/manifest
import ./result
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

func tagVersion*(naming: ReleaseNaming, tagName: string): Option[SemVer] =
  ## The version a tag names, when it can be read at all. `v1.0`, `v2` and
  ## `v20240101` are version tags of this package that nobody can read a
  ## `major.minor.patch` out of - they still bound a range, they just cannot be
  ## a base.
  let written = naming.versionPart(tagName)
  if written.isNone():
    return none(SemVer)
  try:
    some(parseSemVer(written.get))
  except ValueError:
    none(SemVer)

func endsRange*(
    naming: ReleaseNaming, tagName: string, boundary: VersionBoundary
): bool =
  ## Bounding a range and reading a version are two questions. A tag whose
  ## version cannot be parsed still bounds one, exactly as it did before tracks
  ## existed - deciding otherwise would unbound such a repository and make its
  ## next release swallow the whole history.
  if naming.versionPart(tagName).isNone():
    return false
  case boundary
  of vbAnyVersion:
    true
  of vbRelease:
    let version = naming.tagVersion(tagName)
    version.isNone() or not version.get.isPrerelease()

type RangeEnd = tuple[ends: bool, version: Option[SemVer]]
  ## `ends` without a `version` is a tag that bounds the range but whose
  ## version nobody can read - the two questions are kept apart on purpose, so
  ## an unreadable boundary can never be mistaken for a base of 0.0.0.

func endsTheRange(
    naming: ReleaseNaming,
    record: CommitRecord,
    tagsByCommit: Table[string, seq[string]],
    boundary: VersionBoundary,
): RangeEnd =
  ## A commit may carry several tags; a readable one wins, so `v1.2.0` alongside
  ## an unparseable sibling still yields a base.
  result = (ends: false, version: none(SemVer))
  for tagName in tagsByCommit.getOrDefault(record.hash):
    if not naming.endsRange(tagName, boundary):
      continue
    result.ends = true
    let version = naming.tagVersion(tagName)
    if version.isSome():
      result.version = version
      return

proc snapshotAt(repoRoot, revision: string, currentConfig: NimverConfig): Snapshot =
  ## How the repository stood at a commit, read from that commit's own tree.
  ##
  ## Commits made before nimver was set up - or carrying a config that no
  ## longer parses, which a release is not the place to give up over - are read
  ## under the configuration as it is now.
  result.config = currentConfig
  let contents = gitFileAtRevision(repoRoot, revision, ConfigRelPath)
  if contents.isSome():
    try:
      result.config = parseConfig(contents.get, revision & ":" & ConfigRelPath)
    except IOError, ValueError:
      writeError(
        "nimver: keeping the current configuration for " & revision[0 ..< 8] & ": " &
          getCurrentExceptionMsg()
      )

  var detectedManifestNames: seq[string] = @[]
  if result.config.packages.len == 0:
    detectedManifestNames = rootManifestNames(gitRootEntryNames(repoRoot, revision))
  result.workspace =
    workspaceLayout(repoRoot, result.config, detectedManifestNames, quiet = true)

proc changesTheSetup(snapshot: Snapshot, record: CommitRecord): bool =
  ## Whether a commit is one the snapshot has to be re-read after. Reading it
  ## per commit would mean a couple of `git` calls each, which is most of the
  ## time a release spends; both of these change rarely, and a commit that
  ## changes neither cannot have changed how the one before it is read.
  for path in record.changedPaths:
    if path == ConfigRelPath:
      return true
    # Only when nothing is configured does the root listing decide anything,
    # and only a root entry can be part of it.
    if snapshot.config.packages.len == 0 and '/' notin path and
        rootManifestNames(@[path]).len > 0:
      return true
  false

proc changeFor*(snapshot: Snapshot, record: CommitRecord): Option[ChangeEntry] =
  ## The change a commit stands for, or nothing when it is not one: an
  ## `ignore`d type, a message that is not a Conventional Commit, or a commit
  ## touching no package's files.
  let parsed = parseCommitMessage(record.message)
  if isFailure(parsed):
    # Silent on purpose. Merges are already left out, and what is left is
    # history from before the hook was installed or from around it - not
    # something a release can do anything about.
    return none(ChangeEntry)

  let maybeLevel = validateAndLookup(snapshot.config, parsed.value)
  if isNone(maybeLevel):
    writeError(
      "nimver: skipping " & record.hash[0 ..< 8] & ": unknown commit type '" &
        parsed.value.commitType & "'"
    )
    return none(ChangeEntry)
  if maybeLevel.get == blIgnore:
    return none(ChangeEntry)

  let affected = affectedPackageNames(snapshot.workspace, record.changedPaths)
  if affected.len == 0:
    return none(ChangeEntry)

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

type VersionRange = object
  records: seq[CommitRecord] ## Newest first.
  boundaryVersion: Option[SemVer]

proc commitsSinceLastVersion(
    repoRoot: string, naming: ReleaseNaming, boundary: VersionBoundary
): VersionRange =
  ## Newest first, stopping before the commit a version of this package went
  ## out with - which version counts as one is `boundary`'s question, and it is
  ## settled before the walk begins.
  let tagsByCommit = gitTagsByCommit(repoRoot)
  for record in gitCommitsIn(repoRoot, "HEAD"):
    let rangeEnd = naming.endsTheRange(record, tagsByCommit, boundary)
    if rangeEnd.ends:
      result.boundaryVersion = rangeEnd.version
      return
    result.records.add(record)

type PendingChanges* = object
  entries*: seq[ChangeEntry] ## Oldest first - the order a changelog reads in.
  boundaryVersion*: Option[SemVer]
    ## The version of the tag the walk stopped at, and the only thing a base may
    ## be taken from. None for two different reasons: the walk ran out of
    ## history without meeting a tag, or it stopped at one whose version cannot
    ## be read. Neither can serve as a base.

proc pendingChanges*(
    repoRoot: string,
    currentConfig: NimverConfig,
    naming: ReleaseNaming,
    boundary = vbRelease,
): PendingChanges =
  ## Every change since the last version of the package `naming` describes,
  ## oldest first - the order a changelog section reads in.
  ##
  ## The range ends at the first commit going back that such a version went out
  ## with, whether that shows as a tag or as the release commit itself. With
  ## neither to be found the whole history counts, which is what a first release
  ## wants - and what a repository adopting nimver later bounds by tagging the
  ## version it is already on.
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
  let versionRange = commitsSinceLastVersion(repoRoot, naming, boundary)
  result.boundaryVersion = versionRange.boundaryVersion

  var newestFirst: seq[ChangeEntry] = @[]
  var snapshot: Snapshot
  # Walking backwards, the setup only needs re-reading once a commit that
  # changed it has been passed.
  var snapshotIsStale = true
  for record in versionRange.records:
    if snapshotIsStale:
      snapshot = snapshotAt(repoRoot, record.hash, currentConfig)
    let change = snapshot.changeFor(record)
    if change.isSome():
      newestFirst.add(change.get())
    snapshotIsStale = snapshot.changesTheSetup(record)

  result.entries = newestFirst.reversed()

proc nextIteration*(repoRoot: string, naming: ReleaseNaming, core: SemVer): int =
  ## One past the highest iteration this package has already cut on this track
  ## at this core version.
  ##
  ## Every tag is scanned, not only those behind HEAD: a tag name is a
  ## repository-wide resource, and `git tag` refusing a name it already knows
  ## would fail after the release commit was made, leaving a moved manifest
  ## behind an untagged commit. Both prefixes count, so numbering stays
  ## continuous across a workspace shape change.
  result = 1
  for _, tagNames in gitTagsByCommit(repoRoot):
    for tagName in tagNames:
      let version = naming.tagVersion(tagName)
      if version.isNone():
        continue
      if version.get.track == naming.track.name and version.get.core == core:
        result = max(result, version.get.iteration + 1)
