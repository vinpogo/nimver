## End-to-end tests for release tracks, driving real repositories.
##
## Four rules decide every version a track produces, and each is easy to
## confuse with its neighbours, so each gets a test of its own before the long
## story that exercises them together.

import std/[os, strutils, unittest]
import ./support

suite "the rules a track's version follows":
  test "entering a track is not itself a bump":
    # The version is re-derived from the commits every time, so a lone `fix`
    # after a release is a patch, whatever track it goes out on.
    let dir = freshReleasedRepo("track-entering-is-no-bump")
    check setTrack(dir, "enter alpha").code == 0
    discard commitFile(dir, "a.txt", "hi", "fix: a")

    check run("nimver bump", dir).code == 0
    check "v0.2.1-alpha.1" in tags(dir)
    check manifestVersion(dir, "pkg.nimble") == "0.2.1-alpha.1"

  test "levels do not accumulate: a second feat moves the iteration, not the core":
    # The range since the last release is [feat, feat], whose highest level is
    # still minor. A core of 0.4.0 would mean levels adding up, which they do
    # not.
    let dir = freshReleasedRepo("track-levels-do-not-stack")
    check setTrack(dir, "enter alpha").code == 0
    discard commitFile(dir, "a.txt", "hi", "feat: a")
    check run("nimver bump", dir).code == 0
    check "v0.3.0-alpha.1" in tags(dir)

    discard commitFile(dir, "b.txt", "hi", "feat: b")
    check run("nimver bump", dir).code == 0
    check "v0.3.0-alpha.2" in tags(dir)
    check "v0.4.0-alpha.1" notin tags(dir)

  test "changing track keeps the core and restarts the iteration":
    let dir = freshReleasedRepo("track-change-restarts")
    check setTrack(dir, "enter alpha").code == 0
    discard commitFile(dir, "a.txt", "hi", "fix: a")
    check run("nimver bump", dir).code == 0
    discard commitFile(dir, "b.txt", "hi", "fix: b")
    check run("nimver bump", dir).code == 0
    check "v0.2.1-alpha.2" in tags(dir)

    check setTrack(dir, "enter beta").code == 0
    discard commitFile(dir, "c.txt", "hi", "fix: c")
    check run("nimver bump", dir).code == 0
    check "v0.2.1-beta.1" in tags(dir)

    # Only what came after the last prerelease, not the whole track.
    let changelog = readFile(dir / "CHANGELOG.md")
    let betaSection = changelog.split("## [0.2.1-beta.1]")[1].split("## [")[0]
    check "fix: c" in betaSection
    check "fix: a" notin betaSection

  test "the base is the last release, not the manifest":
    # At 0.2.1-alpha.1 the manifest's core is already the result of bumping
    # 0.2.0. Bumping it again would pay for the same patch twice.
    let dir = freshReleasedRepo("track-base-is-the-tag")
    check setTrack(dir, "enter alpha").code == 0
    discard commitFile(dir, "a.txt", "hi", "fix: a")
    check run("nimver bump", dir).code == 0
    discard commitFile(dir, "b.txt", "hi", "fix: b")
    check run("nimver bump", dir).code == 0

    check "v0.2.1-alpha.2" in tags(dir)
    check "v0.2.2-alpha.1" notin tags(dir)

suite "a track from end to end":
  test "alpha, then beta, then the release that covers the whole cycle":
    let dir = freshReleasedRepo("track-full-story")
    check setTrack(dir, "enter alpha").code == 0

    discard commitFile(dir, "a.txt", "hi", "feat: a")
    check run("nimver bump", dir).code == 0
    check "v0.3.0-alpha.1" in tags(dir)
    check "## [0.3.0-alpha.1]" in readFile(dir / "CHANGELOG.md")

    discard commitFile(dir, "b.txt", "hi", "fix: b")
    check run("nimver bump", dir).code == 0
    check "v0.3.0-alpha.2" in tags(dir)

    discard commitFile(dir, "c.txt", "hi", "feat!: c")
    check run("nimver bump", dir).code == 0
    check "v1.0.0-alpha.1" in tags(dir) # the core moved, so the iteration restarts

    check setTrack(dir, "enter beta").code == 0
    discard commitFile(dir, "d.txt", "hi", "fix: d")
    check run("nimver bump", dir).code == 0
    check "v1.0.0-beta.1" in tags(dir)

    check setTrack(dir, "exit").code == 0
    check run("nimver bump", dir).code == 0
    check "v1.0.0" in tags(dir)
    check manifestVersion(dir, "pkg.nimble") == "1.0.0"

    # The release covers the cycle, not just what came after the last beta.
    let changelog = readFile(dir / "CHANGELOG.md")
    let releaseSection = changelog.split("## [1.0.0]")[1].split("## [")[0]
    for subject in ["feat: a", "fix: b", "feat!: c", "fix: d"]:
      check subject in releaseSection

  test "nothing to bump when the only change on the track moves nothing":
    let dir = freshReleasedRepo("track-nothing-to-bump")
    check setTrack(dir, "enter alpha").code == 0
    discard commitFile(dir, "a.txt", "hi", "feat: a")
    check run("nimver bump", dir).code == 0

    discard commitFile(dir, "b.txt", "hi", "docs: b")
    let output = run("nimver bump", dir).output
    check "Nothing to bump" in output
    check tags(dir).len == 3

