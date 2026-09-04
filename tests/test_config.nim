## Unit tests for reading `.nimver/config.ini`: what a configuration says about
## types, workspace strategy and packages, and which malformed ones it refuses
## rather than quietly reading as something else.

import std/[unittest, options, tables]
import config
import commitparser
import semver

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

  test "a package section with no keys at all is dropped by the ini parser":
    check parseConfig("[package.web]\n", "config.ini").packages.len == 0

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
