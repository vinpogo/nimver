## Unit tests for what a commit stands for: which commits count as a pending
## change, and what that change records. `test_history` asks the same of real
## repositories, where every case needs a commit to exist first.

import std/[unittest, options, strutils]
import history
import config
import semver
import gitutils
import ./builders

let typeConfig = parseConfig(
  """
[types]
feat = minor
fix = patch
chore = none
wip = ignore
""", "config.ini",
)

proc commit(message: string, changedPaths = @["src/main.nim"]): CommitRecord =
  CommitRecord(hash: "0123456789abcdef", message: message, changedPaths: changedPaths)

let lonePackage =
  newSnapshot(typeConfig, testWorkspace(@[testPackage("cli", "cli.nimble")]))

let nestedPackages = newSnapshot(
  typeConfig,
  testWorkspace(
    @[
      testPackage("web", "packages/web/package.json"),
      testPackage("cli", "packages/cli/cli.nimble"),
    ],
    sharedChanges = scNone,
  ),
)

suite "commits that stand for a change":
  test "the type decides the level":
    let change = lonePackage.changeFor(commit("feat: add a thing"))
    check change.isSome
    check change.get.commitType == "feat"
    check change.get.bumpLevel == blMinor
    check change.get.breaking == false

  test "the change records the package it affects":
    check lonePackage.changeFor(commit("fix: mend a thing")).get.affectedPackages ==
      @["cli"]

  test "a commit is recorded for every package it touches":
    let change = nestedPackages.changeFor(
      commit("fix: mend both", @["packages/web/index.js", "packages/cli/src/main.nim"])
    )
    check change.get.affectedPackages == @["web", "cli"]

  test "a none-level type is a pending change that moves nothing":
    let change = lonePackage.changeFor(commit("chore: tidy up"))
    check change.isSome
    check change.get.bumpLevel == blNone

  test "the body is kept, not just the header":
    let change =
      lonePackage.changeFor(commit("fix: mend a thing\n\nThe body explains why.\n"))
    check "fix: mend a thing" in change.get.message
    check "The body explains why." in change.get.message

  test "a breaking marker overrides the type's level":
    let change = lonePackage.changeFor(commit("chore!: rework a thing"))
    check change.get.bumpLevel == blMajor
    check change.get.breaking

  test "a breaking footer overrides the type's level":
    let change = lonePackage.changeFor(
      commit("chore: rework a thing\n\nBREAKING CHANGE: it moved")
    )
    check change.get.bumpLevel == blMajor
    check change.get.breaking

suite "commits that stand for nothing":
  test "a message that is not a Conventional Commit is skipped":
    check lonePackage.changeFor(commit("just fixing stuff")).isNone

  test "a type no configuration maps is skipped":
    check lonePackage.changeFor(commit("style: reindent")).isNone

  test "an ignored type is skipped":
    check lonePackage.changeFor(commit("wip: halfway there")).isNone

  test "a commit touching no package's files is skipped":
    check nestedPackages.changeFor(commit("fix: mend the readme", @["README.md"])).isNone

  test "a commit touching only the old bookkeeping directory is skipped":
    check lonePackage.changeFor(
      commit("feat: record a change", @[".nimver/changes/abc123.txt"])
    ).isNone
