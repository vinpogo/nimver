# Package

version       = "5.3.1-beta.4"
author        = "vingy"
description   = "A package to manage semantic versioning from commit messages"
license       = "MIT"
srcDir        = "src"
bin           = @["nimver"]


# Dependencies

requires "nim >= 2.2.12"
requires "results >= 0.5.1"


# Build tasks

task buildBinary, "Compile the native binary into dist/":
  # Release builds pass target-specific flags here: a static musl link, or a
  # cross-compile to another architecture.
  mkDir "dist"
  exec "nim c -d:release --opt:speed -d:NimblePkgVersion:" & version &
    " --hints:off --path:src " & getEnv("NIMVER_NIMFLAGS") & " -o:dist/nimver src/nimver.nim"
