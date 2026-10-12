## Shared fixtures for the end-to-end tests. Every fixture spins up a throwaway
## Git repo so the tests drive real `git` + `nimver` invocations, exactly as a
## user would.
##
## The repos live in the system temp directory rather than inside the checkout:
## each fixture deletes and recreates its repo, and doing that hundreds of times
## inside a working tree fights with whatever watches it (editors, indexers), to
## the point where a deleted `.nimver/config.ini` can come back. Set
## `NIMVER_TEST_DIR` to override the location.

import std/[os, osproc, strtabs, strutils]

const ProjectRoot* = currentSourcePath().parentDir().parentDir()

let TestRepoRoot* =
  if existsEnv("NIMVER_TEST_DIR"):
    getEnv("NIMVER_TEST_DIR")
  else:
    getTempDir() / "nimver-tests"

proc testEnv(): StringTableRef =
  ## The freshly built binary lives at the project root; prepend it to PATH
  ## so the installed Git hooks (`exec nimver ...`) resolve to
  ## it instead of whatever else might be installed on the system.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result["PATH"] = ProjectRoot & ":" & result.getOrDefault("PATH", "")

proc resetDir(dir: string) =
  ## Removing a tree can transiently fail with "Directory not empty" while
  ## something else still holds entries inside it (a file watcher, an indexer,
  ## an editor). Retry rather than leave a half-deleted repo behind: a stale
  ## `.git` or `.nimver` would make the test that follows fail in a way that
  ## looks like a nimver bug.
  for attempt in 1 .. 10:
    try:
      removeDir(dir)
    except OSError:
      discard
    if not dirExists(dir):
      return
    sleep(25)
  removeDir(dir) # out of retries: surface the real error

proc run*(cmd: string, dir: string): tuple[output: string, code: int] =
  let r = execCmdEx(cmd, workingDir = dir, env = testEnv())
  (r.output, r.exitCode)

proc pending*(dir: string, arguments = ""): string =
  ## What a release would do right now. With nothing recorded anywhere, a dry
  ## run is how a test asks which changes the history is understood to hold.
  run("nimver bump --dry-run " & arguments, dir).output

proc editorScript(name, sedProgram: string): string =
  ## A one-line `sed` editor for git to call. Kept outside the repo under test
  ## so these scripts do not turn up as untracked files in its `git status`.
  result = TestRepoRoot / name & ".sh"
  writeFile(result, "#!/bin/sh\nsed -i '" & sedProgram & "' \"$1\"\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc rebaseInteractive*(
    dir, base, todoEdit: string, messageEdit = ""
): tuple[output: string, code: int] =
  ## Drives `git rebase -i` without an interactive editor: `todoEdit` is a `sed`
  ## program applied to the todo list (turning a `pick` into a `reword`, say),
  ## and `messageEdit` one applied to each message the rebase stops to edit.
  let name = dir.lastPathPart
  var command = "GIT_SEQUENCE_EDITOR=" & editorScript(name & "-todo", todoEdit)
  if messageEdit.len > 0:
    command.add(" GIT_EDITOR=" & editorScript(name & "-message", messageEdit))
  run(command & " git rebase -i " & base, dir)

proc initGitRepo(dir: string) =
  let commandResult = run("git init -q", dir)
  doAssert commandResult.code == 0, "git init failed: " & commandResult.output
  discard run("git config user.email test@example.com", dir)
  discard run("git config user.name Test", dir)

proc initNimver(dir: string) =
  var commandResult = run("nimver init", dir)
  doAssert commandResult.code == 0, "init failed: " & commandResult.output
  commandResult = run("nimver install-hooks", dir)
  doAssert commandResult.code == 0, "install-hooks failed: " & commandResult.output

proc tagBaseline(dir, version: string) =
  ## The version the manifest is already on, written as a tag - the whole of
  ## what a repository adopting nimver has to do before its first bump, without
  ## which `bump` refuses rather than counting a history that version already
  ## accounts for.
  ##
  ## A flat `v` tag is what every naming recognises - a namespaced package finds
  ## it through its legacy prefix - so this one bounds every package a fixture
  ## declares, and any a test declares later.
  let commandResult = run("git tag v" & version, dir)
  doAssert commandResult.code == 0, "baseline tag failed: " & commandResult.output

proc commitAll(dir, message: string) =
  discard run("git add -A", dir)
  let commandResult = run("git commit -q -m \"" & message & "\"", dir)
  doAssert commandResult.code == 0, "commit failed: " & commandResult.output

proc freshRepo*(name: string, version = "1.0.0"): string =
  ## A repo with one commit and an initial `pkg.nimble` at `version`, tagged
  ## `v<version>`, with nimver initialized and its hooks installed. The tag is
  ## the release its history is measured from, without which `bump` refuses.
  ##
  ## Stable by default, so a bump lands on the level its commits ask for. A
  ## fixture below 1.0.0 would hold every one of them a notch down, and the
  ## suites that are about something else - attribution, changelogs, manifest
  ## formats - would quietly stop telling a minor from a major. The suites that
  ## *are* about the holding pass their own 0.x version in.
  result = TestRepoRoot / name
  resetDir(result)
  createDir(result)

  initGitRepo(result)
  writeFile(result / "pkg.nimble", "version = \"" & version & "\"\n")
  commitAll(result, "chore: init")
  tagBaseline(result, version)
  initNimver(result)