suite "a track needs a release to build on":
  test "a repository with no release tag is warned on entering, and refused on the bump":
    let dir = freshRepo("track-without-a-release")
    discard run("git tag -d v0.1.0", dir)
    let entered = setTrack(dir, "enter alpha")
    check entered.code == 0
    check "no release tag" in entered.output
    check "git tag v0.1.0" in entered.output

    discard commitFile(dir, "a.txt", "hi", "feat: a")
    let refused = run("nimver bump", dir)
    check refused.code != 0
    check "no release tag" in refused.output
    check "git tag v0.1.0" in refused.output
      # not `pkg-v0.1.0`, which is not this repo's shape

  test "a prerelease manifest leaves no version to advise tagging":
    # Once the first prerelease is written the manifest is no record of
    # anything that went out, so the advice has to fall back to a placeholder.
    let dir = freshRepo("track-prerelease-manifest-no-advice")
    discard run("git tag -d v0.1.0", dir)
    check setTrack(dir, "enter alpha").code == 0
    writeFile(dir / "pkg.nimble", "version = \"0.2.0-alpha.1\"\n")
    discard commitFile(dir, "a.txt", "hi", "fix: b")

    let refused = run("nimver bump", dir)
    check refused.code != 0
    check "track 'alpha'" in refused.output
    check "git tag v<version>" in refused.output

  test "tagging the version it is already on is what fixes it":
    let dir = freshRepo("track-tagging-fixes-it")
    discard run("git tag -d v0.1.0", dir)
    check setTrack(dir, "enter alpha").code == 0
    discard commitFile(dir, "a.txt", "hi", "fix: a")
    check run("nimver bump", dir).code != 0

    discard run("git tag v0.1.0 HEAD~1", dir)
    check run("nimver bump", dir).code == 0
    check "v0.1.1-alpha.1" in tags(dir)

suite "saying which track you are on":
  test "a fresh repository is on none":
    let dir = freshRepo("track-report-none")
    let output = setTrack(dir, "").output
    check "Not on a track" in output

  test "entering and leaving is visible, and leaves no file behind":
    let dir = freshRepo("track-report-roundtrip")
    check setTrack(dir, "enter alpha").code == 0
    check "On track 'alpha'" in setTrack(dir, "").output
    check fileExists(dir / ".nimver" / "track")

    check setTrack(dir, "exit").code == 0
    check "Not on a track" in setTrack(dir, "").output
    check not fileExists(dir / ".nimver" / "track")

  test "leaving twice is harmless":
    let dir = freshRepo("track-exit-twice")
    check setTrack(dir, "exit").code == 0
    check setTrack(dir, "exit").code == 0

  test "a name that could not be a tag is refused, and nothing is written":
    let dir = freshRepo("track-bad-name")
    for name in ["rc.2", "rc1", "2", "a-b"]:
      let refused = setTrack(dir, "enter " & name)
      check refused.code != 0
      check "may only contain letters" in refused.output
    check not fileExists(dir / ".nimver" / "track")

  test "enter needs a name, and an unknown subcommand is refused":
    let dir = freshRepo("track-usage")
    check setTrack(dir, "enter").code != 0
    check "Unknown track command" in setTrack(dir, "sideways").output

  test "entering a track does not by itself make anything releasable":
    # The track file is nimver's own bookkeeping. Counted as a change it would
    # land in every changelog under the default sharedChanges.
    let dir = freshReleasedRepo("track-file-is-not-a-change")
    check setTrack(dir, "enter alpha").code == 0
    discard run("git add -A", dir)
    discard run("git commit -q -m \"chore: enter the alpha track\"", dir)
    check "Nothing to bump" in run("nimver bump", dir).output

suite "a track warns while it is on":
  test "bump says so on stderr, dry run included, and stays quiet off the track":
    let dir = freshReleasedRepo("track-warns")
    discard commitFile(dir, "a.txt", "hi", "fix: a")
    check "releasing on track" notin pending(dir)

    check setTrack(dir, "enter alpha").code == 0
    let warned = pending(dir)
    check "releasing on track 'alpha'" in warned
    check "nimver track exit" in warned
    check "Would tag v0.2.1-alpha.1" in warned

