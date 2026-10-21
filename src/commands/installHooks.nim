import std/strutils
import results
import ../sysio
import ../effects
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

proc writeHook(hooksDir, name, content: string, force: bool): Result[Effects, string] =
  let hookPath = hooksDir / name
  if fileAt(hookPath) and not force:
    return
      err("Hook already exists at " & hookPath & ". Re-run with --force to overwrite.")
  ok(@[writeTo(hookPath, content), markExecutable(hookPath)])

proc removeRetiredHooks(hooksDir: string): Result[Effects, string] =
  var removals: Effects = @[]
  for hookName in RetiredHooks:
    let hookPath = hooksDir / hookName
    if fileAt(hookPath) and (?readFileContents(hookPath)).contains(HookMarker):
      removals.add(deleteAt(hookPath))
      removals.add(say("Removed obsolete " & hookName & " hook at " & hookPath))
  ok(removals)

proc cmdInstallHooks*(
    repoRoot: string, force: bool, effects: var Effects
): Result[void, string] =
  let hooksDir = ?gitPath(repoRoot, "hooks")
  if not directoryAt(hooksDir):
    return err("No hooks directory found at " & hooksDir)

  let hookWrites = ?writeHook(hooksDir, "commit-msg", commitMsgHook(), force)
  let removals = ?removeRetiredHooks(hooksDir)

  effects.add(hookWrites)
  effects.add(say("Installed commit-msg hook at " & hooksDir / "commit-msg"))
  effects.add(removals)
  ok()
