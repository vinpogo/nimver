## The manifest adapters: which manifest gets detected, and that a bump edits
## only the version, leaving the rest of the file untouched.

import std/[unittest, os, strutils, json]
import ./support

suite "manifest adapters":
  test "bump preserves Nimble manifest formatting":
    let dir = freshRepo("bump-nimble-format")
    let manifestPath = dir / "pkg.nimble"
    writeFile(
      manifestPath,
      "name = \"pkg\"\nversion       = '0.1.0' # release version\nauthor = \"Test\"\n",
    )
    discard run("git add pkg.nimble", dir)
    discard run("git commit -q --no-verify -m \"chore: format manifest\"", dir)
    discard commitFile(dir, "a.txt", "hi", "fix: patch")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "0.1.0 -> 0.1.1" in output
    check readFile(manifestPath) ==
      "name = \"pkg\"\nversion       = '0.1.1' # release version\nauthor = \"Test\"\n"

  test "bump updates a package.json manifest":
    let dir = freshPackageRepo("bump-package-json")
    discard commitFile(dir, "index.js", "export {}\n", "feat: add feature")

    let before = readFile(dir / "package.json")
    let (output, code) = run("nimver bump", dir)

    check code == 0
    check "0.1.0 -> 0.2.0" in output
    check "(package.json)" in output
    let package = parseJson(readFile(dir / "package.json"))
    check package["version"].getStr() == "0.2.0"
    check package["name"].getStr() == "pkg"
    check package["private"].getBool()
    check readFile(dir / "package.json") ==
      before.replace("\"version\": \"0.1.0\"", "\"version\": \"0.2.0\"")
    check readFile(dir / "pnpm-lock.yaml") == "lockfileVersion: '9.0'\n"

    let (changedFiles, _) = run("git show --pretty=format: --name-only HEAD", dir)
    check "package.json" in changedFiles
    check "pnpm-lock.yaml" notin changedFiles
    let (tags, _) = run("git tag", dir)
    check "v0.2.0" in tags

  test "bump detects package.json without a package-manager marker":
    let dir = freshPackageRepo("bump-package-json-no-marker")
    let packagePath = dir / "package.json"
    removeFile(dir / "pnpm-lock.yaml")
    discard run("git add pnpm-lock.yaml", dir)
    discard run(
      "git commit -q --no-verify -m \"chore: remove package manager lockfile\"", dir
    )
    discard commitFile(dir, "index.js", "export {}\n", "fix: patch")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "0.1.0 -> 0.1.1" in output
    check "\"version\": \"0.1.1\"" in readFile(packagePath)

  test "sibling manifests are versioned together, with a warning":
    # Nothing in the config says how two root manifests relate, so nimver
    # assumes they are one release unit rather than picking one silently.
    let dir = freshPackageRepo("sibling-manifests")
    writeFile(dir / "pkg.nimble", "version = \"0.1.0\"\n")
    discard commitFile(dir, "index.js", "export {}\n", "fix: patch")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "assuming strategy = fixed" in output
    check "pkg.nimble" in output
    check "package.json" in output

    # Both manifests move to the same next version.
    check "\"version\": \"0.1.1\"" in readFile(dir / "package.json")
    check "version = \"0.1.1\"" in readFile(dir / "pkg.nimble")
    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v0.1.1"

  test "declaring one manifest leaves its sibling alone, without renaming releases":
    # Declaring a package is how you exclude an unrelated manifest - here a
    # package.json that is only tooling. Doing so must not turn `v0.1.1` into
    # `root-v0.1.1`: there is still only one package.
    let dir = freshPackageRepo("declared-single-package")
    writeFile(dir / "pkg.nimble", "version = \"0.1.0\"\n")
    let configPath = dir / ".nimver" / "config.ini"
    writeFile(
      configPath, readFile(configPath) & "\n[package.root]\nmanifest = pkg.nimble\n"
    )
    discard commitFile(dir, "index.js", "export {}\n", "fix: patch")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "assuming strategy = fixed" notin output
    check "0.1.0 -> 0.1.1" in output

    check "version = \"0.1.1\"" in readFile(dir / "pkg.nimble")
    # The undeclared manifest is not versioned at all.
    check "\"version\": \"0.1.0\"" in readFile(dir / "package.json")

    let (subject, _) = run("git log -1 --pretty=%s", dir)
    check subject.strip() == "version: v0.1.1"
    let (tags, _) = run("git tag", dir)
    check tags.strip() == "v0.1.1"

  test "sibling manifests are released separately when the strategy is independent":
    # An explicit strategy is honoured rather than overridden, but detected
    # packages are named after their manifest paths - which is what the warning
    # nudges you to fix by declaring them.
    let dir = freshPackageRepo("sibling-manifests-independent")
    writeFile(dir / "pkg.nimble", "version = \"0.1.0\"\n")
    let configPath = dir / ".nimver" / "config.ini"
    writeFile(
      configPath, readFile(configPath) & "\n[workspace]\nstrategy = independent\n"
    )
    discard commitFile(dir, "index.js", "export {}\n", "fix: patch")

    let (output, code) = run("nimver bump", dir)
    check code == 0
    check "releasing them independently" in output
    check "assuming strategy = fixed" notin output

    # Each moves on its own, and both are named in the changelog they share,
    # since a bare version could not say which manifest it belongs to.
    check "\"version\": \"0.1.1\"" in readFile(dir / "package.json")
    check "version = \"0.1.1\"" in readFile(dir / "pkg.nimble")
    let changelog = readFile(dir / "CHANGELOG.md")
    check "## [package.json 0.1.1]" in changelog
    check "## [pkg.nimble 0.1.1]" in changelog
    check changelog.find("## [package.json") < changelog.find("## [pkg.nimble")
