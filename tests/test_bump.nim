import std/[unittest, os, strutils]
import ./support

suite "bump":
  test "bump with no pending changes is a no-op":
    # Only `chore: init` behind it, which maps to `none`.
    let dir = freshRepo("bump-empty")
    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "Nothing to bump" in output
    check "0.1.0" in readFile(dir / "pkg.nimble")

  test "bump commits and tags the release by default":
    let dir = freshRepo("bump-defaults")
    discard commitFile(dir, "a.txt", "hi", "feat: add feature")
    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "0.1.0 -> 0.2.0" in output
    check "0.2.0" in readFile(dir / "pkg.nimble")
    check fileExists(dir / "CHANGELOG.md")

    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v0.2.0"
    let (tags, _) = run("git tag", dir)
    check "v0.2.0" in tags

  test "a detected single manifest keeps flat release naming by default":
    # No [workspace] section at all: the default strategy is independent, but a
    # lone detected package must still release exactly as it did before
    # workspaces existed - no package name required, no namespaced tag.
    let dir = freshRepo("default-single-package")
    discard commitFile(dir, "a.txt", "hi", "feat: add a")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "0.1.0 -> 0.2.0" in output
    check "0.2.0" in readFile(dir / "pkg.nimble")
    check fileExists(dir / "CHANGELOG.md")

    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v0.2.0"
    let (tags, _) = run("git tag", dir)
    check tags.strip() == "v0.2.0"

  test "bump's release commit is not itself a pending change":
    let dir = freshRepo("bump-commit")
    discard commitFile(dir, "a.txt", "hi", "feat: add feature")
    let (_, code) = run("nimver bump", dir)
    check code == 0
    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v0.2.0"
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
    writeFile(dir / "pkg.nimble", "version = \"0.1.0\"\n")
    discard run("git add -A", dir)
    discard run("git commit -q -m \"chore: init\"", dir)
    discard run("nimver init", dir)
    discard run("git add -A", dir)
    discard run("git commit -q --no-verify -m \"chore: adopt nimver\"", dir)

    # The name taken on a branch this release knows nothing about.
    discard run("git checkout -q -b side", dir)
    discard commitFile(dir, "s.txt", "hi", "chore: elsewhere")
    discard run("git tag v0.2.0", dir)
    discard run("git checkout -q main", dir)
    discard commitFile(dir, "a.txt", "hi", "feat: a")

    let headBefore = run("git rev-parse HEAD", dir).output
    let refused = run("nimver bump", dir)
    check "already exists" in refused.output
    check readFile(dir / "pkg.nimble").contains("0.1.0")
    check run("git rev-parse HEAD", dir).output == headBefore
