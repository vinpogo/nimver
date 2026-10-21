## Filesystem, process and CLI primitives, backed by the OS on the C backend and
## by Node's `fs`/`child_process` on the JS backend. Whatever can fail answers
## with a Result rather than raising.

import std/[os, sequtils]
import results
export
  os.`/`, os.parentDir, os.extractFilename, os.isAbsolute, os.splitFile,
  os.relativePath, os.lastPathPart, os.changeFileExt

type CommandResult* = tuple[output: string, exitCode: int]

when defined(js):
  type
    SpawnResult = ref object of RootObj
    Attempt = ref object of RootObj

  proc jsAttempt(
    action: proc(): cstring
  ): Attempt {.
    importjs:
      "((f) => { try { return {ok: true, value: f()}; } catch (e) { return {ok: false, value: String((e && e.message) || e)}; } })(#)"
  .}

  proc attemptSucceeded(attempt: Attempt): bool {.importjs: "#.ok".}

  proc attemptValue(attempt: Attempt): cstring {.importjs: "#.value".}

  proc attempt(action: proc(): cstring): Result[string, string] =
    ## Node's `fs` throws JavaScript errors, which Nim's `except` does not see.
    let attempted = jsAttempt(action)
    if attempted.attemptSucceeded:
      ok($attempted.attemptValue)
    else:
      err($attempted.attemptValue)

  proc attemptAction(action: proc()): Result[void, string] =
    discard ?attempt(
      proc(): cstring =
        action()
        ""
    )
    ok()

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

  proc jsScriptPath(): cstring {.importjs: "(() => process.argv[1])()".}

  proc jsWriteErr(message: cstring) {.importjs: "process.stderr.write(#)".}

  proc readFileContents*(path: string): Result[string, string] =
    attempt(
      proc(): cstring =
        jsReadFile(path.cstring)
    )

  proc writeFileContents*(path, contents: string): Result[void, string] =
    attemptAction(
      proc() =
        jsWriteFile(path.cstring, contents.cstring)
    )

  proc pathExists*(path: string): bool =
    jsExists(path.cstring)

  proc fileAt*(path: string): bool =
    jsIsFile(path.cstring)

  proc directoryAt*(path: string): bool =
    jsIsDirectory(path.cstring)

  proc makeDirectory*(path: string): Result[void, string] =
    attemptAction(
      proc() =
        jsMkdir(path.cstring)
    )

  proc deleteFile*(path: string): Result[void, string] =
    attemptAction(
      proc() =
        jsUnlink(path.cstring)
    )

  proc makeExecutable*(path: string): Result[void, string] =
    attemptAction(
      proc() =
        jsChmod(path.cstring)
    )

  proc filesIn*(directory: string): Result[seq[string], string] =
    var entries: seq[cstring]
    ?attemptAction(
      proc() =
        entries = jsReadDir(directory.cstring)
    )
    var files: seq[string] = @[]
    for entry in entries:
      let entryPath = directory / $entry
      if fileAt(entryPath):
        files.add(entryPath)
    ok(files)

  proc runCommand*(
      command: string, arguments: seq[string]
  ): Result[CommandResult, string] =
    ## `spawnSync` reports a command it could not start in its result rather
    ## than by throwing, as a status of 1.
    let spawned = jsSpawn(command.cstring, arguments.mapIt(it.cstring))
    ok(($spawned.spawnOutput(), spawned.spawnStatus()))

  proc cliArgs*(): seq[string] =
    jsArgv().mapIt($it)

  proc executablePath*(): string =
    $jsScriptPath()

  proc writeError*(message: string) =
    jsWriteErr((message & "\n").cstring)

else:
  import std/[osproc, strutils, sugar]

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
