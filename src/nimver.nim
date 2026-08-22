import std/[os, strutils, sequtils, options]
import ./gitutils
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

  if args[0] in ["version", "--version", "-v"]:
    cmdVersion()
    quit(0)

  var repoRoot: string
  try:
    repoRoot = findRepoRoot()
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)

  try:
    case args[0]
    of "init":
      cmdInit(repoRoot)
    of "install-hooks":
      cmdInstallHooks(repoRoot, "--force" in args)
    of "check-commit-msg":
      if args.len < 2:
        stderr.writeLine("Usage: nimver check-commit-msg <path-to-message-file>")
        quit(1)
      cmdCheckCommitMsg(repoRoot, args[1])
    of "bump":
      let nonFlagArgs = args[1 ..^ 1].filterIt(not it.startsWith("--"))
      if nonFlagArgs.len > 1:
        stderr.writeLine("nimver: `bump` takes at most one package name")
        quit(1)
      let requestedPackageName =
        if nonFlagArgs.len > 0:
          some(nonFlagArgs[0])
        else:
          none(string)
      cmdBump(repoRoot, requestedPackageName, "--dry-run" in args)
    else:
      echo Usage
      quit(1)
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)
