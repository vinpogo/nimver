import std/[strutils, sequtils, options]
import ./sysio
import ./effects
import ./gitutils
import results
import ./commands/init
import ./commands/version
import ./commands/installHooks
import ./commands/checkCommitMsg
import ./commands/bump
import ./commands/track
import ./commands/changelog

const Usage = """
nimver - semantic versioning from Conventional Commits

Usage:
  nimver init
  nimver install-hooks [--force]
  nimver bump [<package>] [--dry-run] [--stable]
  nimver changelog [<package>] <version>
  nimver track
  nimver track enter <name> [--package <name>] [--stable]
  nimver track exit [--package <name>]
  nimver version

See https://github.com/vinpogo/nimver for details.

"""

proc dispatch(args: seq[string], effects: var Effects): Result[int, string] =
  ## The exit code the command ends with, its effects queued but not yet
  ## performed.
  if args.len == 0:
    effects.add(say(Usage))
    return ok(1)

  let command = args[0]
  let params = args[1 ..^ 1]

  if command in ["version", "--version", "-v"]:
    effects.add(cmdVersion())
    return ok(0)

  if ["--help", "-h"].anyIt(it in params):
    effects.add(say(Usage))
    return ok(0)

  let repoRoot = ?findRepoRoot()
  case command
  of "init":
    ?cmdInit(repoRoot, effects)
  of "install-hooks":
    ?cmdInstallHooks(repoRoot, "--force" in params, effects)
  of "check-commit-msg":
    if params.len < 1:
      effects.add(warn("Usage: nimver check-commit-msg <path-to-message-file>"))
      return ok(1)
    return cmdCheckCommitMsg(repoRoot, params[0], effects)
  of "bump":
    # A flag nobody recognises is refused rather than ignored: a typo'd
    # `--stabel` would otherwise tag the version the commits happened to add
    # up to, and say nothing about having been misread.
    for param in params:
      if param.startsWith("-") and param notin ["--dry-run", "--stable"]:
        return err("unknown option '" & param & "' for `nimver bump`")
    let nonFlagArgs = params.filterIt(not it.startsWith("-"))
    if nonFlagArgs.len > 1:
      return err("`bump` takes at most one package name")
    let requestedPackageName =
      if nonFlagArgs.len > 0:
        some(nonFlagArgs[0])
      else:
        none(string)
    ?cmdBump(
      repoRoot,
      requestedPackageName,
      "--dry-run" in params,
      "--stable" in params,
      effects,
    )
  of "changelog":
    for param in params:
      if param.startsWith("-"):
        return err("unknown option '" & param & "' for `nimver changelog`")
    case params.len
    of 1:
      ?cmdChangelog(repoRoot, none(string), params[0], effects)
    of 2:
      ?cmdChangelog(repoRoot, some(params[0]), params[1], effects)
    else:
      return err("`changelog` takes a version, optionally preceded by a package name")
  of "track":
    ?cmdTrack(repoRoot, params, effects)
  else:
    effects.add(say(Usage))
    return ok(1)
  ok(0)

proc run(args: seq[string]): int =
  ## The one place a command's effects are performed. A command that failed
  ## still has what it queued performed first, so that what it said before
  ## failing is not lost.
  var effects: Effects
  let exitCode = dispatch(args, effects)
  perform(effects).isOkOr:
    writeError("nimver: " & error)
    return 1
  exitCode.valueOr:
    writeError("nimver: " & error)
    return 1

when isMainModule:
  quit(run(cliArgs()))
