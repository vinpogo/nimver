## Releasing a configured workspace: `fixed` moves every package to one shared
## version, `independent` (the default) gives each package its own version.
## Either way a bare `nimver bump` releases every package with pending changes;
## under `independent` a package name narrows the release to that one.
##
## The last suite covers sibling manifests, which live in one directory and so
## share the changelog that sits beside them.

import std/[unittest, os, strutils]
import ./support

suite "workspace strategies":
  test "fixed workspace bump updates every manifest":
    let dir = freshWorkspaceRepo("workspace-fixed-bump")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "0.1.0 -> 0.2.0" in output
    check "\"version\": \"0.2.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check "version = \"0.2.0\"" in readFile(dir / "packages" / "cli" / "cli.nimble")

    let (changedFiles, _) = run("git show --pretty=format: --name-only HEAD", dir)
    check "packages/web/package.json" in changedFiles
    check "packages/cli/cli.nimble" in changedFiles

  test "fixed workspace bump rejects divergent manifest versions":
    let dir = freshWorkspaceRepo("workspace-divergent")
    writeFile(dir / "packages" / "cli" / "cli.nimble", "version = \"0.2.0\"\n")
    discard run("git add packages/cli/cli.nimble", dir)
    discard run("git commit -q --no-verify -m \"chore: diverge package versions\"", dir)
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "fix: patch web")

    let (output, code) = run("nimver bump --no-commit --no-tag", dir)
    check code != 0
    check "Fixed workspace manifests must have the same version" in output
    check "\"version\": \"0.1.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check "version = \"0.2.0\"" in readFile(dir / "packages" / "cli" / "cli.nimble")

  test "fixed bump rejects a package argument":
    let dir = freshWorkspaceRepo("fixed-with-package")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")

    let (output, code) = run("nimver bump web", dir)
    check code != 0
    check "releases every package at once" in output

  test "independent bump releases only the requested package":
    let dir = freshWorkspaceRepo("independent-single", strategy = "independent")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")

    let (output, code) = run("nimver bump web", dir)
    check code == 0
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in output

    # Only the released package moves; the other keeps its own version.
    check "\"version\": \"0.2.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check "version = \"0.1.0\"" in readFile(dir / "packages" / "cli" / "cli.nimble")

    # The changelog lives next to the manifest it describes.
    check fileExists(dir / "packages" / "web" / "CHANGELOG.md")
    check not fileExists(dir / "CHANGELOG.md")

    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version(web): v0.2.0"
    let (tags, _) = run("git tag", dir)
    check "web-v0.2.0" in tags.strip()

  test "a shared change is released once per package, on each one's schedule":
    # Each package reads back to its *own* last release, so releasing `web`
    # says nothing about what `cli` still owes - the one commit is spent twice,
    # once by each.
    let dir = freshWorkspaceRepo("independent-shared", strategy = "independent")
    discard commitFile(dir, "README.md", "# Workspace\n", "feat: shared change")

    var (output, code) = run("nimver bump web", dir)
    check code == 0
    check "0.1.0 -> 0.2.0" in output
    check "shared change" in readFile(dir / "packages" / "web" / "CHANGELOG.md")

    # `cli` has not released yet, so the change is still ahead of it.
    check "Bumping cli: 0.1.0 -> 0.2.0 (minor)" in pending(dir, "cli")
    (output, code) = run("nimver bump cli", dir)
    check code == 0
    check "0.1.0 -> 0.2.0" in output
    check "shared change" in readFile(dir / "packages" / "cli" / "CHANGELOG.md")

    # And now neither has anything left.
    check "Nothing to bump" in pending(dir)

    check "\"version\": \"0.2.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check "version = \"0.2.0\"" in readFile(dir / "packages" / "cli" / "cli.nimble")
    let (tags, _) = run("git tag", dir)
    check "web-v0.2.0" in tags
    check "cli-v0.2.0" in tags

  test "independent packages can drift apart in version":
    let dir = freshWorkspaceRepo("independent-drift", strategy = "independent")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "fix!: break web")
    discard commitFile(dir, "packages/cli/main.nim", "echo 1\n", "fix: patch cli")

    check run("nimver bump web", dir).code == 0
    check run("nimver bump cli", dir).code == 0

    check "\"version\": \"1.0.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check "version = \"0.1.1\"" in readFile(dir / "packages" / "cli" / "cli.nimble")

  test "independent bump without a package releases every package at its own version":
    let dir = freshWorkspaceRepo("independent-all", strategy = "independent")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    discard commitFile(dir, "packages/cli/main.nim", "echo 1\n", "fix: patch cli")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in output
    check "Bumping cli: 0.1.0 -> 0.1.1 (patch)" in output

    # Independent versions, so the two packages land on different numbers.
    check "\"version\": \"0.2.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check "version = \"0.1.1\"" in readFile(dir / "packages" / "cli" / "cli.nimble")
    check fileExists(dir / "packages" / "web" / "CHANGELOG.md")
    check fileExists(dir / "packages" / "cli" / "CHANGELOG.md")
    check not fileExists(dir / "CHANGELOG.md")

    # One release commit, carrying one tag per released package.
    # Alphabetical by package name, not the order the config declares them in.
    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: cli-v0.1.1, web-v0.2.0"
    let (changedFiles, _) = run("git show --pretty=format: --name-only HEAD", dir)
    check "packages/web/package.json" in changedFiles
    check "packages/cli/cli.nimble" in changedFiles
    let (head, _) = run("git rev-parse HEAD", dir)
    check run("git rev-list -1 web-v0.2.0", dir).output.strip() == head.strip()
    check run("git rev-list -1 cli-v0.1.1", dir).output.strip() == head.strip()

  test "independent bump without a package skips packages with nothing pending":
    let dir = freshWorkspaceRepo("independent-all-partial", strategy = "independent")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in output
    check "version = \"0.1.0\"" in readFile(dir / "packages" / "cli" / "cli.nimble")

    # A lone released package keeps the package-scoped subject and single tag.
    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version(web): v0.2.0"
    let (tags, _) = run("git tag", dir)
    check tags.strip() == "web-v0.2.0"

  test "independent bump releases a shared change for every package at once":
    let dir = freshWorkspaceRepo("independent-all-shared", strategy = "independent")
    discard commitFile(dir, "README.md", "# Workspace\n", "feat: shared change")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "Bumping web: 0.1.0 -> 0.2.0 (minor)" in output
    check "Bumping cli: 0.1.0 -> 0.2.0 (minor)" in output

    check "shared change" in readFile(dir / "packages" / "web" / "CHANGELOG.md")
    check "shared change" in readFile(dir / "packages" / "cli" / "CHANGELOG.md")
    check "Nothing to bump" in pending(dir)

  test "independent bump rejects an unknown package":
    let dir = freshWorkspaceRepo("independent-unknown", strategy = "independent")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")

    let (output, code) = run("nimver bump nope", dir)
    check code != 0
    check "Unknown package 'nope'" in output
    check "web, cli" in output

  test "a workspace without an explicit strategy versions independently":
    let dir = freshWorkspaceRepo("default-strategy", strategy = "")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")

    # Releasing one package by name leaves the other alone, rather than
    # moving both to a shared version the way `fixed` would.
    let (output, code) = run("nimver bump web", dir)
    check code == 0
    check "Bumping web: 0.1.0 -> 0.2.0" in output
    check "\"version\": \"0.2.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check "version = \"0.1.0\"" in readFile(dir / "packages" / "cli" / "cli.nimble")
    let (tags, _) = run("git tag", dir)
    check "web-v0.2.0" in tags

  test "independent bump orders a shared changelog alphabetically":
    let dir = freshSiblingWorkspaceRepo("siblings-shared-changelog", sourceFiles = true)
    createDir(dir / "packages" / "both" / "alpha")
    createDir(dir / "packages" / "both" / "beta")
    discard commitFile(dir, "packages/both/alpha/a.nim", "echo 1\n", "feat: add alpha")
    discard commitFile(dir, "packages/both/beta/b.nim", "echo 2\n", "fix: patch beta")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "Bumping alpha: 0.1.0 -> 0.2.0 (minor)" in output
    check "Bumping beta: 0.1.0 -> 0.1.1 (patch)" in output

    # Siblings are still versioned independently, sharing only the changelog.
    check "version = \"0.2.0\"" in readFile(dir / "packages" / "both" / "alpha.nimble")
    check "version = \"0.1.1\"" in readFile(dir / "packages" / "both" / "beta.nimble")

    let changelogPath = dir / "packages" / "both" / "CHANGELOG.md"
    require fileExists(changelogPath)
    check not fileExists(dir / "CHANGELOG.md")
    let changelog = readFile(changelogPath)

    # Each section names its package, since the version alone would not say
    # which of the two moved.
    check "## [alpha 0.2.0]" in changelog
    check "## [beta 0.1.1]" in changelog
    check "add alpha" in changelog
    check "patch beta" in changelog
    # Alphabetical, even though the config declares `beta` first.
    check changelog.find("## [alpha") < changelog.find("## [beta")
    # One prepend for the file, so the header is not repeated per package.
    check changelog.count("# Changelog") == 1

    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: alpha-v0.2.0, beta-v0.1.1"
    let (tags, _) = run("git tag", dir)
    check "alpha-v0.2.0" in tags
    check "beta-v0.1.1" in tags

  test "releasing one sibling keeps the other's entries in the shared changelog":
    let dir = freshSiblingWorkspaceRepo("siblings-sequential", sourceFiles = true)
    createDir(dir / "packages" / "both" / "alpha")
    createDir(dir / "packages" / "both" / "beta")
    discard commitFile(dir, "packages/both/alpha/a.nim", "echo 1\n", "feat: add alpha")
    check run("nimver bump alpha", dir).code == 0

    discard commitFile(dir, "packages/both/beta/b.nim", "echo 2\n", "fix: patch beta")
    check run("nimver bump beta", dir).code == 0

    # The second release prepends rather than replaces: both sections survive,
    # newest on top.
    let changelog = readFile(dir / "packages" / "both" / "CHANGELOG.md")
    check "## [alpha 0.2.0]" in changelog
    check "## [beta 0.1.1]" in changelog
    check changelog.find("## [beta") < changelog.find("## [alpha")
    check changelog.count("# Changelog") == 1

  test "a change beside sibling manifests follows sharedChanges":
    # Both manifests are equally near, so the file belongs to neither package
    # on its own and the policy decides - here `all`, so both release it.
    let dir = freshSiblingWorkspaceRepo("siblings-shared-note")
    discard
      commitFile(dir, "packages/both/notes.txt", "shared\n", "feat: shared change")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "Bumping alpha: 0.1.0 -> 0.2.0 (minor)" in output
    check "Bumping beta: 0.1.0 -> 0.2.0 (minor)" in output

    let changelog = readFile(dir / "packages" / "both" / "CHANGELOG.md")
    check "## [alpha 0.2.0]" in changelog
    check "## [beta 0.2.0]" in changelog
    check changelog.count("shared change") == 2

  test "sharedChanges = none drops a change beside sibling manifests":
    let dir = freshSiblingWorkspaceRepo("siblings-shared-none", sharedChanges = "none")
    discard
      commitFile(dir, "packages/both/notes.txt", "shared\n", "feat: shared change")
    check "Nothing to bump" in pending(dir)

    # A sibling's own manifest still belongs to it, whatever the policy.
    discard commitFile(
      dir, "packages/both/alpha.nimble", "version = \"0.1.0\"\n# alpha\n",
      "fix: annotate alpha",
    )
    let dryRun = pending(dir)
    check "Bumping alpha: 0.1.0 -> 0.1.1 (patch)" in dryRun
    check "Bumping beta" notin dryRun
    check "shared change" notin dryRun
