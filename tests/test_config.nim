## Unit tests for reading `.nimver/config.ini`: what a configuration says about
## types, workspace strategy and packages, and which malformed ones it refuses
## rather than quietly reading as something else.

import std/[unittest, options, strutils, tables, os]
import config
import commitparser
import semver
import ./support

suite "types":
  test "each type maps to its bump level":
    let parsed = parseConfig(
      """
[types]
feat = minor
fix = patch
chore = none
wip = ignore
""", "config.ini",
    )
    check parsed.types["feat"] == blMinor
    check parsed.types["fix"] == blPatch
    check parsed.types["chore"] == blNone
    check parsed.types["wip"] == blIgnore

  test "type names are lowercased":
    let parsed = parseConfig("[types]\nFeat = minor\n", "config.ini")
    check parsed.types["feat"] == blMinor

  test "a missing types section maps nothing":
    check parseConfig("", "config.ini").types.len == 0

  test "an unknown bump level is rejected":
    expect ValueError:
      discard parseConfig("[types]\nfeat = huge\n", "config.ini")

  test "the shipped default config maps the documented types":
    let parsed = parseConfig(DefaultConfig, "config.ini")
    check parsed.types["feat"] == blMinor
    check parsed.types["fix"] == blPatch
    check parsed.types["docs"] == blNone
    check parsed.types["version"] == blIgnore
    check parsed.workspaceStrategy == wsIndependent
    check parsed.strategyWasSpecified == false
    check parsed.packages.len == 0

suite "unknown types":
  test "rejecting them is the default, and what `reject` spells out":
    check parseConfig("[types]\nfeat = minor\n", "config.ini").unknownType.isNone
    check parseConfig("[commits]\nunknownType = reject\n", "config.ini").unknownType.isNone
    check parseConfig(DefaultConfig, "config.ini").unknownType.isNone

  test "a bump level accepts them at that level":
    check parseConfig("[commits]\nunknownType = patch\n", "config.ini").unknownType ==
      some(blPatch)
    check parseConfig("[commits]\nunknownType = ignore\n", "config.ini").unknownType ==
      some(blIgnore)

  test "anything else is rejected":
    expect ValueError:
      discard parseConfig("[commits]\nunknownType = bogus\n", "config.ini")

  test "a listed type still wins over the fallback":
    let config = parseConfig(
      "[types]\nfeat = minor\n[commits]\nunknownType = patch\n", "config.ini"
    )
    check config.validateAndLookup(parseCommitMessage("feat: a").value) == some(blMinor)
    check config.validateAndLookup(parseCommitMessage("net/http: a").value) ==
      some(blPatch)

  test "a breaking unknown type is still a major bump":
    let config = parseConfig("[commits]\nunknownType = patch\n", "config.ini")
    check config.validateAndLookup(parseCommitMessage("net/http!: a").value) ==
      some(blMajor)

  test "without the fallback an unknown type resolves to nothing":
    let config = parseConfig("[types]\nfeat = minor\n", "config.ini")
    check config.validateAndLookup(parseCommitMessage("net/http: a").value).isNone

suite "workspace strategy":
  test "fixed and independent are both accepted":
    check parseConfig("[workspace]\nstrategy = fixed\n", "config.ini").workspaceStrategy ==
      wsFixed
    check parseConfig("[workspace]\nstrategy = independent\n", "config.ini").workspaceStrategy ==
      wsIndependent

  test "a named strategy is recorded as specified":
    check parseConfig("[workspace]\nstrategy = fixed\n", "config.ini").strategyWasSpecified

  test "an empty strategy reads as unspecified rather than invalid":
    let parsed = parseConfig("[workspace]\nstrategy =\n", "config.ini")
    check parsed.workspaceStrategy == wsIndependent
    check parsed.strategyWasSpecified == false

  test "a missing workspace section leaves the strategy unspecified":
    let parsed = parseConfig("[types]\nfeat = minor\n", "config.ini")
    check parsed.workspaceStrategy == wsIndependent
    check parsed.strategyWasSpecified == false

  test "an unknown strategy is rejected":
    expect ValueError:
      discard parseConfig("[workspace]\nstrategy = pinned\n", "config.ini")

