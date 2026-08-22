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
