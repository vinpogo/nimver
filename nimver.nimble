# Package

version       = "2.0.0"
author        = "vingy"
description   = "A package to manage semantic versioning from commit messages"
license       = "MIT"
srcDir        = "src"
bin           = @["nimver"]


# Dependencies

requires "nim >= 2.2.10"

# Tasks

task test, "Build the binary and run end-to-end tests":
  exec "nimble build"
  exec "nim c -r --hints:off --path:src tests/test_e2e.nim"
