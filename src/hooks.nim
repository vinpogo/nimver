## Installs the Git hooks that delegate to this binary.
##
## Two hooks are used because a commit's tree is snapshotted before
## `commit-msg` runs, so a file written and staged there does *not* make it
## into that commit (only `pre-commit` can still influence the tree at that
## point). Instead:
##   - `commit-msg` only validates the message and can reject the commit.
##   - `post-commit` writes the bump-note file for the commit that was just
##     created and folds it in via a guarded `commit --amend`.

import std/os
import ./gitutils

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

proc installHooks*(repoRoot: string, force: bool): string =
  ## Installs both hooks and returns the directory they were written to. That
  ## directory is resolved through Git rather than assumed to be
  ## `<root>/.git/hooks`, so this also works from a linked worktree or any
  ## other checkout whose `.git` is a file (see `gitPath`). Note that Git
  ## shares one hooks directory across all worktrees of a repository.
  let hooksDir = gitPath(repoRoot, "hooks")
  if not dirExists(hooksDir):
    raise newException(IOError, "No hooks directory found at " & hooksDir)

  writeHook(hooksDir, "commit-msg", CommitMsgHook, force)
  writeHook(hooksDir, "post-commit", PostCommitHook, force)
  hooksDir
