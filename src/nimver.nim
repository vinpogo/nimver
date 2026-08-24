import std/[os, strutils, sequtils, options]
import ./gitutils
import ./result
import ./commands/init
import ./commands/version
import ./commands/installHooks
import ./commands/checkCommitMsg
import ./commands/bump

const Usage = """
nimver - semantic versioning from Conventional Commits

Usage:
  nimver init
  nimver install-hooks [--force]
  nimver bump [<package>] [--dry-run]
  nimver version

See https://github.com/vinpogo/nimver for details.

"""

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    echo Usage
    quit(1)

  let command = args[0]
  let params = args[1 ..^ 1]

  if command in ["version", "--version", "-v"]:
    cmdVersion()
    quit(0)

  if ["--help", "-h"].anyIt(it in params):
    echo Usage
    quit(0)

  var repoRoot: string
  try:
    repoRoot = findRepoRoot()
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)

  try:
    case command
    of "init":
      cmdInit(repoRoot)
    of "install-hooks":
      cmdInstallHooks(repoRoot, "--force" in params)
    of "check-commit-msg":
      if params.len < 1:
        stderr.writeLine("Usage: nimver check-commit-msg <path-to-message-file>")
        quit(1)
      let checkResult = cmdCheckCommitMsg(repoRoot, params[0])
      if isFailure(checkResult):
        stderr.writeLine(checkResult.error)
        quit(1)
    of "bump":
      let nonFlagArgs = params.filterIt(not it.startsWith("--"))
      if nonFlagArgs.len > 1:
        stderr.writeLine("nimver: `bump` takes at most one package name")
        quit(1)
      let requestedPackageName =
        if nonFlagArgs.len > 0:
          some(nonFlagArgs[0])
        else:
          none(string)
      cmdBump(repoRoot, requestedPackageName, "--dry-run" in params)
    else:
      echo Usage
      quit(1)
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)
