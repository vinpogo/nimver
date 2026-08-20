# Package

version       = "2.1.0"
author        = "vingy"
description   = "A package to manage semantic versioning from commit messages"
license       = "MIT"
srcDir        = "src"
bin           = @["nimver"]


# Dependencies

requires "nim >= 2.2.10"

# Tasks

import std/[os, strutils]

task test, "Build the binary and run end-to-end tests":
  # Every `tests/test_*.nim` is its own suite; `tests/support.nim` holds the
  # shared fixtures and is not a suite of its own. Suites create their repos
  # under the system temp directory, so nothing needs cleaning up here.
  exec "nimble build"

  # An `exec` that fails raises, and nimble exits 0 regardless (v0.22.2) - even
  # `quit` below does not change that - so a suite that failed, or never ran at
  # all, would otherwise look green. Give every suite a chance to run, then say
  # plainly which ones failed.
  var failedSuites: seq[string] = @[]
  for path in listFiles("tests"):
    let fileName = path.extractFilename()
    if fileName.startsWith("test_") and fileName.endsWith(".nim"):
      try:
        exec "nim c -r --hints:off --path:src " & path
      except OSError:
        failedSuites.add(fileName)

  if failedSuites.len > 0:
    echo "\nFailing suites: " & failedSuites.join(", ")
    quit(1)
