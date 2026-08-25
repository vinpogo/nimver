## Unit tests for rendering a `CHANGELOG.md` section: how entries are grouped,
## how a bullet is worded, and when a heading names its package.

import std/[unittest, strutils, times]
import changelog
import changes
import semver

proc entry(
    commitType, message: string, breaking = false, level = blPatch
): ChangeEntry =
  ChangeEntry(
    commitType: commitType, bumpLevel: level, breaking: breaking, message: message
  )

let today = now().format("yyyy-MM-dd")

suite "section heading":
  test "the heading carries the version and today's date":
    let section = buildSection(parseSemVer("1.2.0"), @[])
    check section == "## [1.2.0] - " & today & "\n"

  test "a package name prefixes the version":
    let section = buildSection(parseSemVer("0.2.0"), @[], packageName = "web")
    check section.startsWith("## [web 0.2.0] - " & today)

suite "grouping entries":
  test "entries are grouped under their type's label":
    let section = buildSection(
      parseSemVer("1.1.0"),
      @[
        entry("feat", "feat: add a thing", level = blMinor),
        entry("fix", "fix: mend a thing"),
      ],
    )
    check section ==
      [
        "## [1.1.0] - " & today, "", "### Features", "- add a thing", "", "### Fixes",
        "- mend a thing", "",
      ].join("\n")

  test "several entries of one type share its group":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[
        entry("fix", "fix: first"),
        entry("docs", "docs: unrelated", level = blNone),
        entry("fix", "fix: second"),
      ],
    )
    check section.count("### Fixes") == 1
    check "- first\n- second" in section

  test "types appear in the order they were first seen":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[entry("fix", "fix: mend"), entry("feat", "feat: add", level = blMinor)],
    )
    check section.find("### Fixes") < section.find("### Features")

  test "an unlabelled type falls back to Other Changes":
    let section = buildSection(parseSemVer("1.0.1"), @[entry("wip", "wip: halfway")])
    check "### Other Changes\n- halfway" in section

suite "breaking changes":
  test "breaking entries are called out first, before every type group":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[
        entry("fix", "fix: mend a thing"),
        entry("feat", "feat!: rework a thing", breaking = true, level = blMajor),
      ],
    )
    check section.find("### Breaking Changes") < section.find("### Fixes")
    check "### Breaking Changes\n- rework a thing" in section

  test "a breaking entry is not repeated in its type's group":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[entry("feat", "feat!: rework a thing", breaking = true, level = blMajor)],
    )
    check section.count("- rework a thing") == 1
    check "### Features" notin section

suite "bullet wording":
  test "the type, scope and breaking marker are dropped":
    let section =
      buildSection(parseSemVer("1.0.1"), @[entry("fix", "fix(parser)!: mend a thing")])
    check "- mend a thing" in section

  test "only the first line of the message is kept":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[
        entry(
          "fix",
          "fix: mend a thing\n\nThe body explains why.\n\nBREAKING CHANGE: nothing really",
        )
      ],
    )
    check "- mend a thing" in section
    check "body explains" notin section

  test "a subject containing a colon keeps it":
    let section =
      buildSection(parseSemVer("1.0.1"), @[entry("fix", "fix: mend: the parser")])
    check "- mend: the parser" in section

  test "a message without a header prefix is taken as written":
    let section = buildSection(parseSemVer("1.0.1"), @[entry("fix", "mend a thing")])
    check "- mend a thing" in section
