## Filesystem, process and CLI primitives, backed by the OS on the C backend and
## by Node's `fs`/`child_process` on the JS backend.

import std/[os, sequtils]
export
  os.`/`, os.parentDir, os.extractFilename, os.isAbsolute, os.splitFile,
  os.relativePath, os.lastPathPart, os.changeFileExt

type CommandResult* = tuple[output: string, exitCode: int]

when defined(js):
  type SpawnResult = ref object of RootObj

  proc jsReadFile(
    path: cstring
  ): cstring {.importjs: "require('fs').readFileSync(#, 'utf8')".}

  proc jsWriteFile(
    path, contents: cstring
  ) {.importjs: "require('fs').writeFileSync(#, #, 'utf8')".}

  proc jsExists(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}

  proc jsIsFile(
    path: cstring
  ): bool {.
    importjs:
      "((p) => require('fs').existsSync(p) && require('fs').statSync(p).isFile())(#)"
  .}

  proc jsIsDirectory(
    path: cstring
  ): bool {.
    importjs:
      "((p) => require('fs').existsSync(p) && require('fs').statSync(p).isDirectory())(#)"
  .}

  proc jsMkdir(
    path: cstring
  ) {.importjs: "require('fs').mkdirSync(#, {recursive: true})".}

  proc jsUnlink(path: cstring) {.importjs: "require('fs').unlinkSync(#)".}

  proc jsChmod(path: cstring) {.importjs: "require('fs').chmodSync(#, 0o755)".}

  proc jsReadDir(
    path: cstring
  ): seq[cstring] {.importjs: "require('fs').readdirSync(#)".}

  proc jsSpawn(
    command: cstring, arguments: seq[cstring]
  ): SpawnResult {.
    importjs:
      "require('child_process').spawnSync(#, #, {encoding: 'utf8', maxBuffer: 67108864})"
  .}

  proc spawnOutput(
    spawned: SpawnResult
  ): cstring {.importjs: "((r) => (r.stdout || '') + (r.stderr || ''))(#)".}

  proc spawnStatus(
    spawned: SpawnResult
  ): int {.
    importjs: "((r) => (r.status === null || r.status === undefined) ? 1 : r.status)(#)"
  .}

  proc jsArgv(): seq[cstring] {.importjs: "process.argv.slice(2)".}

  proc jsWriteErr(message: cstring) {.importjs: "process.stderr.write(#)".}

  proc readFileContents*(path: string): string =
    $jsReadFile(path.cstring)

  proc writeFileContents*(path, contents: string) =
    jsWriteFile(path.cstring, contents.cstring)

  proc pathExists*(path: string): bool =
    jsExists(path.cstring)

  proc fileAt*(path: string): bool =
    jsIsFile(path.cstring)

  proc directoryAt*(path: string): bool =
    jsIsDirectory(path.cstring)

  proc makeDirectory*(path: string) =
    jsMkdir(path.cstring)

  proc deleteFile*(path: string) =
    jsUnlink(path.cstring)

  proc makeExecutable*(path: string) =
    jsChmod(path.cstring)

  proc filesIn*(directory: string): seq[string] =
    for entry in jsReadDir(directory.cstring):
      let entryPath = directory / $entry
      if fileAt(entryPath):
        result.add(entryPath)

  proc runCommand*(command: string, arguments: seq[string]): CommandResult =
    let spawned = jsSpawn(command.cstring, arguments.mapIt(it.cstring))
    ($spawned.spawnOutput(), spawned.spawnStatus())

  proc cliArgs*(): seq[string] =
    jsArgv().mapIt($it)

  proc writeError*(message: string) =
    jsWriteErr((message & "\n").cstring)

else:
  import std/[osproc, strutils]

  const ExecutablePermissions = {
    fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
    fpOthersExec,
  }

  proc readFileContents*(path: string): string =
    readFile(path)

  proc writeFileContents*(path, contents: string) =
    writeFile(path, contents)

  proc pathExists*(path: string): bool =
    fileExists(path) or dirExists(path)

  proc fileAt*(path: string): bool =
    fileExists(path)

  proc directoryAt*(path: string): bool =
    dirExists(path)

  proc makeDirectory*(path: string) =
    createDir(path)

  proc deleteFile*(path: string) =
    removeFile(path)

  proc makeExecutable*(path: string) =
    setFilePermissions(path, ExecutablePermissions)

  proc filesIn*(directory: string): seq[string] =
    for entryKind, entryPath in walkDir(directory):
      if entryKind == pcFile:
        result.add(entryPath)

  proc runCommand*(command: string, arguments: seq[string]): CommandResult =
    execCmdEx(command & " " & arguments.mapIt(it.quoteShell).join(" "))

  proc cliArgs*(): seq[string] =
    commandLineParams()

  proc writeError*(message: string) =
    stderr.writeLine(message)
