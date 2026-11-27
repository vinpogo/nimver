## A package whose version is written in several manifests, and the TOML and
## JSON adapters such manifests need: `Cargo.toml`, a Zed `extension.toml`, a
## `tree-sitter.json`, and the ZON one for a Zig `build.zig.zon`.

import std/[unittest, os, strutils]
import results
import ./support
import config
import semver
import adapters/manifest

const CargoToml = """[package]
name = "cli"
version = "1.0.0"   # the crate's
edition = "2021"

[dependencies]
serde = { version = "1.0.0" }

[dependencies.other]
version = "1.0.0"
"""

const ExtensionToml = """id = "cli"
version = '1.0.0'
schema_version = 1

[grammars.cli]
rev = "abc"
"""

const TreeSitterJson = """{
  "grammars": [{ "name": "cli", "version": "9.9.9" }],
  "metadata": {
    "version": "1.0.0",
    "license": "MIT"
  }
}
"""

const BuildZigZon = """.{
    .name = .cli,
    // .version = "0.0.1", in a comment
    .fingerprint = 0xdc128957cfbdb44a,
    .minimum_zig_version = "0.14.0",
    .dependencies = .{
        .other = .{
            .version = "9.9.9",
            .url = "https://example.com/{.version = \"8.8.8\"}.tar.gz",
            .hash = "abc",
        },
    },
    .note =
        \\ .version = "7.7.7"
    ,
    .brace = '{',
    .version = "1.0.0",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
"""

proc scratch(name: string): string =
  result = TestRepoRoot / "manifest-adapters" / name
  createDir(result)

proc versionIn(path, contents: string): string =
  writeFile(path, contents)
  $readVersion(manifestAt(path)).value

proc written(path, contents: string): string =
  writeFile(path, contents)
  versionWritten(manifestAt(path), parseSemVer("1.1.0").value).value

suite "TOML manifests":
  test "the version under [package], not a dependency's":
    let path = scratch("cargo") / "Cargo.toml"
    check versionIn(path, CargoToml) == "1.0.0"
    check written(path, CargoToml) ==
      CargoToml.replace("version = \"1.0.0\"   #", "version = \"1.1.0\"   #")

  test "a top-level version, in single quotes":
    let path = scratch("extension") / "extension.toml"
    check versionIn(path, ExtensionToml) == "1.0.0"
    check written(path, ExtensionToml) == ExtensionToml.replace("'1.0.0'", "'1.1.0'")

  test "a file without one says where it looked":
    let path = scratch("none") / "Cargo.toml"
    writeFile(path, "[dependencies.other]\nversion = \"1.0.0\"\n")
    let version = readVersion(manifestAt(path))
    check version.isErr
    check "at the top or under [package]" in version.error

suite "JSON manifests":
  test "metadata.version, where tree-sitter.json keeps it":
    let path = scratch("tree-sitter") / "tree-sitter.json"
    check versionIn(path, TreeSitterJson) == "1.0.0"
    check written(path, TreeSitterJson) ==
      TreeSitterJson.replace("\"version\": \"1.0.0\"", "\"version\": \"1.1.0\"")

  test "a top-level version wins over metadata.version":
    let path = scratch("both") / "any.json"
    check versionIn(path, """{"metadata": {"version": "2.0.0"}, "version": "3.0.0"}""") ==
      "3.0.0"

  test "a file without one says where it looked":
    let path = scratch("json-none") / "any.json"
    writeFile(path, """{"name": "x"}""")
    let version = readVersion(manifestAt(path))
    check version.isErr
    check "at the top level or under 'metadata'" in version.error

suite "ZON manifests":
  test "the top-level .version, not a dependency's, a comment's or a string's":
    let path = scratch("zig") / "build.zig.zon"
    check versionIn(path, BuildZigZon) == "1.0.0"
    check written(path, BuildZigZon) ==
      BuildZigZon.replace(".version = \"1.0.0\"", ".version = \"1.1.0\"")

  test "strings, escapes, enum literals and comments do not stand in for it":
    let path = scratch("zig-lexing") / "build.zig.zon"
    let contents =
      ".{\n    .name = .version,\n    .a = \"x\\\" .version = \\\"9.9.9\",\n" &
      "    .b = '\\'', .c = '\"', .d = \"{\",\n    .versionx = \"8.8.8\",\n" &
      "    . version // the release\n    = // set by nimver\n    \"1.0.0\",\n}\n"
    check versionIn(path, contents) == "1.0.0"
    check written(path, contents) == contents.replace("\"1.0.0\"", "\"1.1.0\"")

  test "a quoted field name":
    let path = scratch("zig-quoted") / "build.zig.zon"
    let contents = ".{ .name = .cli, .@\"version\" = \"1.0.0\" }\n"
    check versionIn(path, contents) == "1.0.0"
    check written(path, contents) == contents.replace("1.0.0", "1.1.0")

  test "a file without one says where it looked":
    let path = scratch("zig-none") / "build.zig.zon"
    writeFile(path, ".{ .deps = .{ .version = \"1.0.0\" } }\n")
    let version = readVersion(manifestAt(path))
    check version.isErr
    check "Could not find a top-level '.version' field" in version.error

  test "a version that is not a string is refused":
    let path = scratch("zig-enum") / "build.zig.zon"
    writeFile(path, ".{ .version = .latest }\n")
    let version = readVersion(manifestAt(path))
    check version.isErr
    check "must be a quoted string" in version.error

