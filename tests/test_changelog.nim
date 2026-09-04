## Unit tests for rendering a `CHANGELOG.md` section: which groups appear and in
## what order, how a bullet is worded, and when a heading names its package.

import std/[unittest, strutils, times]
import changelog
import changes
import semver

proc entry(
    commitType, message: string,
    breaking = false,
    level = blPatch,
    releaseNote = "",
    breakingNote = "",
    scope = "",
): ChangeEntry =
  ChangeEntry(
    commitType: commitType,
    scope: scope,
    bumpLevel: level,
    breaking: breaking,
    message: message,
    releaseNote: releaseNote,
    breakingNote: breakingNote,
  )

let today = now().format("yyyy-MM-dd")

suite "section heading":
  test "the heading carries the version and today's date":
    let section = buildSection(parseSemVer("1.2.0"), @[])
    check section == "## [1.2.0] - " & today & "\n"

  test "a package name prefixes the version":
    let section = buildSection(parseSemVer("0.2.0"), @[], packageName = "web")
    check section.startsWith("## [web 0.2.0] - " & today)

suite "the commit list":
  test "a release without notes is a heading and its commits":
    let section = buildSection(
      parseSemVer("1.1.0"),
      @[
        entry("feat", "feat: add a thing", level = blMinor),
        entry("fix", "fix(parser): mend a thing"),
      ],
    )
    check section ==
      [
        "## [1.1.0] - " & today, "", "### Commits", "- feat: add a thing",
        "- fix(parser): mend a thing", "",
      ].join("\n")

  test "headers are listed verbatim, prefix and marker and all":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[
        entry("feat", "feat(parser)!: rework a thing", breaking = true, level = blMajor)
      ],
    )
    check "- feat(parser)!: rework a thing" in section

  test "commits are not grouped by type":
    let section = buildSection(
      parseSemVer("1.1.0"),
      @[
        entry("fix", "fix: first"),
        entry("feat", "feat: middle", level = blMinor),
        entry("fix", "fix: last"),
      ],
    )
    check section.count("### Commits") == 1
    check "- fix: first\n- feat: middle\n- fix: last" in section
    check "### Features" notin section
    check "### Fixes" notin section
    check "### Other Changes" notin section

  test "only the first line of a message is kept":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[entry("fix", "fix: mend a thing\n\nThe body explains why.")],
    )
    check "- fix: mend a thing" in section
    check "body explains" notin section

  test "a message without a header prefix is taken as written":
    let section = buildSection(parseSemVer("1.0.1"), @[entry("fix", "mend a thing")])
    check "- mend a thing" in section

suite "release notes":
  test "an unscoped note leads, as a bullet of its own":
    let section = buildSection(
      parseSemVer("1.1.0"),
      @[
        entry(
          "feat",
          "feat: widen the parser",
          level = blMinor,
          releaseNote = "Types now accept uppercase letters.",
        )
      ],
    )
    check section ==
      [
        "## [1.1.0] - " & today, "", "- Types now accept uppercase letters.", "",
        "### Commits", "- feat: widen the parser", "",
      ].join("\n")

  test "a scope gives the note a section of its own":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[
        entry(
          "fix",
          "fix(parser): tighten it",
          scope = "parser",
          releaseNote = "Scopes may now contain digits.",
        )
      ],
    )
    check "### parser\n- Scopes may now contain digits." in section

  test "notes sharing a scope share its section":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[
        entry("fix", "fix(parser): a", scope = "parser", releaseNote = "First."),
        entry("fix", "fix(cli): b", scope = "cli", releaseNote = "Unrelated."),
        entry("fix", "fix(parser): c", scope = "parser", releaseNote = "Second."),
      ],
    )
    check section.count("### parser") == 1
    check "### parser\n- First.\n- Second." in section

  test "scopes appear in the order they were first seen":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[
        entry("fix", "fix(cli): a", scope = "cli", releaseNote = "First."),
        entry("fix", "fix(parser): b", scope = "parser", releaseNote = "Second."),
      ],
    )
    check section.find("### cli") < section.find("### parser")

  test "the scope is rendered as it was written":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[entry("fix", "fix(net/http): a", scope = "net/http", releaseNote = "A note.")],
    )
    check "### net/http" in section

  test "unscoped notes lead, and scoped sections follow":
    let section = buildSection(
      parseSemVer("1.0.1"),
      @[
        entry("fix", "fix(cli): a", scope = "cli", releaseNote = "Scoped."),
        entry("fix", "fix: b", releaseNote = "Unscoped."),
      ],
    )
    check section.find("- Unscoped.") < section.find("### cli")

  test "a commit without a note contributes only to the commit list":
    let section = buildSection(
      parseSemVer("1.0.1"), @[entry("fix", "fix(parser): tighten it", scope = "parser")]
    )
    check "### parser" notin section
    check "- fix(parser): tighten it" in section

suite "breaking changes":
  test "breaking entries are called out above the notes":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[
        entry("fix", "fix: b", releaseNote = "A note."),
        entry(
          "feat",
          "feat!: rework a thing",
          breaking = true,
          level = blMajor,
          breakingNote = "The config key moved.",
        ),
      ],
    )
    check section.find("### Breaking Changes") < section.find("- A note.")
    check "### Breaking Changes\n- The config key moved." in section

  test "the breaking footer wins over the release note":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[
        entry(
          "feat",
          "feat!: a",
          breaking = true,
          level = blMajor,
          releaseNote = "The feature.",
          breakingNote = "The break.",
        )
      ],
    )
    check "- The break." in section
    check "- The feature." notin section

  test "a release note stands in when there is no breaking footer":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[
        entry(
          "feat",
          "feat!: a",
          breaking = true,
          level = blMajor,
          releaseNote = "Everything moved.",
        )
      ],
    )
    check "### Breaking Changes\n- Everything moved." in section

  test "a bare bang falls back to the subject":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[entry("feat", "feat(cli)!: rework a thing", breaking = true, level = blMajor)],
    )
    check "### Breaking Changes\n- rework a thing" in section

  test "a breaking entry is not repeated among the notes":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[
        entry(
          "feat",
          "feat(cli)!: a",
          breaking = true,
          level = blMajor,
          scope = "cli",
          releaseNote = "Everything moved.",
        )
      ],
    )
    check section.count("- Everything moved.") == 1
    check "### cli" notin section

  test "but it is still listed among the commits":
    let section = buildSection(
      parseSemVer("2.0.0"),
      @[entry("feat", "feat!: a", breaking = true, level = blMajor)],
    )
    check "### Commits\n- feat!: a" in section
