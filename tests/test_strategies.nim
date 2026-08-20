## Releasing a configured workspace: `fixed` moves every package together,
## `independent` (the default) releases one named package at a time.

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
    check changeNotes(dir).len == 0

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
    check changeNotes(dir).len == 0

  test "independent bump consumes a shared note one package at a time":
    let dir = freshWorkspaceRepo("independent-shared", strategy = "independent")
    discard commitFile(dir, "README.md", "# Workspace\n", "feat: shared change")
    var notes = changeNotes(dir)
    require notes.len == 1
    check "packages=web,cli" in readFile(notes[0])

    # Releasing `web` leaves the note pending for `cli` only.
    var (output, code) = run("nimver bump web", dir)
    check code == 0
    check "0.1.0 -> 0.2.0" in output
    notes = changeNotes(dir)
    require notes.len == 1
    check "packages=cli" in readFile(notes[0])
    check "feat: shared change" in readFile(notes[0])

    # Releasing `cli` consumes the last package, so the note is removed.
    (output, code) = run("nimver bump cli", dir)
    check code == 0
    check "0.1.0 -> 0.2.0" in output
    check changeNotes(dir).len == 0

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

  test "independent bump requires a package name":
    let dir = freshWorkspaceRepo("independent-no-package", strategy = "independent")
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")

    let (output, code) = run("nimver bump", dir)
    check code != 0
    check "needs a package to release" in output
    check "web" in output
    check "\"version\": \"0.1.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )

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

    # A bare bump cannot pick between packages...
    var (output, code) = run("nimver bump", dir)
    check code != 0
    check "needs a package to release" in output

    # ...and releasing one leaves the other alone, rather than moving both.
    (output, code) = run("nimver bump web", dir)
    check code == 0
    check "Bumping web: 0.1.0 -> 0.2.0" in output
    check "\"version\": \"0.2.0\"" in readFile(
      dir / "packages" / "web" / "package.json"
    )
    check "version = \"0.1.0\"" in readFile(dir / "packages" / "cli" / "cli.nimble")
    let (tags, _) = run("git tag", dir)
    check "web-v0.2.0" in tags

  test "independent bump treats a pre-workspace note as affecting every package":
    let dir = freshWorkspaceRepo("independent-legacy-note", strategy = "independent")
    # A note in the pre-workspace format: no `packages=` line at all.
    writeFile(
      dir / ".nimver" / "changes" / "1700000000000-aaaaaa.txt",
      "type=feat\nbump=minor\nbreaking=false\n===\nfeat: recorded by an older nimver\n",
    )

    let (output, code) = run("nimver bump web --no-commit --no-tag", dir)
    check code == 0
    check "Bumping web: 0.1.0 -> 0.2.0" in output

    let notes = changeNotes(dir)
    require notes.len == 1
    check "packages=cli" in readFile(notes[0])