proc freshPackageRepo*(name: string, version = "1.0.0"): string =
  ## A package.json repo with one commit and an initial version at `version`.
  result = TestRepoRoot / name
  resetDir(result)
  createDir(result)

  initGitRepo(result)
  writeFile(
    result / "package.json",
    """{
  "name": "pkg",
  "version": "$1",
  "private": true
}
""" % [version],
  )
  writeFile(result / "pnpm-lock.yaml", "lockfileVersion: '9.0'\n")
  commitAll(result, "chore: init")
  tagBaseline(result, version)
  initNimver(result)

proc freshWorkspaceRepo*(
    name: string,
    sharedChanges = "all",
    includeRootPackage = false,
    strategy = "fixed",
    namePrefix = "",
    version = "1.0.0",
): string =
  ## A workspace with package.json and Nimble packages at `version`.
  ## With `includeRootPackage`, a repository-root Nimble package is added too,
  ## which acts as an ancestor of the nested packages. An empty `strategy`
  ## leaves the setting out of the config entirely, exercising the default.
  ##
  ## `namePrefix` goes in front of every declared package name - `@acme/` makes
  ## the workspace a scoped one. The directories keep their plain names, so
  ## attribution is the same workspace either way.
  result = TestRepoRoot / name
  resetDir(result)
  createDir(result / "packages" / "web")
  createDir(result / "packages" / "cli")

  initGitRepo(result)
  writeFile(
    result / "packages" / "web" / "package.json",
    """{
  "name": "web",
  "version": "$1"
}
""" % [version],
  )
  writeFile(
    result / "packages" / "cli" / "cli.nimble", "version = \"" & version & "\"\n"
  )
  if includeRootPackage:
    writeFile(result / "root.nimble", "version = \"" & version & "\"\n")
  commitAll(result, "chore: init")
  tagBaseline(result, version)

  var commandResult = run("nimver init", result)
  doAssert commandResult.code == 0, "init failed: " & commandResult.output

  let configPath = result / ".nimver" / "config.ini"
  # `nimver init` keeps an existing config, so appending to a leftover one would
  # duplicate the package sections and fail confusingly. Checked per line: the
  # default config documents these sections in comments.
  for line in readFile(configPath).splitLines():
    doAssert not (line.startsWith("[workspace]") or line.startsWith("[package.")),
      "stale config survived the reset: " & configPath
  # Built with explicit newlines: a newline directly after `"""` would be
  # swallowed by Nim, which silently joins interpolated ini lines.
  let workspaceConfig =
    "\n[workspace]\n" & (if strategy.len > 0: "strategy = " & strategy & "\n"
    else: "") & "sharedChanges = " & sharedChanges & "\n" & "\n[package." & namePrefix &
    "web]\nmanifest = packages/web/package.json\n" & "\n[package." & namePrefix &
    "cli]\nmanifest = packages/cli/cli.nimble\n" & (
      if includeRootPackage:
        "\n[package." & namePrefix & "root]\nmanifest = root.nimble\n"
      else:
        ""
    )
  writeFile(configPath, readFile(configPath) & workspaceConfig)

  # `--no-verify` keeps the config commit itself out of the pending changes.
  discard run("git add -A", result)
  commandResult =
    run("git commit -q --no-verify -m \"chore: configure workspace\"", result)
  doAssert commandResult.code == 0, "config commit failed: " & commandResult.output

  commandResult = run("nimver install-hooks", result)
  doAssert commandResult.code == 0, "install-hooks failed: " & commandResult.output

proc freshSiblingWorkspaceRepo*(
    name: string, sharedChanges = "all", sourceFiles = false, version = "1.0.0"
): string =
  ## Two Nimble manifests in one directory - `packages/both/alpha.nimble` and
  ## `packages/both/beta.nimble`, both at 0.1.0 - released independently. They
  ## share `packages/both/CHANGELOG.md`, which is what makes this the fixture
  ## for per-package changelog headings.
  ##
  ## `beta` is declared first on purpose: a release has to come out
  ## alphabetical whatever order the config lists. With `sourceFiles` each
  ## package claims its own subdirectory, the only way a file next to the two
  ## manifests can be attributed to one of them.
  result = TestRepoRoot / name
  resetDir(result)
  createDir(result / "packages" / "both")

  initGitRepo(result)
  writeFile(
    result / "packages" / "both" / "alpha.nimble", "version = \"" & version & "\"\n"
  )
  writeFile(
    result / "packages" / "both" / "beta.nimble", "version = \"" & version & "\"\n"
  )
  commitAll(result, "chore: init")
  tagBaseline(result, version)

  var commandResult = run("nimver init", result)
  doAssert commandResult.code == 0, "init failed: " & commandResult.output

  let configPath = result / ".nimver" / "config.ini"
  proc packageSection(packageName: string): string =
    "\n[package." & packageName & "]\nmanifest = packages/both/" & packageName &
      ".nimble\n" & (
      if sourceFiles:
        "sourceFiles = \"packages/both/" & packageName & "/**\"\n"
      else:
        ""
    )

  writeFile(
    configPath,
    readFile(configPath) & "\n[workspace]\nstrategy = independent\n" & "sharedChanges = " &
      sharedChanges & "\n" & packageSection("beta") & packageSection("alpha"),
  )

  discard run("git add -A", result)
  commandResult =
    run("git commit -q --no-verify -m \"chore: configure workspace\"", result)
  doAssert commandResult.code == 0, "config commit failed: " & commandResult.output

  commandResult = run("nimver install-hooks", result)
  doAssert commandResult.code == 0, "install-hooks failed: " & commandResult.output