suite "shared changes":
  test "changes outside every package are shared by default":
    check parseConfig("", "config.ini").sharedChanges == scAll

  test "sharedChanges can be turned off":
    check parseConfig("[workspace]\nsharedChanges = none\n", "config.ini").sharedChanges ==
      scNone

  test "an unknown sharedChanges kind is rejected":
    expect ValueError:
      discard parseConfig("[workspace]\nsharedChanges = some\n", "config.ini")

suite "packages":
  test "a package section names a package and its manifest":
    let parsed = parseConfig(
      """
[package.web]
manifest = packages/web/package.json

[package.cli]
manifest = packages/cli/cli.nimble
""",
      "config.ini",
    )
    check parsed.packages.len == 2
    check parsed.packages[0].name == "web"
    check parsed.packages[0].manifestPath == "packages/web/package.json"
    check parsed.packages[0].sourceFilePatterns.isNone
    check parsed.packages[1].name == "cli"
    check parsed.packages[1].manifestPath == "packages/cli/cli.nimble"

  test "a scoped npm name needs no quoting, the way it is written in package.json":
    let parsed = parseConfig(
      """
[package.@acme/widgets]
manifest = packages/widgets/package.json
""",
      "config.ini",
    )
    check parsed.packages.len == 1
    check parsed.packages[0].name == "@acme/widgets"
    check parsed.packages[0].manifestPath == "packages/widgets/package.json"

  test "a scoped section does not swallow the rest of the file":
    # `loadConfig` answers a parse error by dropping everything after it, so a
    # header it cannot lex used to cost the whole configuration, silently.
    let parsed = parseConfig(
      """
[package.@acme/widgets]
manifest = packages/widgets/package.json

[package.cli]
manifest = packages/cli/cli.nimble

[types]
feat = minor
""",
      "config.ini",
    )
    check parsed.packages.len == 2
    check parsed.packages[1].name == "cli"
    check parsed.types["feat"] == blMinor

  test "a quoted section header still names the same package":
    let parsed = parseConfig(
      "[\"package.@acme/widgets\"]\nmanifest = packages/widgets/package.json\n",
      "config.ini",
    )
    check parsed.packages.len == 1
    check parsed.packages[0].name == "@acme/widgets"

  test "a commented-out scoped section stays a comment":
    check parseConfig(
      "; [package.@acme/widgets]\n; manifest = packages/widgets/package.json\n",
      "config.ini",
    ).packages.len == 0

  test "a comment after a scoped header is not read as part of the name":
    let parsed = parseConfig(
      "[package.@acme/widgets] ; the one with the buttons\nmanifest = packages/widgets/package.json\n",
      "config.ini",
    )
    check parsed.packages.len == 1
    check parsed.packages[0].name == "@acme/widgets"

  test "an unquoted glob is still rejected inside a scoped section":
    expect IOError:
      discard parseConfig(
        "[package.@acme/widgets]\nmanifest = packages/widgets/package.json\nsourceFiles = packages/widgets/**\n",
        "config.ini",
      )

  test "sourceFiles is a comma-separated list of patterns":
    let parsed = parseConfig(
      """
[package.web]
manifest = packages/web/package.json
sourceFiles = "packages/web/**, docs/**"
""",
      "config.ini",
    )
    check parsed.packages[0].sourceFilePatterns == some(@["packages/web/**", "docs/**"])

  test "an empty sourceFiles leaves attribution to nearest ancestor":
    let parsed = parseConfig(
      "[package.web]\nmanifest = packages/web/package.json\nsourceFiles =\n",
      "config.ini",
    )
    check parsed.packages[0].sourceFilePatterns.isNone

  test "an unquoted glob is rejected, since ini would truncate it at the star":
    expect IOError:
      discard parseConfig(
        "[package.web]\nmanifest = packages/web/package.json\nsourceFiles = packages/web/**\n",
        "config.ini",
      )

  test "a package without a manifest is rejected":
    expect IOError:
      discard
        parseConfig("[package.web]\nsourceFiles = \"packages/web/**\"\n", "config.ini")

  test "a misspelled manifest key is rejected rather than read as none":
    expect IOError:
      discard parseConfig(
        "[package.web]\nmanifests = packages/web/package.json\n", "config.ini"
      )

  test "a package section with no keys at all is a package missing its manifest":
    # Not "a package nobody declared": the section is there to be read.
    expect IOError:
      discard parseConfig("[package.web]\n", "config.ini")

  test "the same package section twice is merged, the last manifest winning":
    let parsed = parseConfig(
      """
[package.web]
manifest = packages/web/package.json

[package.web]
manifest = packages/other/package.json
""",
      "config.ini",
    )
    check parsed.packages.len == 1
    check parsed.packages[0].manifestPath == "packages/other/package.json"

  test "sections differing only in the case of the package prefix are rejected":
    expect IOError:
      discard parseConfig(
        """
[package.web]
manifest = packages/web/package.json

[Package.web]
manifest = packages/other/package.json
""",
        "config.ini",
      )

  test "two packages sharing a manifest are rejected":
    expect IOError:
      discard parseConfig(
        """
[package.web]
manifest = packages/web/package.json

[package.cli]
manifest = packages/web/package.json
""",
        "config.ini",
      )

