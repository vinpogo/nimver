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

  test "sourceFiles override nearest-manifest attribution":
    # `docs/` sits outside both packages, so nearest-ancestor alone would hand
    # it to sharedChanges; an explicit pattern claims it for `web` instead.
    let dir = freshWorkspaceRepo("workspace-source-files")
    let configPath = dir / ".nimver" / "config.ini"
    writeFile(
      configPath,
      readFile(configPath).replace(
        "[package.web]\nmanifest = packages/web/package.json\n",
        "[package.web]\nmanifest = packages/web/package.json\nsourceFiles = \"packages/web/**, docs/**\"\n",
      ),
    )
    discard run("git add -A", dir)
    discard run("git commit -q --no-verify -m \"chore: claim docs for web\"", dir)

    createDir(dir / "docs")
    let (_, code) = commitFile(dir, "docs/guide.md", "# Guide\n", "feat: document web")
    check code == 0

    # The config commit above records a note of its own, so pick out this one.
    let notes = changeNotes(dir).filterIt("feat: document web" in readFile(it))
    require notes.len == 1
    # Anchored on the line end: a bare `packages=web` check also passes for
    # `packages=web,cli`, which is what a pattern matching nothing produces.
    check "packages=web\n" in readFile(notes[0])

  test "an unquoted glob in sourceFiles is rejected":
    # The ini format ends an unquoted value at the first `*`, so the pattern
    # would silently narrow to `packages/web/` and claim nothing.
    let dir = freshWorkspaceRepo("workspace-unquoted-glob")
    let configPath = dir / ".nimver" / "config.ini"
    writeFile(
      configPath,
      readFile(configPath).replace(
        "[package.web]\nmanifest = packages/web/package.json\n",
        "[package.web]\nmanifest = packages/web/package.json\nsourceFiles = packages/web/**\n",
      ),
    )

    let (output, code) = run("nimver bump --dry-run", dir)
    check code != 0
    check "Unquoted `*`" in output
    check "has to be quoted" in output

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