proc commitFile*(
    dir, fileName, contents, message: string
): tuple[output: string, code: int] =
  writeFile(dir / fileName, contents)
  discard run("git add -A", dir)
  run("git commit -q -m \"" & message & "\"", dir)

proc mustRun(cmd, dir: string) =
  let commandResult = run(cmd, dir)
  doAssert commandResult.code == 0, cmd & " failed: " & commandResult.output

proc subtreeMirroredRepo*(name: string): string =
  ## `app`, whose `docs/` is mirrored to a repository of its own with `git
  ## subtree`, right after a `git subtree pull` - so a commit from the docs
  ## repository is the newest non-merge commit, and the history holds the
  ## subtree's copies of `feat: initial` and `feat: add b together with docs`.
  ## Released as v1.0.0 at `feat: initial`.
  ##
  ## The sleeps keep commit dates apart, which is what the walk orders by.
  let base = TestRepoRoot / name
  resetDir(base)
  result = base / "app"
  createDir(result / "docs")
  let docsRemote = base / "docs.git"
  let docsClone = base / "docs"
  mustRun("git init -q --bare -b main " & docsRemote, base)

  initGitRepo(result)
  writeFile(result / "app.nimble", "version = \"1.0.0\"\n")
  writeFile(result / "docs" / "a.md", "a\n")
  initNimver(result)
  commitAll(result, "feat: initial")
  tagBaseline(result, "1.0.0")
  mustRun(
    "git subtree split -q --prefix=docs --rejoin -m \"chore: rejoin docs\" -b split",
    result,
  )
  mustRun("git push -q " & docsRemote & " split:main", result)

  sleep(1100)
  writeFile(result / "docs" / "b.md", "b\n")
  commitAll(result, "feat: add b together with docs")
  mustRun("git subtree push -q --prefix=docs " & docsRemote & " main", result)

  mustRun("git clone -q " & docsRemote & " " & docsClone, base)
  initGitRepo(docsClone)
  sleep(1100)
  writeFile(docsClone / "c.md", "c\n")
  commitAll(docsClone, "external edit")
  mustRun("git push -q", docsClone)

  mustRun(
    "git subtree pull -q --prefix=docs " & docsRemote & " main -m \"docs: pull docs\"",
    result,
  )

proc foreignHistory*(name, fileName, message: string): string =
  ## A repository sharing no history with the project: one commit, adding
  ## `fileName` at its root, and no manifest.
  result = TestRepoRoot / name
  resetDir(result)
  createDir(result)
  initGitRepo(result)
  writeFile(result / fileName, "foreign\n")
  commitAll(result, message)

proc mergeUnrelated*(dir, otherRepo: string) =
  mustRun("git fetch -q " & otherRepo & " HEAD", dir)
  mustRun(
    "git merge -q --no-ff --allow-unrelated-histories -m \"chore: merge it in\" FETCH_HEAD",
    dir,
  )

proc freshReleasedRepo*(name: string, version = "1.0.0"): string =
  ## `freshRepo` with one release on top of the baseline, so the repository
  ## carries both tags. Nearly every track test needs one: a prerelease is
  ## measured from a release, and a repository without one is refused.
  result = freshRepo(name, version)
  discard commitFile(result, "released.txt", "hi", "feat: the released one")
  let commandResult = run("nimver bump", result)
  doAssert commandResult.code == 0, "first release failed: " & commandResult.output

proc setTrack*(dir, subcommand: string): tuple[output: string, code: int] =
  run("nimver track " & subcommand, dir)

proc tags*(dir: string): seq[string] =
  for line in run("git tag", dir).output.splitLines():
    if line.strip().len > 0:
      result.add(line.strip())

proc manifestVersion*(dir, manifestRelativePath: string): string =
  ## The version a manifest carries, however it spells the field.
  for line in readFile(dir / manifestRelativePath).splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("version"):
      let parts = trimmed.split('"')
      if parts.len >= 2:
        return parts[1]
      let jsonParts = trimmed.split(':')
      if jsonParts.len >= 2:
        return jsonParts[1].strip().strip(chars = {'"', ','})
  ""
