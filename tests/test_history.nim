## Reading pending changes back out of the history: which commits a release
## counts, what their messages are taken to mean, and where the range ends.

import std/[unittest, os, strutils, sequtils]
import ./support

suite "history":
  test "a change follows its commit message, however the commit is rewritten":
    # The property the whole design rests on: nothing is recorded while
    # committing, so there is nothing that can fall out of step with a message.
    let dir = freshRepo("history-follows-message")
    check commitFile(dir, "a.txt", "hi", "fix: a").code == 0
    check "0.1.0 -> 0.1.1 (patch)" in pending(dir)

    check run("git commit --amend -q -m \"feat: a\"", dir).code == 0
    check "0.1.0 -> 0.2.0 (minor)" in pending(dir)

    check run("git commit --amend -q -m \"feat!: a\"", dir).code == 0
    check "0.1.0 -> 1.0.0 (major)" in pending(dir)

    # Amending the *content* leaves the message, and so the change, alone.
    writeFile(dir / "a.txt", "more")
    discard run("git add -A", dir)
    check run("git commit --amend -q --no-edit", dir).code == 0
    check "0.1.0 -> 1.0.0 (major)" in pending(dir)

  test "rewording during a rebase is picked up without touching the rebase":
    let dir = freshRepo("history-reword")
    discard commitFile(dir, "a.txt", "hi", "fix: a")
    discard commitFile(dir, "b.txt", "hi", "fix: b")
    discard commitFile(dir, "c.txt", "hi", "fix: c")
    check "0.1.0 -> 0.1.1 (patch)" in pending(dir)

    let (rebaseOutput, rebaseCode) = rebaseInteractive(
      dir,
      run("git rev-parse HEAD~3", dir).output.strip(),
      "s/^pick \\(\\S*\\) fix: b/reword \\1 fix: b/",
      "s/^fix: b$/feat: b is bigger than thought/",
    )
    check rebaseCode == 0
    check "Successfully rebased" in rebaseOutput
    # Every commit still replayed, and nothing was left behind in the tree.
    check run("git rev-list --count HEAD", dir).output.strip() == "4"
    check run("git status --porcelain", dir).output.strip().len == 0

    let dryRun = pending(dir)
    check "0.1.0 -> 0.2.0 (minor)" in dryRun
    check "- b is bigger than thought" in dryRun
    check "- a" in dryRun

  test "reordering commits changes nothing about the release":
    let dir = freshRepo("history-reorder")
    discard commitFile(dir, "a.txt", "hi", "feat: a")
    discard commitFile(dir, "b.txt", "hi", "fix: b")

    let (_, rebaseCode) = rebaseInteractive(
      dir, run("git rev-parse HEAD~2", dir).output.strip(), "1{h;d};2{G}"
    )
    check rebaseCode == 0
    check "fix: b" in run("git log --oneline -2", dir).output.splitLines()[1]

    # Same changes, so the same release - only the order the changelog lists
    # them in follows the history.
    let dryRun = pending(dir)
    check "0.1.0 -> 0.2.0 (minor)" in dryRun
    check "- a" in dryRun
    check "- b" in dryRun

  test "squashed commits count once, under the message they end up with":
    let dir = freshRepo("history-squash")
    discard commitFile(dir, "a.txt", "hi", "fix: a")
    discard commitFile(dir, "b.txt", "hi", "fix: b")

    let (_, rebaseCode) = rebaseInteractive(
      dir,
      run("git rev-parse HEAD~2", dir).output.strip(),
      "s/^pick \\(\\S*\\) fix: b/squash \\1 fix: b/",
      "1s/.*/feat: a and b together/",
    )
    check rebaseCode == 0

    let dryRun = pending(dir)
    check "0.1.0 -> 0.2.0 (minor)" in dryRun
    check "- a and b together" in dryRun
    # The two commits it was made of are gone, so neither is listed on its own.
    check "\n- a\n" notin dryRun
    check "\n- b\n" notin dryRun

  test "ignored types contribute nothing":
    let dir = freshRepo("history-ignored")
    check commitFile(dir, "a.txt", "hi", "wip: not done").code == 0
    check "Nothing to bump" in pending(dir)

    check commitFile(dir, "b.txt", "hi", "fix: real").code == 0
    let dryRun = pending(dir)
    check "0.1.0 -> 0.1.1 (patch)" in dryRun
    check "not done" notin dryRun

  test "a released commit is not counted again":
    let dir = freshRepo("history-boundary-tag")
    discard commitFile(dir, "a.txt", "hi", "feat: a")
    check run("nimver bump", dir).code == 0
    check "v0.2.0" in run("git tag", dir).output
    check "Nothing to bump" in pending(dir)

    discard commitFile(dir, "b.txt", "hi", "fix: b")
    let dryRun = pending(dir)
    check "0.2.0 -> 0.2.1 (patch)" in dryRun
    check "- a" notin dryRun # already released

  test "the release commit ends the range when there is no tag":
    # `bump --no-tag` is a normal way to release, so the range cannot depend on
    # tags alone.
    let dir = freshRepo("history-boundary-commit")
    discard commitFile(dir, "a.txt", "hi", "feat: a")
    check run("nimver bump --no-tag", dir).code == 0
    check run("git tag", dir).output.strip().len == 0
    check "Nothing to bump" in pending(dir)

    discard commitFile(dir, "b.txt", "hi", "fix: b")
    check "0.2.0 -> 0.2.1 (patch)" in pending(dir)

  test "a tag bounds the history a repository adopting nimver brings with it":
    # Without a release to stop at, a first release counts everything - so a
    # repository with a past says where that past ends by tagging the version
    # it is already on. Deliberately the only such marker: anything cleverer
    # can be reordered out from under itself.
    let dir = TestRepoRoot / "history-pre-nimver"
    removeDir(dir)
    createDir(dir)
    discard run("git init -q", dir)
    discard run("git config user.email test@example.com", dir)
    discard run("git config user.name Test", dir)
    writeFile(dir / "pkg.nimble", "version = \"0.1.0\"\n")
    discard run("git add -A", dir)
    discard run("git commit -q -m \"feat: from another life\"", dir)

    check run("nimver init", dir).code == 0
    check run("nimver install-hooks", dir).code == 0
    check "- from another life" in pending(dir) # counted, for now

    discard run("git tag v0.1.0 HEAD", dir)
    check commitFile(dir, "a.txt", "hi", "fix: the first with nimver").code == 0

    let dryRun = pending(dir)
    check "0.1.0 -> 0.1.1 (patch)" in dryRun
    check "- the first with nimver" in dryRun
    check "another life" notin dryRun

  test "a commit is read under the configuration it was made with":
    # The snapshot a change note used to freeze, derived instead: retyping the
    # mapping today must not rewrite what last week's commits meant.
    let dir = freshRepo("history-config-snapshot")
    check commitFile(dir, "a.txt", "hi", "fix: a").code == 0
    check "0.1.0 -> 0.1.1 (patch)" in pending(dir)

    let configFile = dir / ".nimver" / "config.ini"
    writeFile(configFile, readFile(configFile).replace("fix = patch", "fix = major"))
    discard run("git add -A", dir)
    discard run("git commit -q -m \"chore: fixes are major from now on\"", dir)

    # The earlier commit keeps the meaning it was made with...
    check "0.1.0 -> 0.1.1 (patch)" in pending(dir)
    # ...while a new one takes the mapping as it now stands.
    check commitFile(dir, "b.txt", "hi", "fix: b").code == 0
    check "0.1.0 -> 1.0.0 (major)" in pending(dir)

  test "a package added mid-cycle does not claim changes made before it":
    # The layout is read from each commit's own tree, so `cli` cannot pick up a
    # change committed when only `web` was configured.
    let dir = freshWorkspaceRepo(
      "history-package-added", sharedChanges = "none", strategy = "independent"
    )
    createDir(dir / "packages" / "extra")
    writeFile(dir / "packages" / "extra" / "extra.nimble", "version = \"0.1.0\"\n")
    check commitFile(
      dir, "packages/web/index.js", "export {}\n", "feat: web only, for now"
    ).code == 0

    let configFile = dir / ".nimver" / "config.ini"
    writeFile(
      configFile,
      readFile(configFile) &
        "\n[package.extra]\nmanifest = packages/extra/extra.nimble\n",
    )
    discard run("git add -A", dir)
    discard run("git commit -q --no-verify -m \"chore: declare extra\"", dir)

    let dryRun = pending(dir)
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in dryRun
    check "extra" notin dryRun
