## nimver: semantic versioning for Nim projects, driven by
## Conventional Commits and wired into Git via a `commit-msg` hook.

import std/[os, strutils, sequtils, algorithm, tables]
import ./gitutils
import ./config
import ./commitparser
import ./changes
import ./nimblefile
import ./changelog
import ./hooks
import ./semver

const NimblePkgVersion {.strdefine.} = "unknown"

const Usage = """
nimver - semantic versioning from Conventional Commits

Usage:
  nimver init
  nimver install-hooks [--force]
  nimver bump [--no-commit] [--no-tag] [--dry-run]
  nimver version

Invoked by installed hooks (not usually run by hand):
  nimver check-commit-msg <path-to-message-file>
  nimver record-commit
"""

proc cmdVersion() =
  echo NimblePkgVersion

proc cmdInit(repoRoot: string) =
  createDir(changesDir(repoRoot))
  let cfgPath = configPath(repoRoot)
  if fileExists(cfgPath):
    echo "Config already exists at ", cfgPath
  else:
    writeFile(cfgPath, DefaultConfig)
    echo "Created ", cfgPath
  echo "Run `nimver install-hooks` to wire up the commit-msg hook."

proc cmdInstallHooks(repoRoot: string, force: bool) =
  let hooksDir = installHooks(repoRoot, force)
  echo "Installed commit-msg hook at ", hooksDir / "commit-msg"
  echo "Installed post-commit hook at ", hooksDir / "post-commit"

proc validateAndLookup(cfg: Config, parsed: ParsedCommit): (bool, string, BumpLevel) =
  ## Returns `(ok, errorMessage, bumpLevel)`.
  let (known, configuredLevel) = lookupType(cfg, parsed.commitType)
  if not known:
    let allowed = toSeq(cfg.types.keys).sorted().join(", ")
    return (
      false,
      "unknown commit type '" & parsed.commitType & "'. Allowed types: " & allowed,
      blNone,
    )
  let bumpLevel = if parsed.breaking: blMajor else: configuredLevel
  (true, "", bumpLevel)

proc cmdCheckCommitMsg(repoRoot: string, msgFilePath: string) =
  ## Runs as the `commit-msg` hook. Only validates; the commit's tree is
  ## already fixed by this point, so writing the bump-note file here would
  ## not end up in the commit being created (see `record-commit`).
  let raw = readFile(msgFilePath)
  let (ok, err, parsed) = parseCommitMessage(raw)
  if not ok:
    stderr.writeLine("nimver: invalid commit message: " & err)
    quit(1)

  let cfg = loadConfig(repoRoot)
  let (validType, typeErr, _) = validateAndLookup(cfg, parsed)
  if not validType:
    stderr.writeLine("nimver: " & typeErr)
    quit(1)

proc cmdRecordCommit(repoRoot: string) =
  ## Runs as the `post-commit` hook. Writes the bump-note file for the
  ## commit that was just created and folds it into that same commit via a
  ## guarded amend (see the `post-commit` hook script for the re-entrancy
  ## guard).
  if isRebaseInProgress(repoRoot):
    # Amending here would fight with the rebase sequencer's own bookkeeping
    # (see `isRebaseInProgress`). Leave existing notes untouched; review
    # `.nimver/changes` once the rebase completes if any
    # reworded commits should have their notes updated.
    stderr.writeLine(
      "nimver: skipping change-note recording during an in-progress rebase"
    )
    return

  let raw = gitLastCommitMessage(repoRoot)
  let (ok, err, parsed) = parseCommitMessage(raw)
  if not ok:
    stderr.writeLine("nimver: skipping unparseable commit: " & err)
    return

  let cfg = loadConfig(repoRoot)
  let (validType, typeErr, bumpLevel) = validateAndLookup(cfg, parsed)
  if not validType:
    stderr.writeLine("nimver: skipping commit: " & typeErr)
    return

  # If HEAD's own diff already contains a change-note file, this call is
  # amending a commit that was already recorded rather than a brand-new
  # commit - remove the stale note (whatever its previously recorded type
  # was) before writing a fresh one. Checking the commit's actual diff
  # (rather than tracking hashes) also means a reword that changes the
  # commit's type (e.g. `fix:` -> `feat:`) is handled correctly for free.
  var dirty = false
  for path in gitHeadChangedPaths(repoRoot):
    if path.startsWith(ChangesRelPrefix) and path.endsWith(".txt"):
      let full = repoRoot / path
      if fileExists(full):
        removeFile(full)
        dirty = true

  if bumpLevel != blIgnore:
    discard writeChangeFile(
      repoRoot, parsed.commitType, bumpLevel, parsed.breaking, parsed.rawMessage
    )
    dirty = true

  if not dirty:
    return

  gitAdd(repoRoot, changesDir(repoRoot))
  putEnv("NIMVER_AMENDING", "1")
  gitAmendNoVerify(repoRoot)

