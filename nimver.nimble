# Package

version       = "3.0.0"
author        = "vingy"
description   = "A package to manage semantic versioning from commit messages"
license       = "MIT"
srcDir        = "src"
bin           = @["nimver"]


# Dependencies

requires "nim >= 2.2.10"


# Build tasks

task buildBinary, "Compile the native binary into dist/":
  mkDir "dist"
  exec "nim c -d:release --opt:speed -d:NimblePkgVersion:" & version &
    " --hints:off --path:src -o:dist/nimver src/nimver.nim"

task buildJs, "Compile the Node bundle into bin/, ready for `npm publish`":
  mkDir "bin"
  exec "nim js -d:release -d:nodejs -d:NimblePkgVersion:" & version &
    " --hints:off --path:src -o:bin/nimver.js src/nimver.nim"
  writeFile("bin/nimver.js", "#!/usr/bin/env node\n" & readFile("bin/nimver.js"))
  when not defined(windows):
    exec "chmod +x bin/nimver.js"
