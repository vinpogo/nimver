## Attributing a commit's files to workspace packages: nearest-ancestor manifest
## lookup, and the `sharedChanges` policy for files outside every package.
##
## Attribution is not written down anywhere, so what a release makes of it is
## what these tests read: an independent workspace bumps each package on its
## own, and names the ones it is bumping.

import std/[unittest, os, strutils]
import ./support

suite "workspace attribution":
  test "a change inside one package bumps only that package":
    let dir = freshWorkspaceRepo("workspace-attribution", strategy = "independent")
    let (_, code) =
      commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    check code == 0

    let dryRun = pending(dir)
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in dryRun
    check "Bumping cli" notin dryRun

  test "workspace shared changes affect every package":
    let dir = freshWorkspaceRepo("workspace-shared-all", strategy = "independent")
    let (_, code) = commitFile(dir, "README.md", "# Workspace\n", "fix: document")
    check code == 0

    let dryRun = pending(dir)
    check "Bumping web: 0.1.0 -> 0.1.1 (patch)" in dryRun
    check "Bumping cli: 0.1.0 -> 0.1.1 (patch)" in dryRun

  test "workspace can ignore shared changes":
    let dir = freshWorkspaceRepo(
      "workspace-shared-none", sharedChanges = "none", strategy = "independent"
    )
    let (_, code) = commitFile(dir, "README.md", "# Workspace\n", "fix: document")
    check code == 0
    check "Nothing to bump" in pending(dir)

  test "sourceFiles override nearest-manifest attribution":
    # `docs/` sits outside both packages, so nearest-ancestor alone would hand
    # it to sharedChanges; an explicit pattern claims it for `web` instead.
    let dir = freshWorkspaceRepo(
      "workspace-source-files", sharedChanges = "none", strategy = "independent"
    )
    let configFile = dir / ".nimver" / "config.ini"
    writeFile(
      configFile,
      readFile(configFile).replace(
        "[package.web]\nmanifest = packages/web/package.json\n",
        "[package.web]\nmanifest = packages/web/package.json\nsourceFiles = \"packages/web/**, docs/**\"\n",
      ),
    )
    discard run("git add -A", dir)
    discard run("git commit -q --no-verify -m \"chore: claim docs for web\"", dir)

    createDir(dir / "docs")
    let (_, code) = commitFile(dir, "docs/guide.md", "# Guide\n", "feat: document web")
    check code == 0

    let dryRun = pending(dir)
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in dryRun
    check "Bumping cli" notin dryRun

  test "an unquoted glob in sourceFiles is rejected":
    # The ini format ends an unquoted value at the first `*`, so the pattern
    # would silently narrow to `packages/web/` and claim nothing.
    let dir = freshWorkspaceRepo("workspace-unquoted-glob")
    let configFile = dir / ".nimver" / "config.ini"
    writeFile(
      configFile,
      readFile(configFile).replace(
        "[package.web]\nmanifest = packages/web/package.json\n",
        "[package.web]\nmanifest = packages/web/package.json\nsourceFiles = packages/web/**\n",
      ),
    )

    let (output, code) = run("nimver bump --dry-run", dir)
    check code != 0
    check "Unquoted `*`" in output
    check "has to be quoted" in output

  test "nested packages attribute changes to the nearest manifest":
    let dir = freshWorkspaceRepo(
      "workspace-nearest-manifest",
      sharedChanges = "none",
      includeRootPackage = true,
      strategy = "independent",
    )

    # Inside `packages/web`, so the nearest manifest is the web package's, even
    # though the root package's manifest is also an ancestor.
    check commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web").code ==
      0
    var dryRun = pending(dir)
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in dryRun
    check "Bumping root" notin dryRun

    # Outside every nested package, so the root package is the nearest.
    createDir(dir / "src")
    check commitFile(dir, "src/main.nim", "echo 1\n", "fix: patch root").code == 0
    dryRun = pending(dir)
    check "Bumping root: 0.1.0 -> 0.1.1 (patch)" in dryRun
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in dryRun
