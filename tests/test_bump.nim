import std/[unittest, os, strutils]
import ./support

suite "bump":
  test "bump with no pending changes is a no-op":
    # Only `chore: init` behind it, which maps to `none`.
    let dir = freshRepo("bump-empty")
    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "Nothing to bump" in output
    check "1.0.0" in readFile(dir / "pkg.nimble")

  test "bump commits and tags the release by default":
    let dir = freshRepo("bump-defaults")
    discard commitFile(dir, "a.txt", "hi", "feat: add feature")
    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "1.0.0 -> 1.1.0" in output
    check "1.1.0" in readFile(dir / "pkg.nimble")
    check fileExists(dir / "CHANGELOG.md")

    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v1.1.0"
    let (tags, _) = run("git tag", dir)
    check "v1.1.0" in tags

  test "a detected single manifest keeps flat release naming by default":
    # No [workspace] section at all: the default strategy is independent, but a
    # lone detected package must still release exactly as it did before
    # workspaces existed - no package name required, no namespaced tag.
    let dir = freshRepo("default-single-package")
    discard commitFile(dir, "a.txt", "hi", "feat: add a")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "1.0.0 -> 1.1.0" in output
    check "1.1.0" in readFile(dir / "pkg.nimble")
    check fileExists(dir / "CHANGELOG.md")

    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v1.1.0"
    check tags(dir) == @["v1.0.0", "v1.1.0"]

  test "bump's release commit is not itself a pending change":
    let dir = freshRepo("bump-commit")
    discard commitFile(dir, "a.txt", "hi", "feat: add feature")
    let (_, code) = run("nimver bump", dir)
    check code == 0
    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v1.1.0"
    # The release commit is itself a `version:` commit, which is ignored - so
    # releasing twice in a row has nothing to release the second time.
    check "Nothing to bump" in run("nimver bump", dir).output

suite "a release says when it is a prerelease":
  test "off a track, nothing is said about one":
    let dir = freshReleasedRepo("bump-quiet-off-track")
    discard commitFile(dir, "a.txt", "hi", "fix: a")
    check "track" notin pending(dir)

  test "on a track, every run says so, dry run included":
    let dir = freshReleasedRepo("bump-warns-on-track")
    check run("nimver track enter rc", dir).code == 0
    discard commitFile(dir, "a.txt", "hi", "fix: a")

    for output in [pending(dir), run("nimver bump", dir).output]:
      check "releasing on track 'rc'" in output
      check "nimver track exit" in output

  test "it is said even when there is nothing to bump":
    let dir = freshReleasedRepo("bump-warns-with-nothing-to-do")
    check run("nimver track enter rc", dir).code == 0
    let output = run("nimver bump", dir).output
    check "releasing on track 'rc'" in output
    check "Nothing to bump" in output

suite "a tag that is already taken":
  test "the release is refused before anything is written":
    # `git tag` runs last, so a name it already knows would otherwise fail with
    # the manifest moved and the release commit made - the two left out of step.
    let dir = TestRepoRoot / "bump-tag-collision"
    removeDir(dir)
    createDir(dir)
    discard run("git init -q -b main .", dir)
    discard run("git config user.email test@example.com", dir)
    discard run("git config user.name Test", dir)
    writeFile(dir / "pkg.nimble", "version = \"1.0.0\"\n")
    discard run("git add -A", dir)
    discard run("git commit -q -m \"chore: init\"", dir)
    discard run("nimver init", dir)
    discard run("git add -A", dir)
    discard run("git commit -q --no-verify -m \"chore: adopt nimver\"", dir)
    discard run("git tag v1.0.0", dir)

    # The name taken on a branch this release knows nothing about.
    discard run("git checkout -q -b side", dir)
    discard commitFile(dir, "s.txt", "hi", "chore: elsewhere")
    discard run("git tag v1.1.0", dir)
    discard run("git checkout -q main", dir)
    discard commitFile(dir, "a.txt", "hi", "feat: a")

    let headBefore = run("git rev-parse HEAD", dir).output
    let refused = run("nimver bump", dir)
    check "already exists" in refused.output
    check readFile(dir / "pkg.nimble").contains("1.0.0")
    check run("git rev-parse HEAD", dir).output == headBefore

