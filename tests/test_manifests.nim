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

    let (output, code) = run("nimver bump --no-tag", dir)
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

    let (output, code) = run("nimver bump --no-tag", dir)
    check code == 0
    check "0.1.0 -> 0.1.1" in output
    check "\"version\": \"0.1.1\"" in readFile(packagePath)

  test "bump rejects an ambiguous Nimble and package.json repository":
    let dir = freshPackageRepo("bump-ambiguous")
    writeFile(dir / "pkg.nimble", "version = \"0.1.0\"\n")
    discard commitFile(dir, "index.js", "export {}\n", "fix: patch")

    let (output, code) = run("nimver bump --no-commit --no-tag", dir)
    check code != 0
    check "Both Nimble and package.json manifests were found" in output
    check "\"version\": \"0.1.0\"" in readFile(dir / "package.json")
    check "version = \"0.1.0\"" in readFile(dir / "pkg.nimble")
