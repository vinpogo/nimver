## End-to-end tests. Each test spins up a throwaway Git repo under
## `testRepo/` (gitignored, safe to blow away) and drives it through real
## `git` + `nimver` invocations, exactly as a user would.
##
## Run via `nimble test` (builds the binary first, then runs this file).

import std/[unittest, os, osproc, strutils, strtabs, sequtils]

const ProjectRoot = currentSourcePath().parentDir().parentDir()
const TestRepoRoot = ProjectRoot / "testRepo"

proc testEnv(): StringTableRef =
  ## The freshly built binary lives at the project root; prepend it to PATH
  ## so the installed Git hooks (`exec nimver ...`) resolve to
  ## it instead of whatever else might be installed on the system.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result["PATH"] = ProjectRoot & ":" & result.getOrDefault("PATH", "")

proc run(cmd: string, dir: string): tuple[output: string, code: int] =
  let r = execCmdEx(cmd, workingDir = dir, env = testEnv())
  (r.output, r.exitCode)

proc changeNotes(dir: string): seq[string] =
  toSeq(walkFiles(dir / ".nimver" / "changes" / "*.txt"))

proc freshRepo(name: string): string =
  ## A repo with one commit and an initial `pkg.nimble` at 0.1.0, with
  ## nimver initialized and its hooks installed.
  result = TestRepoRoot / name
  removeDir(result)
  createDir(result)

  var r = run("git init -q", result)
  doAssert r.code == 0, "git init failed: " & r.output
  discard run("git config user.email test@example.com", result)
  discard run("git config user.name Test", result)

  writeFile(result / "pkg.nimble", "version = \"0.1.0\"\n")
  discard run("git add -A", result)
  r = run("git commit -q -m \"chore: init\"", result)
  doAssert r.code == 0, "initial commit failed: " & r.output

  r = run("nimver init", result)
  doAssert r.code == 0, "init failed: " & r.output
  r = run("nimver install-hooks", result)
  doAssert r.code == 0, "install-hooks failed: " & r.output

proc commitFile(
    dir, fileName, contents, message: string
): tuple[output: string, code: int] =
  writeFile(dir / fileName, contents)
  discard run("git add -A", dir)
  run("git commit -q -m \"" & message & "\"", dir)

removeDir(TestRepoRoot)
createDir(TestRepoRoot)

suite "end-to-end":
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

    # Known, safe limitation: note recording is skipped entirely while a
    # rebase is in progress (to avoid fighting the sequencer's own amend of
    # the reworded commit - see `isRebaseInProgress`), so the pre-existing
    # note for "fix: b" survives with its original text instead of being
    # updated or duplicated.
    check changeNotes(dir).anyIt(
      "fix: b" in readFile(it) and "reworded" notin readFile(it)
    )

  test "bump with no pending changes is a no-op":
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
    check changeNotes(dir).len == 0

    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v0.2.0"
    let (tags, _) = run("git tag", dir)
    check "v0.2.0" in tags

  test "bump --commit's release commit is not recorded as a pending change":
    let dir = freshRepo("bump-commit")
    discard commitFile(dir, "a.txt", "hi", "feat: add feature")
    let (_, code) = run("nimver bump", dir)
    check code == 0
    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v0.2.0"
    check changeNotes(dir).len == 0

  test "bump --no-commit --no-tag only touches files, leaving history untouched":
    let dir = freshRepo("bump-no-commit-no-tag")
    discard commitFile(dir, "a.txt", "hi", "feat: add feature")
    let (headBefore, _) = run("git rev-parse HEAD", dir)

    let (output, code) = run("nimver bump --no-commit --no-tag", dir)
    check code == 0
    check "0.1.0 -> 0.2.0" in output
    check "0.2.0" in readFile(dir / "pkg.nimble")
    check fileExists(dir / "CHANGELOG.md")
    check changeNotes(dir).len == 0

    let (headAfter, _) = run("git rev-parse HEAD", dir)
    check headBefore.strip() == headAfter.strip()
    let (tags, _) = run("git tag", dir)
    check tags.strip().len == 0
    check run("git status --porcelain", dir).output.strip().len > 0

  test "bump --no-tag commits without creating a tag":
    let dir = freshRepo("bump-no-tag")
    discard commitFile(dir, "a.txt", "hi", "fix: patch it")
    let (_, code) = run("nimver bump --no-tag", dir)
    check code == 0
    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v0.1.1"
    let (tags, _) = run("git tag", dir)
    check tags.strip().len == 0

  test "bump --no-commit alone skips the tag too":
    let dir = freshRepo("bump-no-commit-only")
    discard commitFile(dir, "a.txt", "hi", "fix: patch it")
    let (headBefore, _) = run("git rev-parse HEAD", dir)

    let (output, code) = run("nimver bump --no-commit", dir)
    check code == 0
    check "Skipped tag" in output

    let (headAfter, _) = run("git rev-parse HEAD", dir)
    check headBefore.strip() == headAfter.strip()
    let (tags, _) = run("git tag", dir)
    check tags.strip().len == 0

  test "bump tags the release by default":
    let dir = freshRepo("bump-tag")
    discard commitFile(dir, "a.txt", "hi", "fix: patch it")
    let (_, code) = run("nimver bump", dir)
    check code == 0
    let (tags, _) = run("git tag", dir)
    check "v0.1.1" in tags
