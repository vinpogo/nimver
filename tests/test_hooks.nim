## The `commit-msg` hook, which is all nimver installs: committing records
## nothing, it only refuses messages a release would not be able to read.

import std/[unittest, os, strutils]
import ./support

suite "hooks":
  test "committing writes nothing into the repository":
    let dir = freshRepo("commit-writes-nothing")
    let (_, code) = commitFile(dir, "a.txt", "hi", "feat: add a")
    check code == 0
    # No bookkeeping file in the commit, and nothing left over in the working
    # tree. (The commit also carries `.nimver/config.ini`, which `freshRepo`
    # writes but does not commit.)
    check not dirExists(dir / ".nimver" / "changes")
    check run("git status --porcelain", dir).output.strip().len == 0
    check ".nimver/changes" notin run("git show --name-only --pretty= HEAD", dir).output
    check "a.txt" in run("git show --name-only --pretty= HEAD", dir).output
    check "0.1.0 -> 0.2.0 (minor)" in pending(dir)

  test "invalid commit type is rejected by the commit-msg hook":
    let dir = freshRepo("invalid-type")
    let (output, code) = commitFile(dir, "a.txt", "hi", "bogus: nope")
    check code != 0
    check "unknown commit type 'bogus'" in output
    check run("git log --oneline", dir).output.count("bogus") == 0

  test "breaking change forces a major bump regardless of type mapping":
    let dir = freshRepo("breaking")
    check commitFile(dir, "a.txt", "hi", "fix!: breaking fix").code == 0
    check "-> 1.0.0 (major)" in pending(dir)

  test "the bump mapping comes from config.ini":
    let dir = freshRepo("config-driven")
    let configFile = dir / ".nimver" / "config.ini"
    writeFile(configFile, readFile(configFile).replace("fix = patch", "fix = major"))
    discard run("git add -A", dir)
    discard run("git commit -q -m \"chore: fixes are major\"", dir)

    check commitFile(dir, "a.txt", "hi", "fix: b").code == 0
    check "-> 1.0.0 (major)" in pending(dir)

  test "a commit made with --no-verify still counts, and is reported if unusable":
    # The hook is the only thing checking messages, so bypassing it can leave a
    # type no config maps. A release says so rather than passing over it.
    let dir = freshRepo("no-verify")
    writeFile(dir / "a.txt", "hi")
    discard run("git add -A", dir)
    check run("git commit -q --no-verify -m \"feat: slipped past the hook\"", dir).code ==
      0
    check "0.1.0 -> 0.2.0 (minor)" in pending(dir)

    writeFile(dir / "b.txt", "hi")
    discard run("git add -A", dir)
    check run("git commit -q --no-verify -m \"bogus: nope\"", dir).code == 0
    let dryRun = pending(dir)
    check "unknown commit type 'bogus'" in dryRun
    check "nope" notin dryRun.split("---")[^1] # reported, not released

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

    # Wipe the hook installed by `freshRepo` so the install below is the only
    # thing that could have put it back.
    removeFile(dir / ".git" / "hooks" / "commit-msg")

    r = run("nimver install-hooks", linked)
    check r.code == 0
    # Git shares one hooks directory across every worktree of a repository.
    check fileExists(dir / ".git" / "hooks" / "commit-msg")

    r = run("nimver init", linked)
    check r.code == 0
    check commitFile(linked, "a.txt", "hi", "feat: add a").code == 0
    check "0.1.0 -> 0.2.0 (minor)" in pending(linked)
    check commitFile(linked, "b.txt", "hi", "bogus: nope").code != 0

  test "install-hooks clears out the hooks earlier versions left behind":
    # `post-commit` and `post-rewrite` used to keep a change-note file in step
    # with its commit. Left in place they would call subcommands that no longer
    # exist, failing on every commit.
    let dir = freshRepo("retired-hooks")
    let hooksDir = dir / ".git" / "hooks"
    for hookName in ["post-commit", "post-rewrite"]:
      writeFile(
        hooksDir / hookName,
        "#!/bin/sh\n# Installed by nimver. Do not edit by hand;\nexec nimver record-commit\n",
      )
      setFilePermissions(hooksDir / hookName, {fpUserRead, fpUserWrite, fpUserExec})

    let (output, code) = run("nimver install-hooks --force", dir)
    check code == 0
    check "Removed obsolete post-commit hook" in output
    check not fileExists(hooksDir / "post-commit")
    check not fileExists(hooksDir / "post-rewrite")
    check fileExists(hooksDir / "commit-msg")

  test "install-hooks leaves hooks nimver did not write alone":
    let dir = freshRepo("foreign-hooks")
    let foreignHook = dir / ".git" / "hooks" / "post-commit"
    writeFile(foreignHook, "#!/bin/sh\necho mine\n")
    setFilePermissions(foreignHook, {fpUserRead, fpUserWrite, fpUserExec})

    check run("nimver install-hooks --force", dir).code == 0
    check fileExists(foreignHook)
    check "echo mine" in readFile(foreignHook)