suite "looking up a commit's level":
  let parsed = parseConfig("[types]\nfeat = minor\nchore = none\n", "config.ini")

  test "a mapped type yields its level":
    check parsed.validateAndLookup(ParsedCommit(commitType: "feat")) == some(blMinor)

  test "the lookup is case-insensitive":
    check parsed.validateAndLookup(ParsedCommit(commitType: "FEAT")) == some(blMinor)

  test "an unmapped type yields nothing":
    check parsed.validateAndLookup(ParsedCommit(commitType: "style")).isNone

  test "breaking overrides the type's level":
    check parsed.validateAndLookup(ParsedCommit(commitType: "chore", breaking: true)) ==
      some(blMajor)

  test "breaking does not rescue an unmapped type":
    check parsed.validateAndLookup(ParsedCommit(commitType: "style", breaking: true)).isNone

suite "package names":
  ## A name is released as a tag and names itself in the release commit, so one
  ## that neither can spell is refused where it is written rather than halfway
  ## through a release.

  proc parsePackage(packageName: string): NimverConfig =
    parseConfig(
      "[package." & packageName & "]\nmanifest = packages/a/package.json\n",
      "config.ini",
    )

  test "a name a tag and a commit can both spell is accepted":
    for packageName in [
      "@acme/widgets", "web", "package.json", "cli.nimble", "root", "web,cli"
    ]:
      check parsePackage(packageName).packages[0].name == packageName

  test "a character neither a tag nor a commit scope allows is rejected":
    for packageName in ["my package", "web*", "we~b", "web:cli", "web(cli)", "web\\cli"]:
      expect IOError:
        discard parsePackage(packageName)

  test "a name git would refuse as a ref is rejected":
    for packageName in [
      "a..b", "@acme//widgets", "/widgets", "widgets/", ".hidden", "a/.b", "a.lock/b"
    ]:
      expect IOError:
        discard parsePackage(packageName)

  test "a name git tag would read as an option is rejected":
    expect IOError:
      discard parsePackage("-widgets")

  test "a bare at sign is rejected":
    expect IOError:
      discard parsePackage("@")

  test "a half-quoted header is a name with quotes in it, and is rejected":
    expect IOError:
      discard parseConfig(
        "[package.\"@acme/widgets\"]\nmanifest = packages/a/package.json\n",
        "config.ini",
      )

