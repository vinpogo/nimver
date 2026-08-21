import std/os
import ../gitutils

const CommitMsgHook = """#!/bin/sh
# Installed by nimver. Do not edit by hand;
# re-run `nimver install-hooks --force` to regenerate.
exec nimver check-commit-msg "$1"
"""

const PostCommitHook = """#!/bin/sh
# Installed by nimver. Do not edit by hand;
# re-run `nimver install-hooks --force` to regenerate.
#
# Guard against re-entrancy: `record-commit` folds its note file into HEAD via
# `commit --amend`, which triggers this same hook again.
if [ -n "$NIMVER_AMENDING" ]; then
  exit 0
fi
exec nimver record-commit
"""

const PostRewriteHook = """#!/bin/sh
# Installed by nimver. Do not edit by hand;
# re-run `nimver install-hooks --force` to regenerate.
#
# Runs once a rebase has finished rewriting commits, so notes reworded along
# the way can be brought back in line with their messages.
if [ -n "$NIMVER_AMENDING" ]; then
  exit 0
fi
exec nimver record-rewrite "$1"
"""

const ExecutablePerms = {
  fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
  fpOthersExec,
}

proc writeHook(hooksDir, name, content: string, force: bool) =
  let hookPath = hooksDir / name
  if fileExists(hookPath) and not force:
    raise newException(
      IOError,
      "Hook already exists at " & hookPath & ". Re-run with --force to overwrite.",
    )
  writeFile(hookPath, content)
  setFilePermissions(hookPath, ExecutablePerms)

proc cmdInstallHooks*(repoRoot: string, force: bool) =
  let hooksDir = gitPath(repoRoot, "hooks")
  if not dirExists(hooksDir):
    raise newException(IOError, "No hooks directory found at " & hooksDir)

  writeHook(hooksDir, "commit-msg", CommitMsgHook, force)
  echo "Installed commit-msg hook at ", hooksDir / "commit-msg"

  writeHook(hooksDir, "post-commit", PostCommitHook, force)
  echo "Installed post-commit hook at ", hooksDir / "post-commit"

  writeHook(hooksDir, "post-rewrite", PostRewriteHook, force)
  echo "Installed post-rewrite hook at ", hooksDir / "post-rewrite"
