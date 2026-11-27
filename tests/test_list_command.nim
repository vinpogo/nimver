import std/[unittest, os, strutils]
import ./support

proc addCargoManifest(dir, version: string) =
  writeFile(
    dir / "packages" / "cli" / "Cargo.toml",
    "[package]\nname = \"cli\"\nversion = \"" & version & "\"\n",
  )
  let configPath = dir / ".nimver" / "config.ini"
  writeFile(
    configPath,
    readFile(configPath).replace(
      "manifest = packages/cli/cli.nimble",
      "manifest = \"packages/cli/cli.nimble, packages/cli/Cargo.toml\"",
    ),
  )

suite "list":
  test "a single package is listed with its version and manifest":
    let dir = freshRepo("list-single")
    check run("nimver list", dir) == ("pkg  1.0.0  pkg.nimble\n", 0)

  test "a workspace lists its packages in config order":
    let dir = freshWorkspaceRepo("list-workspace", strategy = "independent")
    check run("nimver list", dir) == (
      "web  1.0.0  packages/web/package.json\n" & "cli  1.0.0  packages/cli/cli.nimble\n",
      0,
    )

  test "a package's manifests are listed together":
    let dir = freshWorkspaceRepo("list-manifests", strategy = "independent")
    addCargoManifest(dir, "1.0.0")
    check run("nimver list", dir) == (
      "web  1.0.0  packages/web/package.json\n" &
        "cli  1.0.0  packages/cli/cli.nimble, packages/cli/Cargo.toml\n",
      0,
    )

  test "only a package on a track shows it":
    let dir = freshWorkspaceRepo("list-track", strategy = "independent")
    check setTrack(dir, "enter alpha --package web").code == 0
    check run("nimver list", dir) == (
      "web  1.0.0  packages/web/package.json  track 'alpha'\n" &
        "cli  1.0.0  packages/cli/cli.nimble\n",
      0,
    )

  test "manifests that disagree on the version are refused":
    let dir = freshWorkspaceRepo("list-mismatch", strategy = "independent")
    addCargoManifest(dir, "2.0.0")
    let (output, code) = run("nimver list", dir)
    check code != 0
    check "must have the same version" in output
    check "packages/web/package.json" notin output

  test "a repository without a config is refused":
    let dir = freshRepo("list-no-config")
    removeDir(dir / ".nimver")
    let (output, code) = run("nimver list", dir)
    check code != 0
    check "Run `nimver init` first" in output
