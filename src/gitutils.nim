import std/[osproc, options, strutils, sequtils, os, tables]

type CommitRecord* = object
  hash*: string
  message*: string
  changedPaths*: seq[string]

const
  RecordSeparator = "\x1e"
  FieldSeparator = "\x1f"

proc tryRunGit(args: seq[string]): tuple[output: string, exitCode: int] =
  execCmdEx("git " & args.map(quoteShell).join(" "))

proc runGit(args: seq[string]): string =
  let (output, code) = tryRunGit(args)
  if code != 0:
    raise newException(IOError, "git " & args.join(" ") & " failed: " & output.strip())
  output

proc findRepoRoot*(): string =
  runGit(@["rev-parse", "--show-toplevel"]).strip()

proc gitPath*(repoRoot: string, relative: string): string =
  let resolved = runGit(@["-C", repoRoot, "rev-parse", "--git-path", relative]).strip()
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

proc gitCommitsIn*(repoRoot: string, revisionRange: string): seq[CommitRecord] =
  runGit(
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
    .split(RecordSeparator)
    .filterIt(it.strip().len > 0)
    .mapIt(it.split(FieldSeparator))
    .filterIt(it.len >= 3)
    .mapIt(
      CommitRecord(
        hash: it[0].strip(),
        message: it[1].strip(),
        changedPaths: it[2].splitLines().mapIt(it.strip()).filterIt(it.len > 0),
      )
    )

func tagCommit(parts: seq[string]): string =
  if parts.len >= 3:
    parts[1]
  else:
    parts[0]

func groupByCommit(
    pairs: seq[tuple[commit: string, tagName: string]]
): Table[string, seq[string]] =
  for (commit, tagName) in pairs:
    result.mgetOrPut(commit, @[]).add(tagName)

proc gitTagsByCommit*(repoRoot: string): Table[string, seq[string]] =
  runGit(
    @[
      "-C", repoRoot, "for-each-ref",
      "--format=%(objectname) %(*objectname) %(refname:strip=2)", "refs/tags",
    ]
  )
    .splitLines()
    .filterIt(it.strip().len > 0)
    .mapIt(it.splitWhitespace())
    .filterIt(it.len >= 2)
    .mapIt((commit: tagCommit(it), tagName: it[^1]))
    .groupByCommit()

proc gitFileAtRevision*(repoRoot, revision, path: string): Option[string] =
  let (output, code) = tryRunGit(@["-C", repoRoot, "show", revision & ":" & path])
  if code != 0:
    return none(string)
  some(output)

proc gitRootEntryNames*(repoRoot, revision: string): seq[string] =
  runGit(@["-C", repoRoot, "ls-tree", "--name-only", revision & ":"])
    .splitLines()
    .filterIt(it.strip().len > 0)
    .mapIt(it.strip())
