## Unit tests for the decisions a release plan makes without touching a
## repository: which level a set of changes adds up to, whether there is
## anything to release, how changelog writes are folded together, and what the
## release commit is called.

import std/[unittest, strutils]
import release
import workspace
import config
import changes
import semver
import adapters/manifest

proc package(name, manifestRelativePath: string): WorkspacePackage =
  WorkspacePackage(
    name: name,
    manifest: manifestAt(manifestRelativePath),
    manifestRelativePath: manifestRelativePath,
    rootDirectory: "",
  )

proc workspaceOf(packages: seq[WorkspacePackage]): Workspace =
  Workspace(strategy: wsIndependent, sharedChanges: scAll, packages: packages)

proc entry(level: BumpLevel, breaking = false): ChangeEntry =
  ChangeEntry(
    commitType: "feat", bumpLevel: level, breaking: breaking, message: "feat: a change"
  )

proc release(
    name: string,
    next: string,
    level: BumpLevel,
    changelogPath = "CHANGELOG.md",
    entries = @[entry(blMinor)],
): PackageRelease =
  PackageRelease(
    package: package(name, name & ".nimble"),
    entries: entries,
    current: parseSemVer("0.1.0"),
    next: parseSemVer(next),
    level: level,
    section: "## [" & next & "]\n",
    changelogPath: changelogPath,
    tag: name & "-v" & next,
  )

suite "the level a release takes":
  test "no changes mean no bump":
    check highestBumpLevel(@[]) == blNone

  test "one change decides on its own":
    check highestBumpLevel(@[entry(blPatch)]) == blPatch

  test "the highest level among the changes wins":
    check highestBumpLevel(@[entry(blPatch), entry(blMinor), entry(blPatch)]) == blMinor

  test "levels do not stack: three patches are still a patch":
    check highestBumpLevel(@[entry(blPatch), entry(blPatch), entry(blPatch)]) == blPatch

  test "one breaking change turns the whole release major":
    check highestBumpLevel(@[entry(blPatch), entry(blMajor, breaking = true)]) == blMajor

  test "ignored changes count for nothing":
    check highestBumpLevel(@[entry(blIgnore), entry(blIgnore)]) == blNone

  test "an ignored change does not hold back the others":
    check highestBumpLevel(@[entry(blIgnore), entry(blMinor)]) == blMinor

suite "whether there is anything to release":
  test "changes that move the version are releasable":
    let planned = release("cli", "0.2.0", blMinor)
    check planned.hasPendingChanges()
    check planned.isReleasable()

  test "no changes at all are not releasable":
    let planned = release("cli", "0.1.0", blNone, entries = @[])
    check not planned.hasPendingChanges()
    check not planned.isReleasable()

  test "changes that move nothing are reported but not releasable":
    let planned = release("cli", "0.1.0", blNone, entries = @[entry(blNone)])
    check planned.hasPendingChanges()
    check not planned.isReleasable()

suite "folding changelog writes":
  test "one release writes its section":
    let writes = changelogWrites(@[release("cli", "0.2.0", blMinor)])
    check writes.len == 1
    check writes[0].path == "CHANGELOG.md"
    check writes[0].text == "## [0.2.0]\n"

  test "separate changelogs are written separately":
    let writes = changelogWrites(
      @[
        release("web", "0.2.0", blMinor, changelogPath = "packages/web/CHANGELOG.md"),
        release("cli", "0.1.1", blPatch, changelogPath = "packages/cli/CHANGELOG.md"),
      ]
    )
    check writes.len == 2
    check writes[0].path == "packages/web/CHANGELOG.md"
    check writes[1].path == "packages/cli/CHANGELOG.md"

  test "packages sharing a changelog are folded into one write":
    let writes = changelogWrites(
      @[release("web", "0.2.0", blMinor), release("cli", "0.1.1", blPatch)]
    )
    check writes.len == 1
    check writes[0].text == "## [0.2.0]\n\n## [0.1.1]\n"

  test "a folded write keeps the order the releases were planned in":
    let writes = changelogWrites(
      @[release("cli", "0.1.1", blPatch), release("web", "0.2.0", blMinor)]
    )
    check writes[0].text.find("[0.1.1]") < writes[0].text.find("[0.2.0]")

  test "nothing to release writes nothing":
    check changelogWrites(@[]).len == 0

suite "naming the release":
  let single = workspaceOf(@[package("cli", "cli.nimble")])
  let several =
    workspaceOf(@[package("web", "package.json"), package("cli", "cli.nimble")])

  test "a lone package is just the version":
    check single.releaseCommitSubject(@[release("cli", "1.0.0", blMajor)]) ==
      "version: v1.0.0"

  test "one package out of several names itself":
    check several.releaseCommitSubject(@[release("web", "0.2.0", blMinor)]) ==
      "version(web): v0.2.0"

  test "several packages at once list their tags instead of a single version":
    check several.releaseCommitSubject(
      @[release("web", "0.2.0", blMinor), release("cli", "0.1.1", blPatch)]
    ) == "version: web-v0.2.0, cli-v0.1.1"

  test "progress output names the package only when there are several":
    check single.releaseLabelFor(package("cli", "cli.nimble")) == "version"
    check several.releaseLabelFor(package("web", "package.json")) == "web"