suite "a history no tag bounds":
  ## Walking to the root commit and bumping from the manifest counted changes
  ## the manifest version already accounted for, doubling the release. There is
  ## no safe guess to make instead, so `bump` says what to tag and stops.

  test "with nothing pending, it is still the repository that is refused":
    # Asked before releasability on purpose: having a release behind you is a
    # property of the repository. Answered the other way round, this would
    # report nothing to bump and then refuse the moment a `feat:` landed.
    let dir = freshRepo("no-tag-nothing-pending")
    discard run("git tag -d v1.0.0", dir)

    let refused = run("nimver bump", dir)
    check refused.code != 0
    check "count the same changes twice" in refused.output
    check "git tag v1.0.0" in refused.output
    check "Nothing to bump" notin refused.output

  test "a dry run is refused the same way":
    let dir = freshRepo("no-tag-dry-run")
    discard run("git tag -d v1.0.0", dir)
    discard commitFile(dir, "a.txt", "hi", "feat: a")

    let refused = run("nimver bump --dry-run", dir)
    check refused.code != 0
    check "no release tag" in refused.output
    check "Would tag" notin refused.output

  test "nothing is written, and the tagged sibling is not released either":
    # A bare bump plans every package, so one untagged package holds up the
    # release of its siblings - a one-time setup error, said once.
    let dir = freshWorkspaceRepo("no-tag-one-package", strategy = "independent")
    discard run("git tag -d v1.0.0", dir)
    discard run("git tag cli-v1.0.0", dir)
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    discard commitFile(dir, "packages/cli/src.nim", "discard\n", "feat: add cli")

    let headBefore = run("git rev-parse HEAD", dir).output
    let refused = run("nimver bump", dir)
    check refused.code != 0
    check "package 'web' has" in refused.output
    check "git tag web-v1.0.0" in refused.output
    check run("git rev-parse HEAD", dir).output == headBefore
    check tags(dir) == @["cli-v1.0.0"]

suite "below 1.0.0 a bump is held a notch down":
  ## What `^0.4.2` already means to npm and to cargo: the minor is the breaking
  ## axis down here and the major is not yet the project's to spend. Each
  ## fixture starts at 0.4.2 rather than the stable default.

  test "a breaking change takes the minor, not the major":
    let dir = freshRepo("premajor-breaking", version = "0.4.2")
    discard commitFile(dir, "a.txt", "hi", "feat!: drop the old API")

    check run("nimver bump", dir).code == 0
    check tags(dir) == @["v0.4.2", "v0.5.0"]
    check manifestVersion(dir, "pkg.nimble") == "0.5.0"

  test "a feature takes the patch":
    let dir = freshRepo("premajor-feature", version = "0.4.2")
    discard commitFile(dir, "a.txt", "hi", "feat: something new")

    check run("nimver bump", dir).code == 0
    check "v0.4.3" in tags(dir)

  test "a fix is still a patch, because there is no lower notch":
    let dir = freshRepo("premajor-fix", version = "0.4.2")
    discard commitFile(dir, "a.txt", "hi", "fix: something small")

    check run("nimver bump", dir).code == 0
    check "v0.4.3" in tags(dir)

  test "0.0.x is held the same way as any other 0.x":
    let dir = freshRepo("premajor-zero-zero", version = "0.0.3")
    discard commitFile(dir, "a.txt", "hi", "feat!: break it")

    check run("nimver bump", dir).code == 0
    check "v0.1.0" in tags(dir)

  test "the progress line names the level it cut and the one it held":
    # `0.4.2 -> 0.5.0 (major)` would describe a bump that did not happen.
    let dir = freshRepo("premajor-progress-line", version = "0.4.2")
    discard commitFile(dir, "a.txt", "hi", "feat!: drop the old API")

    let dryRun = pending(dir)
    check "Bumping version: 0.4.2 -> 0.5.0 (minor, major held below 1.0.0)" in dryRun

  test "at 1.0.0 and above the line reads as it always did":
    let dir = freshRepo("premajor-stable-line")
    discard commitFile(dir, "a.txt", "hi", "feat!: drop the old API")

    check "Bumping version: 1.0.0 -> 2.0.0 (major)" in pending(dir)

