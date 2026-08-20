## Reads and writes the per-commit "pending version bump" files stored under
## `.nimver/changes/`.

import std/[os, strutils, times, random, sequtils, algorithm]
import ./semver

type ChangeEntry* = object
  commitType*: string
  bumpLevel*: BumpLevel
  breaking*: bool
  affectedPackages*: seq[string]
  message*: string
  path*: string

const ChangesRelPrefix* = ".nimver/changes/"
  ## Repo-relative (POSIX-style, matching `git diff-tree` output) path
  ## prefix for change-note files.

proc changesDir*(repoRoot: string): string =
  repoRoot / ".nimver" / "changes"

proc randomSlug(): string =
  ## A timestamp prefix keeps files sorted chronologically; the random
  ## suffix avoids collisions between commits made in the same millisecond.
  let millis = int64(epochTime() * 1000)
  let suffix = toHex(rand(0 .. 0xFFFFFF), 6).toLowerAscii()
  $millis & "-" & suffix

proc renderChangeFile(
    commitType: string,
    bumpLevel: BumpLevel,
    breaking: bool,
    affectedPackages: seq[string],
    message: string,
): string =
  "type=" & commitType & "\n" & "bump=" & $bumpLevel & "\n" & "breaking=" &
    (if breaking: "true" else: "false") & "\n" & "packages=" & affectedPackages.join(
    ","
  ) & "\n" & "===\n" & message & "\n"

proc writeChangeFile*(
    repoRoot, commitType: string,
    bumpLevel: BumpLevel,
    breaking: bool,
    affectedPackages: seq[string],
    message: string,
): string =
  randomize()
  let dir = changesDir(repoRoot)
  createDir(dir)
  let path = dir / (randomSlug() & ".txt")
  writeFile(
    path, renderChangeFile(commitType, bumpLevel, breaking, affectedPackages, message)
  )
  path

proc parseChangeFile(path: string): ChangeEntry =
  let content = readFile(path)
  const separator = "===\n"
  let sepIdx = content.find(separator)
  if sepIdx == -1:
    raise
      newException(IOError, "Malformed change file (missing '===' separator): " & path)

  let header = content[0 ..< sepIdx]
  let message =
    content[sepIdx + separator.len .. ^1].strip(leading = false, trailing = true)

  var commitType = ""
  var bumpLevel = blNone
  var breaking = false
  var affectedPackages: seq[string] = @[]
  for line in header.splitLines():
    if line.len == 0:
      continue
    let kv = line.split('=', 1)
    if kv.len != 2:
      continue
    case kv[0]
    of "type":
      commitType = kv[1]
    of "bump":
      bumpLevel = parseBumpLevel(kv[1])
    of "breaking":
      breaking = kv[1] == "true"
    of "packages":
      affectedPackages = kv[1].split(',').mapIt(it.strip()).filterIt(it.len > 0)
    else:
      discard

  ChangeEntry(
    commitType: commitType,
    bumpLevel: bumpLevel,
    breaking: breaking,
    affectedPackages: affectedPackages,
    message: message,
    path: path,
  )

proc readChangeFiles*(repoRoot: string): seq[ChangeEntry] =
  let dir = changesDir(repoRoot)
  if not dirExists(dir):
    return @[]
  var files: seq[string] = @[]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".txt"):
      files.add(path)
  files.sort() # filenames are timestamp-prefixed, so this is chronological order.
  files.mapIt(parseChangeFile(it))

proc deleteChangeFiles*(entries: seq[ChangeEntry]) =
  for entry in entries:
    removeFile(entry.path)

proc rewriteAffectedPackages*(entry: ChangeEntry, remainingPackages: seq[string]) =
  ## Releasing one package consumes the note for that package only: the note is
  ## rewritten with whichever packages still have it pending, and removed once
  ## none are left.
  if remainingPackages.len == 0:
    removeFile(entry.path)
  else:
    writeFile(
      entry.path,
      renderChangeFile(
        entry.commitType, entry.bumpLevel, entry.breaking, remainingPackages,
        entry.message,
      ),
    )