proc cmdBump(repoRoot: string, doCommit, doTag, dryRun: bool) =
  ## `doCommit`/`doTag` are true by default at the call site; `--no-commit`
  ## / `--no-tag` on the command line opt out of either one.
  let entries = readChangeFiles(repoRoot)
  if entries.len == 0:
    echo "No pending changes found in .nimver/changes. Nothing to bump."
    return

  var overall = blNone
  for e in entries:
    if e.bumpLevel > overall:
      overall = e.bumpLevel

  if overall == blNone:
    echo "All pending changes are non-version-impacting (bump=none). Nothing to bump."
    return

  let nimblePath = findNimbleFile(repoRoot)
  let current = readVersion(nimblePath)
  let next = bump(current, overall)
  let section = buildSection(next, entries)
  let changelogPath = repoRoot / "CHANGELOG.md"

  echo "Bumping version: ", $current, " -> ", $next, " (", $overall, ")"
  if dryRun:
    echo "\n--- CHANGELOG entry (dry run, nothing written) ---"
    echo section
    return

  writeVersion(nimblePath, next)
  prependToChangelog(changelogPath, section)
  deleteChangeFiles(entries)
  echo "Updated ", nimblePath
  echo "Updated ", changelogPath

  if doCommit:
    gitAdd(repoRoot, nimblePath)
    gitAdd(repoRoot, changelogPath)
    gitAdd(repoRoot, changesDir(repoRoot))
    gitCommit(repoRoot, "version: v" & $next)
    echo "Created release commit."

  if doTag:
    if not doCommit:
      # Without a release commit, HEAD is still whatever it was before this
      # run - tagging it as vX.Y.Z would mislabel an unrelated commit.
      echo "Skipped tag: no release commit was created (pass --no-tag along with --no-commit)."
    else:
      gitTag(repoRoot, "v" & $next)
      echo "Created tag v" & $next

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    echo Usage
    quit(1)

  if args[0] in ["version", "--version", "-v"]:
    cmdVersion()
    quit(0)

  var repoRoot: string
  try:
    repoRoot = findRepoRoot()
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)

  try:
    case args[0]
    of "init":
      cmdInit(repoRoot)
    of "install-hooks":
      cmdInstallHooks(repoRoot, "--force" in args)
    of "check-commit-msg":
      if args.len < 2:
        stderr.writeLine("Usage: nimver check-commit-msg <path-to-message-file>")
        quit(1)
      cmdCheckCommitMsg(repoRoot, args[1])
    of "record-commit":
      cmdRecordCommit(repoRoot)
    of "bump":
      cmdBump(
        repoRoot,
        not ("--no-commit" in args),
        not ("--no-tag" in args),
        "--dry-run" in args,
      )
    else:
      echo Usage
      quit(1)
  except IOError as e:
    stderr.writeLine("nimver: " & e.msg)
    quit(1)
