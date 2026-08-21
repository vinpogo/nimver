## Builds a `CHANGELOG.md` section (grouped by Conventional Commit type,
## with breaking changes called out separately) and prepends it to the file.

import std/[os, strutils, times, tables, sequtils]
import ./changes
import ./semver

const TypeLabels = {
  "feat": "Features",
  "fix": "Fixes",
  "perf": "Performance",
  "refactor": "Refactoring",
  "revert": "Reverts",
  "docs": "Documentation",
  "style": "Styling",
  "test": "Tests",
  "build": "Build System",
  "ci": "Continuous Integration",
  "chore": "Chores",
}.toTable

proc labelFor(commitType: string): string =
  TypeLabels.getOrDefault(commitType, "Other Changes")

proc firstLine(message: string): string =
  let idx = message.find('\n')
  if idx == -1:
    message.strip()
  else:
    message[0 ..< idx].strip()

proc bulletFor(entry: ChangeEntry): string =
  ## Renders the commit's subject line only, dropping the `type(scope)!: `
  ## header prefix so the changelog reads like prose.
  let line = firstLine(entry.message)
  let sepIdx = line.find(": ")
  let subject =
    if sepIdx != -1:
      line[sepIdx + 2 .. ^1].strip()
    else:
      line
  "- " & subject

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
      parts.add(bulletFor(e))

  # Group the remaining, non-breaking entries by type, preserving first-seen
  # order of the types themselves.
  var order: seq[string] = @[]
  var byType = initTable[string, seq[ChangeEntry]]()
  for e in entries:
    if e.breaking:
      continue
    if not byType.hasKey(e.commitType):
      byType[e.commitType] = @[]
      order.add(e.commitType)
    byType[e.commitType].add(e)

  for t in order:
    parts.add("\n### " & labelFor(t))
    for e in byType[t]:
      parts.add(bulletFor(e))

  parts.join("\n") & "\n"

proc prependToChangelog*(changelogPath: string, section: string) =
  const header = "# Changelog"
  if not fileExists(changelogPath):
    writeFile(changelogPath, header & "\n\n" & section)
    return

  let existing = readFile(changelogPath)
  if existing.startsWith(header):
    let idx = existing.find('\n')
    let rest =
      if idx == -1:
        ""
      else:
        existing[idx + 1 .. ^1].strip(leading = true, trailing = false)
    writeFile(changelogPath, header & "\n\n" & section & "\n" & rest)
  else:
    writeFile(changelogPath, header & "\n\n" & section & "\n" & existing)
