import std/[os, strutils]
import ../gitutils

const HookMarker = "# Installed by nimver."

const CommitMsgHook =
  """#!/bin/sh
""" & HookMarker & """ Do not edit by hand;
# re-run `nimver install-hooks --force` to regenerate.
exec nimver check-commit-msg "$1"
"""

const RetiredHooks = ["post-commit", "post-rewrite"]

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

proc removeRetiredHooks(hooksDir: string) =
  for hookName in RetiredHooks:
    let hookPath = hooksDir / hookName
    if fileExists(hookPath) and readFile(hookPath).contains(HookMarker):
      removeFile(hookPath)
      echo "Removed obsolete ", hookName, " hook at ", hookPath

proc cmdInstallHooks*(repoRoot: string, force: bool) =
  let hooksDir = gitPath(repoRoot, "hooks")
  if not dirExists(hooksDir):
    raise newException(IOError, "No hooks directory found at " & hooksDir)

  writeHook(hooksDir, "commit-msg", CommitMsgHook, force)
  echo "Installed commit-msg hook at ", hooksDir / "commit-msg"

  removeRetiredHooks(hooksDir)
