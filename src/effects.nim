## Everything nimver changes outside itself, as values. A command only queues
## these; the runner performs them, in order, once the command is done.
##
## A command that fails still has what it queued performed before its error is
## reported, so a warning said ahead of a refusal is not lost. That is safe
## because a command queues a change only after its last step that can fail:
## what precedes a failure is only ever something said.

import ./sysio
import ./gitutils
import results

type
  Effect* = proc(): Result[void, string] {.closure.}
  Effects* = seq[Effect]

proc say*(message: string): Effect =
  proc(): Result[void, string] =
    echo message
    ok()

proc warn*(message: string): Effect =
  proc(): Result[void, string] =
    writeError(message)
    ok()

proc writeTo*(path, contents: string): Effect =
  proc(): Result[void, string] =
    writeFileContents(path, contents)

proc createDirectory*(path: string): Effect =
  proc(): Result[void, string] =
    makeDirectory(path)

proc deleteAt*(path: string): Effect =
  proc(): Result[void, string] =
    deleteFile(path)

proc markExecutable*(path: string): Effect =
  proc(): Result[void, string] =
    makeExecutable(path)

proc git(arguments: seq[string]): Effect =
  proc(): Result[void, string] =
    discard ?runGit(arguments)
    ok()

proc stage*(repoRoot, path: string): Effect =
  ## The file itself when `path` is a link to it: what was written through the
  ## link would otherwise be left out of the commit.
  proc(): Result[void, string] =
    discard ?runGit(@["-C", repoRoot, "add", "-A", "--", ?resolvedPath(path)])
    ok()

proc commit*(repoRoot, message: string): Effect =
  git(@["-C", repoRoot, "commit", "-m", message])

proc tag*(repoRoot, name: string): Effect =
  git(@["-C", repoRoot, "tag", "-a", name, "-m", name])

proc perform*(effects: Effects): Result[void, string] =
  ## In order, stopping at the first that fails.
  for effect in effects:
    ?effect()
  ok()
