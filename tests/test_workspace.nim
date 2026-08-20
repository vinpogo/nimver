## Attributing a commit's files to workspace packages: nearest-ancestor manifest
## lookup, and the `sharedChanges` policy for files outside every package.

import std/[unittest, os, strutils, sequtils]
import ./support

suite "workspace attribution":
  test "workspace change notes record affected packages":
    let dir = freshWorkspaceRepo("workspace-attribution")
    let (_, code) =
      commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    check code == 0

    let notes = changeNotes(dir)
    check notes.len == 1
    let content = readFile(notes[0])
    check "packages=web" in content
    check "packages=cli" notin content

  test "workspace shared changes affect every package":
    let dir = freshWorkspaceRepo("workspace-shared-all")
    let (_, code) = commitFile(dir, "README.md", "# Workspace\n", "fix: document")
    check code == 0

    let notes = changeNotes(dir)
    check notes.len == 1
    check "packages=web,cli" in readFile(notes[0])

  test "workspace can ignore shared changes":
    let dir = freshWorkspaceRepo("workspace-shared-none", "none")
    let (_, code) = commitFile(dir, "README.md", "# Workspace\n", "fix: document")
    check code == 0
    check changeNotes(dir).len == 0

  test "workspace can assign shared changes to one package":
    let dir = freshWorkspaceRepo("workspace-shared-package", "package.cli")
    let (_, code) = commitFile(dir, "README.md", "# Workspace\n", "fix: document")
    check code == 0

    let notes = changeNotes(dir)
    require notes.len == 1
    check "packages=cli" in readFile(notes[0])

  test "nested packages attribute changes to the nearest manifest":
    let dir =
      freshWorkspaceRepo("workspace-nearest-manifest", includeRootPackage = true)

    # Inside `packages/web`, so the nearest manifest is the web package's,
    # even though the root package's manifest is also an ancestor.
    var (_, code) =
      commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    check code == 0
    var notes = changeNotes(dir)
    require notes.len == 1
    check "packages=web" in readFile(notes[0])

    # Outside every nested package, so the root package is the nearest.
    createDir(dir / "src")
    (_, code) = commitFile(dir, "src/main.nim", "echo 1\n", "fix: patch root")
    check code == 0
    notes = changeNotes(dir)
    require notes.len == 2
    let rootNotes = notes.filterIt("fix: patch root" in readFile(it))
    require rootNotes.len == 1
    check "packages=root" in readFile(rootNotes[0])
