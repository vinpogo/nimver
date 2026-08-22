## Small wrappers around the `git` CLI. We shell out rather than link a Git
## library to keep the tool dependency-free.

import std/[osproc, strutils, sequtils, os, tables]

proc tryRunGit(args: seq[string]): tuple[output: string, exitCode: int] =
  execCmdEx("git " & args.map(quoteShell).join(" "))

proc runGit(args: seq[string]): string =
  let (output, code) = tryRunGit(args)
  if code != 0:
    raise newException(IOError, "git " & args.join(" ") & " failed: " & output.strip())
  output

proc findRepoRoot*(): string =
  ## Locates the root of the current Git working tree.
  runGit(@["rev-parse", "--show-toplevel"]).strip()

proc gitPath*(repoRoot: string, relative: string): string =
  ## Resolves `relative` inside the repository's Git directory.
  ##
  ## This is not the same as `repoRoot / ".git" / relative`: whenever the Git
  ## directory does not physically live at `<root>/.git`, Git writes a
  ## one-line `.git` *file* pointing at it instead. That is the case for
  ## linked worktrees (`git worktree add`), submodules, and checkouts made
  ## with `--separate-git-dir`. Asking Git also preserves its own split
  ## between paths shared by every worktree (`hooks`) and per-worktree ones
  ## (`rebase-merge`).
  let resolved = runGit(@["-C", repoRoot, "rev-parse", "--git-path", relative]).strip()
  # `--git-path` reports relative to Git's working directory, which `-C` has
  # already set to `repoRoot`.
  if isAbsolute(resolved):
    resolved
  else:
    repoRoot / resolved

proc gitAdd*(repoRoot: string, path: string) =
  discard runGit(@["-C", repoRoot, "add", "-A", "--", path])

proc gitCommit*(repoRoot: string, message: string) =
  discard runGit(@["-C", repoRoot, "commit", "-m", message])

proc gitTag*(repoRoot: string, tag: string) =
  discard runGit(@["-C", repoRoot, "tag", tag])

type CommitRecord* = object ## One commit as a release needs to read it.
  hash*: string
  message*: string ## Subject, body and footers, as committed.
  changedPaths*: seq[string]

const
  RecordSeparator = "\x1e"
  FieldSeparator = "\x1f"

proc gitCommitsIn*(repoRoot: string, revisionRange: string): seq[CommitRecord] =
  ## Every commit in `revisionRange`, newest first, with the paths it touched.
  ##
  ## Read in one go rather than a `git` call per commit: a release cycle can be
  ## hundreds of commits long, and the message and the file list are all that
  ## is wanted from each. Merges are left out - what they bring in is listed
  ## individually, and their own messages are not Conventional Commits.
  let output = runGit(
    @[
      "-C",
      repoRoot,
      "log",
      "--no-merges",
      "--name-only",
      "--format=" & RecordSeparator & "%H" & FieldSeparator & "%B" & FieldSeparator,
      revisionRange,
    ]
  )
  for rawRecord in output.split(RecordSeparator):
    if rawRecord.strip().len == 0:
      continue
    let fields = rawRecord.split(FieldSeparator)
    if fields.len < 3:
      continue
    var record = CommitRecord(hash: fields[0].strip(), message: fields[1].strip())
    for line in fields[2].splitLines():
      let path = line.strip()
      if path.len > 0:
        record.changedPaths.add(path)
    result.add(record)

proc gitTagsByCommit*(repoRoot: string): Table[string, seq[string]] =
  ## Tag names by the commit they mark. Annotated tags resolve through their
  ## tag object, so both kinds land on the commit a release would have tagged.
  let output = runGit(
    @[
      "-C", repoRoot, "for-each-ref",
      "--format=%(objectname) %(*objectname) %(refname:strip=2)", "refs/tags",
    ]
  )
  for line in output.splitLines():
    let fields = line.splitWhitespace()
    if fields.len < 2:
      continue
    # An annotated tag reports the commit it peels to in the second column; a
    # lightweight one leaves it empty, so the first column is already a commit.
    let commit =
      if fields.len >= 3:
        fields[1]
      else:
        fields[0]
    let tagName = fields[^1]
    result.mgetOrPut(commit, @[]).add(tagName)

proc gitFileAtRevision*(repoRoot, revision, path: string): string =
  ## The contents of a file as of a commit, or an empty string when the commit
  ## did not have it.
  let (output, code) = tryRunGit(@["-C", repoRoot, "show", revision & ":" & path])
  if code != 0:
    return ""
  output

proc gitRootEntryNames*(repoRoot, revision: string): seq[string] =
  ## Names of the entries in a commit's root directory.
  let output = runGit(@["-C", repoRoot, "ls-tree", "--name-only", revision & ":"])
  for line in output.splitLines():
    let name = line.strip()
    if name.len > 0:
      result.add(name)