suite "configurations that say nothing nimver can act on":
  ## A mistake in a config file is otherwise a silence rather than an error, and
  ## a workspace that lost its packages reads exactly like one that never
  ## declared any - which releases the wrong thing instead of saying so.

  test "an unknown section is rejected, with the nearest known one named":
    let message = (
      try:
        discard parseConfig("[packages.web]\nmanifest = a/package.json\n", "config.ini")
        ""
      except IOError as failure:
        failure.msg
    )
    check "Unknown section [packages.web]" in message
    check "did you mean [package.web]?" in message

  test "a section nothing resembles lists what there is":
    let message = (
      try:
        discard parseConfig("[notes]\nfoo = bar\n", "config.ini")
        ""
      except IOError as failure:
        failure.msg
    )
    check "Unknown section [notes]" in message
    check "[package.<name>]" in message

  test "a section spelled in the wrong case is rejected rather than ignored":
    for section in ["[Workspace]\nstrategy = fixed\n", "[Types]\nfeat = minor\n"]:
      expect IOError:
        discard parseConfig(section, "config.ini")

  test "an unknown setting is rejected, with the nearest known one named":
    let message = (
      try:
        discard parseConfig(
          "[package.web]\nmanifest = a/package.json\nsourceFile = \"a/**\"\n",
          "config.ini",
        )
        ""
      except IOError as failure:
        failure.msg
    )
    check "Unknown setting 'sourceFile'" in message
    check "did you mean 'sourceFiles'?" in message

  test "a commit type is any word, so [types] takes any setting":
    check parseConfig("[types]\nwhatever = patch\n", "config.ini").types.len == 1

  test "a setting written before any section is rejected":
    expect IOError:
      discard parseConfig("strategy = fixed\n\n[types]\nfeat = minor\n", "config.ini")

  test "a line that does not parse is an error, not a shorter file":
    # parsecfg answers a malformed line by dropping the rest of the file.
    let message = (
      try:
        discard parseConfig(
          "[types]\nfeat = minor\n\n[workspace\nstrategy = fixed\n", "config.ini"
        )
        ""
      except IOError as failure:
        failure.msg
    )
    check "Could not read config.ini" in message

suite "section headers written loosely":
  ## Whitespace and quoting around a header are the ini file's business, not the
  ## package name's - and a header that is misread costs a whole package.

  test "padding inside the brackets is not part of the name":
    for header in [
      "[package.web]", "[package.web ]", "[ package.web]", "[\"package.web\"]",
      "[\"package.web\" ]", "[ \"package.web\"]",
    ]:
      let parsed =
        parseConfig(header & "\nmanifest = packages/web/package.json\n", "config.ini")
      check parsed.packages.len == 1
      check parsed.packages[0].name == "web"

  test "padding around a scoped name is not part of the name either":
    for header in [
      "[package.@acme/web]", "[package.@acme/web ]", "[ package.@acme/web]",
      "[\"package.@acme/web\"]", "[ \"package.@acme/web\" ]",
    ]:
      let parsed =
        parseConfig(header & "\nmanifest = packages/web/package.json\n", "config.ini")
      check parsed.packages.len == 1
      check parsed.packages[0].name == "@acme/web"

  test "an indented section is still a section":
    let parsed = parseConfig(
      "  [package.@acme/web]\n  manifest = packages/web/package.json\n", "config.ini"
    )
    check parsed.packages.len == 1
    check parsed.packages[0].name == "@acme/web"

suite "the track file sits beside the configuration without disturbing it":
  test "a .nimver/track next to config.ini is not the configuration's business":
    let dir = freshRepo("config-with-a-track-file")
    check run("nimver track enter alpha", dir).code == 0
    check run("nimver bump --dry-run", dir).code == 0

  test "[track] is still an unknown section":
    # The track lives in a file of its own, so nothing should start suggesting
    # it as a configuration section.
    let dir = freshRepo("config-track-section")
    let configFile = dir / ".nimver" / "config.ini"
    writeFile(configFile, readFile(configFile) & "\n[track]\nname = alpha\n")
    let (output, code) = run("nimver bump --dry-run", dir)
    check code != 0
    check "Unknown section [track]" in output
