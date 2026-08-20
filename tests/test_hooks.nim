## The Git hooks: `commit-msg` validation and the `post-commit` change-note
## recording, including how notes survive amends and rebases.

import std/[unittest, os, strutils, sequtils]
import ./support

suite "hooks":
  test "valid commit records a change note":
    let dir = freshRepo("valid-commit")
    let (output, code) = commitFile(dir, "a.txt", "hi", "feat: add a")
    check code == 0
    let notes = changeNotes(dir)
    check notes.len == 1
    let content = readFile(notes[0])
    check "type=feat" in content
    check "bump=minor" in content
    check "breaking=false" in content
    check "packages=root" in content
    check "feat: add a" in content
    discard output

  test "invalid commit type is rejected by the commit-msg hook":
    let dir = freshRepo("invalid-type")
    let (_, code) = commitFile(dir, "a.txt", "hi", "bogus: nope")
    check code != 0
    check changeNotes(dir).len == 0

  test "breaking change forces a major bump regardless of type mapping":
    let dir = freshRepo("breaking")
    let (_, code) = commitFile(dir, "a.txt", "hi", "fix!: breaking fix")
    check code == 0
    let notes = changeNotes(dir)
    check notes.len == 1
    check "breaking=true" in readFile(notes[0])
    let (out1, _) = run("nimver bump --dry-run", dir)
    check "-> 1.0.0 (major)" in out1

  test "change notes are created according to config.ini's bump mapping":
    let dir = freshRepo("config-driven")
    let cfgPath = dir / ".nimver" / "config.ini"
    writeFile(cfgPath, readFile(cfgPath).replace("fix = patch", "fix = major"))

    let (_, code) = commitFile(dir, "a.txt", "hi", "fix: b")
    check code == 0
    let notes = changeNotes(dir)
    check notes.len == 1
    check "bump=major" in readFile(notes[0])

    let (out1, _) = run("nimver bump --dry-run", dir)
    check "-> 1.0.0 (major)" in out1

  test "amending a commit replaces its note instead of duplicating":
    let dir = freshRepo("amend-dedupe")
    var r = commitFile(dir, "a.txt", "hi", "feat: first")
    check r.code == 0
    check changeNotes(dir).len == 1

    r = run("git commit --amend -q -m \"feat: second\"", dir)
    check r.code == 0
    var notes = changeNotes(dir)
    check notes.len == 1
    check "feat: second" in readFile(notes[0])

    r = run("git commit --amend -q -m \"version: v9.9.9\"", dir)
    check r.code == 0
    check changeNotes(dir).len == 0

    let status = run("git status --porcelain", dir)
    check status.output.strip().len == 0

  test "amend that changes commit type replaces the note with the correct one":
    let dir = freshRepo("amend-type-change")
    var r = commitFile(dir, "a.txt", "hi", "fix: a")
    check r.code == 0
    var notes = changeNotes(dir)
    check notes.len == 1
    check "type=fix" in readFile(notes[0])
    check "bump=patch" in readFile(notes[0])

    r = run("git commit --amend -q -m \"feat: a\"", dir)
    check r.code == 0
    notes = changeNotes(dir)
    check notes.len == 1
    let content = readFile(notes[0])
    check "type=feat" in content
    check "bump=minor" in content
    check "type=fix" notin content

  test "amend doesn't create a new change file across repeated amends":
    let dir = freshRepo("amend-no-new-file")
    var r = commitFile(dir, "a.txt", "hi", "fix: v1")
    check r.code == 0
    check changeNotes(dir).len == 1

    for msg in ["fix: v2", "fix: v3", "fix: v4"]:
      r = run("git commit --amend -q -m \"" & msg & "\"", dir)
      check r.code == 0
      let notes = changeNotes(dir)
      check notes.len == 1 # never grows past one note
      check msg in readFile(notes[0])

    check run("git status --porcelain", dir).output.strip().len == 0

  test "interactive rebase rewording an old commit doesn't corrupt state or duplicate notes":
    let dir = freshRepo("rebase-reword")
    discard commitFile(dir, "a.txt", "hi", "feat: a")
    discard commitFile(dir, "b.txt", "hi", "fix: b")
    discard commitFile(dir, "c.txt", "hi", "docs: c")
    check changeNotes(dir).len == 3

    # Script a non-interactive reword of the *middle* commit ("fix: b"),
    # which forces "docs: c" to be replayed on top of a new parent - a good
    # stress test for note dedup, and also a scenario that could confuse
    # the rebase sequencer if our post-commit hook tried to amend mid-rebase.
    # Kept outside the repo directory so these scripts don't show up as
    # untracked files in `git status` for the repo under test.
    let seqEditor = TestRepoRoot / "rebase-reword-seq-editor.sh"
    writeFile(
      seqEditor,
      "#!/bin/sh\nsed -i 's/^pick \\(\\S*\\) fix: b/reword \\1 fix: b/' \"$1\"\n",
    )
    setFilePermissions(seqEditor, {fpUserRead, fpUserWrite, fpUserExec})

    let msgEditor = TestRepoRoot / "rebase-reword-msg-editor.sh"
    writeFile(msgEditor, "#!/bin/sh\nsed -i 's/^fix: b$/fix: b (reworded)/' \"$1\"\n")
    setFilePermissions(msgEditor, {fpUserRead, fpUserWrite, fpUserExec})

    let base = run("git rev-parse HEAD~2", dir).output.strip()
    let (rebaseOut, rebaseCode) = run(
      "GIT_SEQUENCE_EDITOR=" & seqEditor & " GIT_EDITOR=" & msgEditor & " git rebase -i " &
        base,
      dir,
    )
    check rebaseCode == 0
    check "Successfully rebased" in rebaseOut

    # The rebase must finish cleanly: no leftover rebase state, no dirty tree.
    check not dirExists(dir / ".git" / "rebase-merge")
    check not dirExists(dir / ".git" / "rebase-apply")
    check run("git status --porcelain", dir).output.strip().len == 0

    # No duplicate (or missing) notes despite every commit after "feat: a"
    # being replayed with a new hash (and, for "docs: c", a new parent).
    check changeNotes(dir).len == 3

    let log = run("git log --oneline", dir).output
    check "fix: b (reworded)" in log

    # `post-commit` does nothing during the rebase, so `post-rewrite` catches
    # up once it finishes: the note follows the reworded message.
    check changeNotes(dir).anyIt("fix: b (reworded)" in readFile(it))
    check not changeNotes(dir).anyIt(
      "fix: b" in readFile(it) and "reworded" notin readFile(it)
    )

  test "a rebase that retypes a commit updates its bump level":
    # The dangerous case: the message says `feat` while the note still says
    # `fix`, which would silently under-bump the next release.
    let dir = freshRepo("rebase-retype")
    discard commitFile(dir, "a.txt", "hi", "fix: a change")
    var notes = changeNotes(dir)
    require notes.len == 1
    check "bump=patch" in readFile(notes[0])

    let seqEditor = TestRepoRoot / "rebase-retype-seq-editor.sh"
    writeFile(seqEditor, "#!/bin/sh\nsed -i 's/^pick/reword/' \"$1\"\n")
    setFilePermissions(seqEditor, {fpUserRead, fpUserWrite, fpUserExec})

    let msgEditor = TestRepoRoot / "rebase-retype-msg-editor.sh"
    writeFile(msgEditor, "#!/bin/sh\nsed -i '1s/.*/feat: a change/' \"$1\"\n")
    setFilePermissions(msgEditor, {fpUserRead, fpUserWrite, fpUserExec})

    let (_, rebaseCode) = run(
      "GIT_SEQUENCE_EDITOR=" & seqEditor & " GIT_EDITOR=" & msgEditor &
        " git rebase -i HEAD~1",
      dir,
    )
    check rebaseCode == 0
    check "feat: a change" in run("git log -1 --pretty=%s", dir).output

    notes = changeNotes(dir)
    require notes.len == 1
    let content = readFile(notes[0])
    check "type=feat" in content
    check "bump=minor" in content
    check "feat: a change" in content
    check run("git status --porcelain", dir).output.strip().len == 0

    # And the release that follows reflects the corrected level.
    check "0.1.0 -> 0.2.0 (minor)" in run("nimver bump --dry-run", dir).output

  test "hooks install into the shared hooks directory from a linked worktree":
    # A linked worktree's `.git` is a *file* pointing at
    # `<main>/.git/worktrees/<name>`, so `<root>/.git/hooks` does not exist
    # there. The same layout is used by submodules and by checkouts created
    # with `--separate-git-dir`.
    let dir = freshRepo("worktree-install")
    let linked = TestRepoRoot / "worktree-install-linked"
    removeDir(linked)
    var r = run("git worktree add -q " & linked & " -b feature", dir)
    check r.code == 0
    check fileExists(linked / ".git")
    check not dirExists(linked / ".git")

    # Wipe the hooks installed by `freshRepo` so the install below is the
    # only thing that could have put them back.
    for hookName in ["commit-msg", "post-commit", "post-rewrite"]:
      removeFile(dir / ".git" / "hooks" / hookName)

    r = run("nimver install-hooks", linked)
    check r.code == 0
    # Git shares one hooks directory across every worktree of a repository.
    for hookName in ["commit-msg", "post-commit", "post-rewrite"]:
      check fileExists(dir / ".git" / "hooks" / hookName)

    r = run("nimver init", linked)
    check r.code == 0
    check commitFile(linked, "a.txt", "hi", "feat: add a").code == 0
    let notes = changeNotes(linked)
    check notes.len == 1
    check "bump=minor" in readFile(notes[0])

    check commitFile(linked, "b.txt", "hi", "bogus: nope").code != 0

  test "rebase in a linked worktree is detected, leaving notes untouched":
    # Per-worktree state such as `rebase-merge` lives in the worktree's own
    # Git directory, not in `<main>/.git`. Failing to find it would let the
    # post-commit hook amend commits from under the rebase sequencer.
    let dir = freshRepo("worktree-rebase")
    let linked = TestRepoRoot / "worktree-rebase-linked"
    removeDir(linked)
    var r = run("git worktree add -q " & linked & " -b feature", dir)
    check r.code == 0
    check run("nimver init", linked).code == 0

    discard commitFile(linked, "a.txt", "hi", "feat: a")
    discard commitFile(linked, "b.txt", "hi", "fix: b")
    discard commitFile(linked, "c.txt", "hi", "docs: c")
    check changeNotes(linked).len == 3

    let seqEditor = TestRepoRoot / "worktree-rebase-seq-editor.sh"
    writeFile(
      seqEditor,
      "#!/bin/sh\nsed -i 's/^pick \\(\\S*\\) fix: b/reword \\1 fix: b/' \"$1\"\n",
    )
    setFilePermissions(seqEditor, {fpUserRead, fpUserWrite, fpUserExec})

    let msgEditor = TestRepoRoot / "worktree-rebase-msg-editor.sh"
    writeFile(msgEditor, "#!/bin/sh\nsed -i 's/^fix: b$/fix: b (reworded)/' \"$1\"\n")
    setFilePermissions(msgEditor, {fpUserRead, fpUserWrite, fpUserExec})

    let base = run("git rev-parse HEAD~2", linked).output.strip()
    let (rebaseOut, rebaseCode) = run(
      "GIT_SEQUENCE_EDITOR=" & seqEditor & " GIT_EDITOR=" & msgEditor & " git rebase -i " &
        base,
      linked,
    )
    check rebaseCode == 0
    check "Successfully rebased" in rebaseOut

    let rebaseState =
      run("git rev-parse --git-path rebase-merge", linked).output.strip()
    check not dirExists(rebaseState)
    check run("git status --porcelain", linked).output.strip().len == 0
    check changeNotes(linked).len == 3
    check "fix: b (reworded)" in run("git log --oneline", linked).output
