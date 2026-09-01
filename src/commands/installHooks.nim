import std/strutils
import ../sysio
import ../gitutils

const HookMarker = "# Installed by nimver."

func singleQuoted(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc commitMsgHook(): string =
  """#!/bin/sh
""" & HookMarker & """ Do not edit by hand;
# re-run `nimver install-hooks --force` to regenerate.
if command -v nimver >/dev/null 2>&1; then
  exec nimver check-commit-msg "$1"
fi

nimver_exe=""" &
    singleQuoted(executablePath()) &
    # An explicit newline: one written after `"""` would be swallowed by Nim.
    "\n" & """if [ -x "$nimver_exe" ]; then
  exec "$nimver_exe" check-commit-msg "$1"
fi

printf 'nimver: not on PATH, and %s is gone.\n' "$nimver_exe" >&2
printf 'Reinstall nimver, then re-run: nimver install-hooks --force\n' >&2
exit 1
"""

const RetiredHooks = ["post-commit", "post-rewrite"]

proc writeHook(hooksDir, name, content: string, force: bool) =
  let hookPath = hooksDir / name
  if fileAt(hookPath) and not force:
    raise newException(
      IOError,
      "Hook already exists at " & hookPath & ". Re-run with --force to overwrite.",
    )
  writeFileContents(hookPath, content)
  makeExecutable(hookPath)

proc removeRetiredHooks(hooksDir: string) =
  for hookName in RetiredHooks:
    let hookPath = hooksDir / hookName
    if fileAt(hookPath) and readFileContents(hookPath).contains(HookMarker):
      deleteFile(hookPath)
      echo "Removed obsolete ", hookName, " hook at ", hookPath

proc cmdInstallHooks*(repoRoot: string, force: bool) =
  let hooksDir = gitPath(repoRoot, "hooks")
  if not directoryAt(hooksDir):
    raise newException(IOError, "No hooks directory found at " & hooksDir)

  writeHook(hooksDir, "commit-msg", commitMsgHook(), force)
  echo "Installed commit-msg hook at ", hooksDir / "commit-msg"

  removeRetiredHooks(hooksDir)
