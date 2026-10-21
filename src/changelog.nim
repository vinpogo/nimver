## Builds a `CHANGELOG.md` section and prepends it to the file.
##
## Hand-written `Release-Note:` footers lead, since they are the only part of a
## release anyone wrote for a reader. The commits themselves follow as one flat
## list: what a release contains, in the words its authors committed.

import std/[strutils, times, tables, sequtils, options]
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

func sectionLabel*(version: SemVer, packageName = ""): string =
  ## `packageName` prefixes the version, for changelogs that several packages
  ## share and where the version alone would not say which package moved.
  if packageName.len > 0:
    packageName & " " & $version
  else:
    $version

proc buildSection*(
    version: SemVer, entries: seq[ChangeEntry], packageName = ""
): string =
  let date = now().format("yyyy-MM-dd")
  var parts: seq[string] =
    @["## [" & sectionLabel(version, packageName) & "] - " & date]

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

func sectionBody*(changelog, label: string): Option[string] =
  ## The section under the `## [<label>]` heading, without the heading. The
  ## closing bracket is part of the match, so `1.2.0` does not find the
  ## section of `1.2.0-rc.1`, nor `1.2.0` that of `web 1.2.0`.
  let heading = "## [" & label & "]"
  var body: seq[string] = @[]
  var inSection = false
  for line in changelog.splitLines():
    if inSection:
      if line.startsWith("## "):
        break
      body.add(line)
    elif line.startsWith(heading):
      inSection = true
  if not inSection:
    return none(string)
  some(body.join("\n").strip())

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
