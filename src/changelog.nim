## Builds a `CHANGELOG.md` section and prepends it to the file.
##
## Hand-written `Release-Note:` footers lead, since they are the only part of a
## release anyone wrote for a reader. The commits themselves follow as one flat
## list: what a release contains, in the words its authors committed.

import std/[strutils, times, tables, sequtils]
import ./sysio
import ./changes
import ./semver

proc firstLine(message: string): string =
  let idx = message.find('\n')
  if idx == -1:
    message.strip()
  else:
    message[0 ..< idx].strip()

proc subjectOf(entry: ChangeEntry): string =
  ## The header line without its `type(scope)!: ` prefix.
  let line = firstLine(entry.message)
  let sepIdx = line.find(": ")
  if sepIdx != -1:
    line[sepIdx + 2 .. ^1].strip()
  else:
    line

proc breakingBullet(entry: ChangeEntry): string =
  ## What the break was, in the most deliberate wording the commit offers.
  if entry.breakingNote.len > 0:
    entry.breakingNote
  elif entry.releaseNote.len > 0:
    entry.releaseNote
  else:
    entry.subjectOf()

proc buildSection*(
    version: SemVer, entries: seq[ChangeEntry], packageName = ""
): string =
  ## `packageName` prefixes the version in the heading, for changelogs that
  ## several packages share and where the version alone would not say which
  ## package moved.
  let date = now().format("yyyy-MM-dd")
  let versionLabel =
    if packageName.len > 0:
      packageName & " " & $version
    else:
      $version
  var parts: seq[string] = @["## [" & versionLabel & "] - " & date]

  let breaking = entries.filterIt(it.breaking)
  if breaking.len > 0:
    parts.add("\n### Breaking Changes")
    for e in breaking:
      parts.add("- " & e.breakingBullet())

  # A break is already spoken for above; what is left is the notes, unscoped
  # ones leading and each scope gathering its own below.
  let noted = entries.filterIt(not it.breaking and it.releaseNote.len > 0)

  let unscoped = noted.filterIt(it.scope.len == 0)
  if unscoped.len > 0:
    parts.add("")
    for e in unscoped:
      parts.add("- " & e.releaseNote)

  var order: seq[string] = @[]
  var byScope = initTable[string, seq[ChangeEntry]]()
  for e in noted:
    if e.scope.len == 0:
      continue
    if not byScope.hasKey(e.scope):
      byScope[e.scope] = @[]
      order.add(e.scope)
    byScope[e.scope].add(e)

  for scope in order:
    parts.add("\n### " & scope)
    for e in byScope[scope]:
      parts.add("- " & e.releaseNote)

  if entries.len > 0:
    parts.add("\n### Commits")
    for e in entries:
      parts.add("- " & firstLine(e.message))

  parts.join("\n") & "\n"

proc prependToChangelog*(changelogPath: string, section: string) =
  const header = "# Changelog"
  if not fileAt(changelogPath):
    writeFileContents(changelogPath, header & "\n\n" & section)
    return

  let existing = readFileContents(changelogPath)
  if existing.startsWith(header):
    let idx = existing.find('\n')
    let rest =
      if idx == -1:
        ""
      else:
        existing[idx + 1 .. ^1].strip(leading = true, trailing = false)
    writeFileContents(changelogPath, header & "\n\n" & section & "\n" & rest)
  else:
    writeFileContents(changelogPath, header & "\n\n" & section & "\n" & existing)