proc withManifests(dir: string, files: openArray[(string, string)]): string =
  ## Writes `files` (repository-relative path, contents) and makes them cli's
  ## manifests after `cli.nimble`, committed outside the pending changes.
  var paths = @["packages/cli/cli.nimble"]
  for (path, contents) in files:
    createDir(parentDir(dir / path))
    writeFile(dir / path, contents)
    paths.add(path)
  let configPath = dir / ".nimver" / "config.ini"
  writeFile(
    configPath,
    readFile(configPath).replace(
      "manifest = packages/cli/cli.nimble\n",
      "manifest = \"" & paths.join(", ") & "\"\n",
    ),
  )
  discard run("git add -A", dir)
  let committed = run("git commit -q --no-verify -m \"chore: more manifests\"", dir)
  doAssert committed.code == 0, committed.output
  dir

suite "a package with several manifests":
  test "a release rewrites all of them, in its commit":
    let dir = withManifests(
      freshWorkspaceRepo("several-manifests", strategy = "independent"),
      [
        ("packages/cli/Cargo.toml", CargoToml),
        ("packages/cli/tree-sitter.json", TreeSitterJson),
      ],
    )
    discard commitFile(dir, "packages/cli/main.nim", "echo 1\n", "feat: add cli")

    let (output, code) = run("nimver bump cli", dir)
    check code == 0
    check "Bumping cli: 1.0.0 -> 1.1.0" in output
    check "(Cargo.toml)" in output
    check "(tree-sitter.json)" in output
    check manifestVersion(dir, "packages/cli/cli.nimble") == "1.1.0"
    check "version = \"1.1.0\"   #" in readFile(dir / "packages/cli/Cargo.toml")
    check "\"version\": \"1.1.0\"" in readFile(dir / "packages/cli/tree-sitter.json")
    check run("git status --porcelain", dir).output.strip() == ""
    let changed = run("git show --name-only --pretty= HEAD", dir).output
    check "packages/cli/Cargo.toml" in changed
    check "packages/cli/tree-sitter.json" in changed
    # The changelog stays next to the first manifest.
    check fileExists(dir / "packages/cli/CHANGELOG.md")

  test "another package's release leaves them alone":
    let dir = withManifests(
      freshWorkspaceRepo("several-manifests-other", strategy = "independent"),
      [("packages/cli/Cargo.toml", CargoToml)],
    )
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    check run("nimver bump web", dir).code == 0
    check readFile(dir / "packages/cli/Cargo.toml") == CargoToml

  test "manifests that disagree stop the release before anything is written":
    let dir = withManifests(
      freshWorkspaceRepo("several-manifests-disagree", strategy = "independent"),
      [("packages/cli/Cargo.toml", CargoToml.replace("\"1.0.0\"   #", "\"0.9.0\"   #"))],
    )
    discard commitFile(dir, "packages/cli/main.nim", "echo 1\n", "feat: add cli")
    for output in [pending(dir, "cli"), run("nimver bump cli", dir).output]:
      check "must have the same version" in output
    check manifestVersion(dir, "packages/cli/cli.nimble") == "1.0.0"
    check run("git status --porcelain", dir).output.strip() == ""

  test "a manifest outside the package's folder still belongs to it":
    let dir = withManifests(
      freshWorkspaceRepo(
        "several-manifests-elsewhere", strategy = "independent", sharedChanges = "none"
      ),
      [("editors/cli/extension.toml", ExtensionToml)],
    )
    writeFile(dir / "editors/cli/extension.toml", ExtensionToml & "# more\n")
    discard run("git commit -q -a -m \"fix: describe it\"", dir)
    check "Bumping cli: 1.0.0 -> 1.0.1" in pending(dir)

  test "a fixed workspace moves every package's manifests":
    let dir = withManifests(
      freshWorkspaceRepo("several-manifests-fixed"),
      [("packages/cli/Cargo.toml", CargoToml)],
    )
    discard commitFile(dir, "packages/web/index.js", "export {}\n", "feat: add web")
    check run("nimver bump", dir).code == 0
    check "version = \"1.1.0\"   #" in readFile(dir / "packages/cli/Cargo.toml")

suite "several manifests in the configuration":
  test "a quoted, comma-separated list":
    let parsed = parseConfig(
      "[package.zed]\nmanifest = \"zed/package.json, zed/Cargo.toml\"\n", "config.ini"
    ).value
    check parsed.packages[0].manifestPaths == @["zed/package.json", "zed/Cargo.toml"]

  test "an unquoted list is refused, saying to quote it":
    let parsed = parseConfig(
      "[package.zed]\nmanifest = zed/package.json, zed/Cargo.toml\n", "config.ini"
    )
    check parsed.isErr
    check "has to be quoted" in parsed.error

  test "a manifest of two packages is refused":
    let parsed = parseConfig(
      "[package.a]\nmanifest = \"a/a.nimble, VERSION.json\"\n" &
        "[package.b]\nmanifest = \"b/b.nimble, VERSION.json\"\n",
      "config.ini",
    )
    check parsed.isErr
    check "Duplicate package manifest 'VERSION.json'" in parsed.error

  test "a file of another format is refused when the release reads it":
    let dir = withManifests(
      freshWorkspaceRepo("several-manifests-format", strategy = "independent"),
      [("packages/cli/VERSION", "1.0.0\n")],
    )
    let output = pending(dir, "cli")
    check "A manifest is a .nimble, .json, .toml or .zon file" in output