suite "promoting to the first stable release":
  test "--stable cuts exactly 1.0.0, whatever the changes add up to":
    # A lone `fix:` would be 0.4.3. Leaving 0.x is the user's call, not the
    # commits'.
    let dir = freshRepo("stable-one-shot", version = "0.4.2")
    discard commitFile(dir, "a.txt", "hi", "fix: something small")

    let (output, code) = run("nimver bump --stable", dir)
    check code == 0
    check "0.4.2 -> 1.0.0 (stable)" in output
    check "v1.0.0" in tags(dir)
    check manifestVersion(dir, "pkg.nimble") == "1.0.0"

  test "--stable with nothing pending still cuts 1.0.0":
    # The ceremonial release: the API is frozen, and the version is the whole
    # announcement. Its section is the heading and the date.
    let dir = freshRepo("stable-ceremonial", version = "0.4.2")

    let (output, code) = run("nimver bump --stable", dir)
    check code == 0
    check "0.4.2 -> 1.0.0 (stable)" in output
    check "v1.0.0" in tags(dir)

    let changelog = readFile(dir / "CHANGELOG.md")
    check "## [1.0.0]" in changelog
    check "### Commits" notin changelog

  test "--stable on a package already past 1.0.0 is refused, and nothing is written":
    let dir = freshRepo("stable-already")
    discard commitFile(dir, "a.txt", "hi", "feat: something new")

    let headBefore = run("git rev-parse HEAD", dir).output
    let refused = run("nimver bump --stable", dir)
    check refused.code != 0
    check "already at 1.0.0" in refused.output
    check "nothing for `--stable` to promote" in refused.output
    check run("git rev-parse HEAD", dir).output == headBefore
    check tags(dir) == @["v1.0.0"]
    check manifestVersion(dir, "pkg.nimble") == "1.0.0"

  test "after the promotion the commits decide the version again":
    let dir = freshRepo("stable-then-normal", version = "0.4.2")
    discard commitFile(dir, "a.txt", "hi", "fix: something small")
    check run("nimver bump --stable", dir).code == 0

    discard commitFile(dir, "b.txt", "hi", "feat: something new")
    check run("nimver bump", dir).code == 0
    # 1.1.0, not 1.0.1: nothing is held once the major is spent.
    check "v1.1.0" in tags(dir)

  test "a bare --stable promotes every package the run releases":
    let dir = freshWorkspaceRepo(
      "stable-workspace-all", strategy = "independent", version = "0.4.2"
    )
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    discard commitFile(dir, "packages/cli/main.nim", "echo 1\n", "fix: fix cli")

    check run("nimver bump --stable", dir).code == 0
    check "web-v1.0.0" in tags(dir)
    check "cli-v1.0.0" in tags(dir)

  test "one stable package holds up a bare --stable for its siblings":
    # A run is planned whole, so the sibling that got there first refuses it -
    # and naming the package is the way through.
    let dir = freshWorkspaceRepo(
      "stable-workspace-mixed", strategy = "independent", version = "0.4.2"
    )
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    check run("nimver bump web --stable", dir).code == 0

    discard commitFile(dir, "packages/cli/main.nim", "echo 1\n", "fix: fix cli")
    let refused = run("nimver bump --stable", dir)
    check refused.code != 0
    check "package 'web' is already at 1.0.0" in refused.output

    check run("nimver bump cli --stable", dir).code == 0
    check "cli-v1.0.0" in tags(dir)

  test "a fixed workspace moves every manifest to 1.0.0 at once":
    let dir = freshWorkspaceRepo("stable-workspace-fixed", version = "0.4.2")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")

    check run("nimver bump --stable", dir).code == 0
    check "v1.0.0" in tags(dir)
    check "\"version\": \"1.0.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check manifestVersion(dir, "packages/cli/cli.nimble") == "1.0.0"

  test "an unknown option is refused rather than ignored":
    # A silently dropped `--stabel` would tag 0.4.3 and say nothing about
    # having been misread.
    let dir = freshRepo("stable-typo", version = "0.4.2")
    discard commitFile(dir, "a.txt", "hi", "fix: something small")

    let refused = run("nimver bump --stabel", dir)
    check refused.code != 0
    check "unknown option '--stabel'" in refused.output
    check tags(dir) == @["v0.4.2"]