suite "tracks in an independent workspace":
  test "one package can be on a track while its sibling releases plainly":
    let dir = freshWorkspaceRepo("track-workspace-one", strategy = "independent")
    discard commitFile(dir, "packages/web/a.txt", "hi", "feat: web")
    discard commitFile(dir, "packages/cli/a.txt", "hi", "feat: cli")
    check run("nimver bump", dir).code == 0

    check setTrack(dir, "enter alpha --package web").code == 0
    discard commitFile(dir, "packages/web/b.txt", "hi", "fix: web again")
    discard commitFile(dir, "packages/cli/b.txt", "hi", "fix: cli again")
    check run("nimver bump", dir).code == 0

    check "web-v0.2.1-alpha.1" in tags(dir)
    check "cli-v0.2.1" in tags(dir)

  test "a repo-wide track applies to whoever has no say of their own":
    let dir = freshWorkspaceRepo("track-workspace-default", strategy = "independent")
    discard commitFile(dir, "packages/web/a.txt", "hi", "feat: web")
    discard commitFile(dir, "packages/cli/a.txt", "hi", "feat: cli")
    check run("nimver bump", dir).code == 0

    check setTrack(dir, "enter alpha --package web").code == 0
    check setTrack(dir, "enter beta").code == 0
    discard commitFile(dir, "packages/web/b.txt", "hi", "fix: web again")
    discard commitFile(dir, "packages/cli/b.txt", "hi", "fix: cli again")
    check run("nimver bump", dir).code == 0

    check "web-v0.2.1-alpha.1" in tags(dir) # its own override stands
    check "cli-v0.2.1-beta.1" in tags(dir) # the default reaches the rest

  test "a package can come off the track while the rest stay on":
    let dir = freshWorkspaceRepo("track-workspace-exit-one", strategy = "independent")
    discard commitFile(dir, "packages/web/a.txt", "hi", "feat: web")
    discard commitFile(dir, "packages/cli/a.txt", "hi", "feat: cli")
    check run("nimver bump", dir).code == 0

    check setTrack(dir, "enter beta").code == 0
    check setTrack(dir, "exit --package web").code == 0
    discard commitFile(dir, "packages/web/b.txt", "hi", "fix: web again")
    discard commitFile(dir, "packages/cli/b.txt", "hi", "fix: cli again")
    check run("nimver bump", dir).code == 0

    check "web-v0.2.1" in tags(dir)
    check "cli-v0.2.1-beta.1" in tags(dir)

  test "a fixed workspace has one version, so it refuses a per-package track":
    let dir = freshWorkspaceRepo("track-workspace-fixed", strategy = "fixed")
    let refused = setTrack(dir, "enter alpha --package web")
    check refused.code != 0
    check "strategy is 'fixed'" in refused.output

  test "a package nobody declared is refused, with the ones that were":
    let dir = freshWorkspaceRepo("track-workspace-unknown", strategy = "independent")
    let refused = setTrack(dir, "enter alpha --package nope")
    check refused.code != 0
    check "Unknown package 'nope'" in refused.output

suite "tracks on parallel lines of development":
  test "a maintenance branch does not see the other line's tags":
    # Tags are read off HEAD's ancestry, so a 2.0.0 cut on another branch is
    # neither a boundary nor a base for the 1.x line.
    let dir = TestRepoRoot / "track-parallel-lines"
    removeDir(dir)
    createDir(dir)
    discard run("git init -q -b main .", dir)
    discard run("git config user.email test@example.com", dir)
    discard run("git config user.name Test", dir)
    writeFile(dir / "pkg.nimble", "version = \"1.1.0\"\n")
    discard run("git add -A", dir)
    discard run("git commit -q -m \"chore: init\"", dir)
    discard run("nimver init", dir)
    discard run("nimver install-hooks", dir)
    discard run("git add -A", dir)
    discard run("git commit -q --no-verify -m \"chore: adopt nimver\"", dir)
    discard run("git tag v1.1.0", dir)

    discard run("git checkout -q -b twox", dir)
    discard commitFile(dir, "big.txt", "hi", "feat!: the next major")
    check run("nimver bump", dir).code == 0
    check "v2.0.0" in tags(dir)

    discard run("git checkout -q main", dir)
    check setTrack(dir, "enter alpha").code == 0
    discard commitFile(dir, "f.txt", "hi", "fix: on the 1.x line")
    check run("nimver bump", dir).code == 0

    check "v1.1.1-alpha.1" in tags(dir)
