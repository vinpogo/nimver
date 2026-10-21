import std/[unittest, os, strutils]
import ./support

suite "changelog":
  test "prints a released version's entry without its heading":
    let dir = freshRepo("changelog-single")
    discard commitFile(dir, "a.txt", "hi", "feat: add a\n\nRelease-Note: A is here.")
    check run("nimver bump", dir).code == 0

    let (output, code) = run("nimver changelog 1.1.0", dir)
    check code == 0
    check output == "- A is here.\n\n### Commits\n- feat: add a\n"

  test "accepts the version as its tag spells it":
    let dir = freshRepo("changelog-v-prefix")
    discard commitFile(dir, "a.txt", "hi", "feat: add a")
    check run("nimver bump", dir).code == 0
    check run("nimver changelog v1.1.0", dir) == run("nimver changelog 1.1.0", dir)

  test "finds an older entry below newer ones":
    let dir = freshRepo("changelog-older")
    discard commitFile(dir, "a.txt", "hi", "feat: add a")
    check run("nimver bump", dir).code == 0
    discard commitFile(dir, "b.txt", "hi", "fix: mend b")
    check run("nimver bump", dir).code == 0

    let (output, code) = run("nimver changelog 1.1.0", dir)
    check code == 0
    check output == "### Commits\n- feat: add a\n"

  test "a prerelease is found by its full version":
    let dir = freshReleasedRepo("changelog-prerelease")
    check setTrack(dir, "enter rc").code == 0
    discard run("git add -A", dir)
    discard run("git commit -q -m \"chore: enter rc\"", dir)
    discard commitFile(dir, "b.txt", "hi", "feat: add b")
    check run("nimver bump", dir).code == 0

    let (output, code) = run("nimver changelog 1.2.0-rc.1", dir)
    check code == 0
    check "- feat: add b" in output
    check "the released one" notin output

  test "a version with no entry is refused":
    let dir = freshReleasedRepo("changelog-missing")
    let (output, code) = run("nimver changelog 9.9.9", dir)
    check code != 0
    check "no entry for 9.9.9 in CHANGELOG.md" in output

  test "a version nimver could not have released is refused":
    let dir = freshReleasedRepo("changelog-not-a-version")
    for argument in ["foo", "1.2", "1.1.0-beta", "1.1.0+build"]:
      let (output, code) = run("nimver changelog " & argument, dir)
      check code != 0
      check ("'" & argument & "' is not a version") in output

  test "a repository that never released has no changelog to read":
    let dir = freshRepo("changelog-no-file")
    let (output, code) = run("nimver changelog 1.0.0", dir)
    check code != 0
    check "no changelog at CHANGELOG.md" in output

  test "a shared changelog is read for the named package only":
    let dir = freshSiblingWorkspaceRepo("changelog-siblings", sourceFiles = true)
    createDir(dir / "packages" / "both" / "alpha")
    createDir(dir / "packages" / "both" / "beta")
    discard commitFile(dir, "packages/both/alpha/a.nim", "echo 1\n", "feat: add alpha")
    discard commitFile(dir, "packages/both/beta/b.nim", "echo 2\n", "fix: patch beta")
    check run("nimver bump", dir).code == 0

    let (alpha, alphaCode) = run("nimver changelog alpha 1.1.0", dir)
    check alphaCode == 0
    check alpha == "### Commits\n- chore: configure workspace\n- feat: add alpha\n"

    let (beta, betaCode) = run("nimver changelog beta 1.0.1", dir)
    check betaCode == 0
    check beta == "### Commits\n- chore: configure workspace\n- fix: patch beta\n"

    let (output, code) = run("nimver changelog beta 1.1.0", dir)
    check code != 0
    check "no entry for beta 1.1.0 in packages/both/CHANGELOG.md" in output

  test "an independent workspace needs the package named":
    let dir = freshSiblingWorkspaceRepo("changelog-siblings-unnamed")
    let (output, code) = run("nimver changelog 1.0.0", dir)
    check code != 0
    check "alpha" in output and "beta" in output

  test "an unknown package is refused":
    let dir = freshSiblingWorkspaceRepo("changelog-siblings-unknown")
    let (output, code) = run("nimver changelog gamma 1.0.0", dir)
    check code != 0
    check "Unknown package 'gamma'" in output

  test "a package with a changelog of its own is read from beside its manifest":
    let dir = freshWorkspaceRepo("changelog-independent", strategy = "independent")
    discard commitFile(dir, "packages/web/a.ts", "x\n", "feat: add web")
    discard commitFile(dir, "packages/cli/a.nim", "echo 1\n", "fix: mend cli")
    check run("nimver bump", dir).code == 0

    let (web, webCode) = run("nimver changelog web 1.1.0", dir)
    check webCode == 0
    check web == "### Commits\n- chore: configure workspace\n- feat: add web\n"

    let (cli, cliCode) = run("nimver changelog cli 1.0.1", dir)
    check cliCode == 0
    check cli == "### Commits\n- chore: configure workspace\n- fix: mend cli\n"

  test "a fixed workspace has one changelog and refuses a package":
    let dir = freshWorkspaceRepo("changelog-fixed")
    discard commitFile(dir, "packages/web/a.ts", "x\n", "feat: add web")
    check run("nimver bump", dir).code == 0

    let (output, code) = run("nimver changelog 1.1.0", dir)
    check code == 0
    check output == "### Commits\n- chore: configure workspace\n- feat: add web\n"

    let (refused, refusedCode) = run("nimver changelog web 1.1.0", dir)
    check refusedCode != 0
    check "strategy is 'fixed'" in refused

  test "arguments it cannot read are refused":
    let dir = freshReleasedRepo("changelog-arguments")
    for arguments in ["", "a b c", "--dry-run 1.1.0"]:
      let (output, code) = run("nimver changelog " & arguments, dir)
      check code != 0
      check "nimver:" in output
