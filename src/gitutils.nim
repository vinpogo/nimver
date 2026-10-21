import std/[options, strutils, sequtils, tables]
import ./sysio
import results

type CommitRecord* = object
  hash*: string
  parentHash*: string ## Empty for a root commit; merges are never read.
  message*: string
  changedPaths*: seq[string]

const
  RecordSeparator = "\x1e"
  FieldSeparator = "\x1f"

proc tryRunGit(args: seq[string]): Result[CommandResult, string] =
  runCommand("git", args)

proc runGit*(args: seq[string]): Result[string, string] =
  let (output, code) = ?tryRunGit(args)
  if code != 0:
    return err("git " & args.join(" ") & " failed: " & output.strip())
  ok(output)

proc findRepoRoot*(): Result[string, string] =
  ok((?runGit(@["rev-parse", "--show-toplevel"])).strip())

proc gitPath*(repoRoot: string, relative: string): Result[string, string] =
  let resolved =
    (?runGit(@["-C", repoRoot, "rev-parse", "--git-path", relative])).strip()
  if isAbsolute(resolved):
    ok(resolved)
  else:
    ok(repoRoot / resolved)

proc gitCommitsIn*(
    repoRoot: string, revisionRange: string
): Result[seq[CommitRecord], string] =
  let log = ?runGit(
    @[
      "-C",
      repoRoot,
      "log",
      "--no-merges",
      "--name-only",
      "--format=" & RecordSeparator & "%H" & FieldSeparator & "%P" & FieldSeparator &
        "%B" & FieldSeparator,
      revisionRange,
    ]
  )
  ok(
    log
      .split(RecordSeparator)
      .filterIt(it.strip().len > 0)
      .mapIt(it.split(FieldSeparator))
      .filterIt(it.len >= 4)
      .mapIt(
        CommitRecord(
          hash: it[0].strip(),
          parentHash: it[1].strip(),
          message: it[2].strip(),
          changedPaths: it[3].splitLines().mapIt(it.strip()).filterIt(it.len > 0),
        )
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

proc gitTagsByCommit*(repoRoot: string): Result[Table[string, seq[string]], string] =
  let refs = ?runGit(
    @[
      "-C", repoRoot, "for-each-ref",
      "--format=%(objectname) %(*objectname) %(refname:strip=2)", "refs/tags",
    ]
  )
  ok(
    refs
      .splitLines()
      .filterIt(it.strip().len > 0)
      .mapIt(it.splitWhitespace())
      .filterIt(it.len >= 2)
      .mapIt((commit: tagCommit(it), tagName: it[^1]))
      .groupByCommit()
  )

proc gitFileAtRevision*(
    repoRoot, revision, path: string
): Result[Option[string], string] =
  let (output, code) = ?tryRunGit(@["-C", repoRoot, "show", revision & ":" & path])
  if code != 0:
    return ok(none(string))
  ok(some(output))

func listedNames(listing: string): seq[string] =
  listing.splitLines().filterIt(it.strip().len > 0).mapIt(it.strip())

proc gitRootEntryNames*(repoRoot, revision: string): Result[seq[string], string] =
  ok(listedNames(?runGit(@["-C", repoRoot, "ls-tree", "--name-only", revision & ":"])))

proc gitPathsAtRevision*(
    repoRoot, revision: string, paths: seq[string]
): Result[seq[string], string] =
  ## Those of `paths` that exist in the revision's tree.
  ok(
    listedNames(
      ?runGit(@["-C", repoRoot, "ls-tree", "--name-only", revision, "--"] & paths)
    )
  )

proc tagExists*(repoRoot: string, tag: string): Result[bool, string] =
  ## Asked before a release writes anything: `git tag` refusing a name it
  ## already knows would otherwise fail after the manifests had moved.
  let lookup = ?tryRunGit(
    @["-C", repoRoot, "rev-parse", "--verify", "--quiet", "refs/tags/" & tag]
  )
  ok(lookup.exitCode == 0)
