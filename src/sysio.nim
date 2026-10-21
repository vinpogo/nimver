## Filesystem, process and CLI primitives. Whatever can fail answers with a
## Result rather than raising.

import std/[os, osproc, sequtils, strutils, sugar]
import results
export
  os.`/`, os.parentDir, os.extractFilename, os.isAbsolute, os.splitFile,
  os.relativePath, os.lastPathPart, os.changeFileExt

type CommandResult* = tuple[output: string, exitCode: int]

const ExecutablePermissions = {
  fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
  fpOthersExec,
}

proc readFileContents*(path: string): Result[string, string] =
  catch(readFile(path)).mapErr(e => e.msg)

proc writeFileContents*(path, contents: string): Result[void, string] =
  catch(writeFile(path, contents)).mapErr(e => e.msg)

proc pathExists*(path: string): bool =
  fileExists(path) or dirExists(path)

proc fileAt*(path: string): bool =
  fileExists(path)

proc directoryAt*(path: string): bool =
  dirExists(path)

proc makeDirectory*(path: string): Result[void, string] =
  catch(createDir(path)).mapErr(e => e.msg)

proc deleteFile*(path: string): Result[void, string] =
  catch(removeFile(path)).mapErr(e => e.msg)

proc makeExecutable*(path: string): Result[void, string] =
  catch(setFilePermissions(path, ExecutablePermissions)).mapErr(e => e.msg)

proc regularFilesIn(directory: string): seq[string] =
  for entryKind, entryPath in walkDir(directory):
    if entryKind == pcFile:
      result.add(entryPath)

proc filesIn*(directory: string): Result[seq[string], string] =
  catch(regularFilesIn(directory)).mapErr(e => e.msg)

proc runCommand*(
    command: string, arguments: seq[string]
): Result[CommandResult, string] =
  catch(execCmdEx(command & " " & arguments.mapIt(it.quoteShell).join(" "))).mapErr(
    e => e.msg
  )

proc cliArgs*(): seq[string] =
  commandLineParams()

proc executablePath*(): string =
  getAppFilename()

proc writeError*(message: string) =
  stderr.writeLine(message)
