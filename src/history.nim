import std/[options, strutils, tables, options]
import ./changes
import ./commitparser
import ./config
import ./gitutils
import ./adapters/manifest
import ./result
import ./semver
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

  Snapshot = object
    ## How the repository was set up at some commit: what the types map to, and
    ## which packages a changed file can belong to.
    config: Config
    workspace: Workspace

proc newReleaseNaming*(packageName: string, namespaced: bool): ReleaseNaming =
  if namespaced:
    ReleaseNaming(
      tagPrefix: packageName & "-v", packageName: packageName, legacyPrefix: "v"
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
    )

proc isReleaseTag(naming: ReleaseNaming, tagName: string): bool =
  ## `v1.2.0` and `web-v1.2.0` are releases; `verify-fix` and `webhooks` are
  ## not, hence the digit.
  proc matchesPrefix(tag, prefix: string): bool =
    tag.len > prefix.len and tag.startsWith(prefix) and tag[prefix.len].isDigit()

  tagName.matchesPrefix(naming.tagPrefix) or
    (naming.legacyPrefix.len > 0 and tagName.matchesPrefix(naming.legacyPrefix))

proc endsTheRange(
    naming: ReleaseNaming,
    record: CommitRecord,
    tagsByCommit: Table[string, seq[string]],
): bool =
  for tagName in tagsByCommit.getOrDefault(record.hash):
    if naming.isReleaseTag(tagName):
      return true

proc snapshotAt(repoRoot, revision: string, currentConfig: Config): Snapshot =
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
      stderr.writeLine(
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

proc changeFor(snapshot: Snapshot, record: CommitRecord): Option[ChangeEntry] =
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
    stderr.writeLine(
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
      bumpLevel: maybeLevel.get,
      breaking: parsed.value.breaking,
      affectedPackages: affected,
      message: parsed.value.rawMessage,
    )
  )

proc pendingChanges*(
    repoRoot: string, currentConfig: Config, naming: ReleaseNaming
): seq[ChangeEntry] =
  ## Every change since the last release of the package `naming` describes,
  ## oldest first - the order a changelog section reads in.
  ##
  ## The range ends at the first commit going back that a release of this
  ## package went out with, whether that shows as a tag or as the release
  ## commit itself. With neither to be found the whole history counts, which is
  ## what a first release wants - and what a repository adopting nimver later
  ## bounds by tagging the version it is already on.
  ##
  ## Nothing subtler than that on purpose. Cutting the range at, say, the
  ## commit that introduced `.nimver/config.ini` reads well until a rebase
  ## reorders that commit past its neighbours, at which point the changes
  ## behind it disappear from the release without a word.
  let tagsByCommit = gitTagsByCommit(repoRoot)

  var changes: seq[ChangeEntry] = @[]
  var snapshot: Snapshot
  # Walking backwards, the setup only needs re-reading once a commit that
  # changed it has been passed.
  var snapshotIsStale = true
  for record in gitCommitsIn(repoRoot, "HEAD"):
    if naming.endsTheRange(record, tagsByCommit):
      break
    if snapshotIsStale:
      snapshot = snapshotAt(repoRoot, record.hash, currentConfig)
      snapshotIsStale = false

    let change = snapshot.changeFor(record)
    if change.isSome():
      changes.add(change.get())
    snapshotIsStale = snapshot.changesTheSetup(record)

  # Read newest first, released oldest first.
  for index in countdown(changes.high, 0):
    result.add(changes[index])
