import std/[unittest, options, strutils]
import workspace
import config
import adapters/manifest

proc rootDirectoryOf(manifestRelativePath: string): string =
  let lastSeparatorIndex = manifestRelativePath.rfind('/')
  if lastSeparatorIndex == -1:
    ""
  else:
    manifestRelativePath[0 ..< lastSeparatorIndex]

proc package(
    name, manifestRelativePath: string, sourceFiles = none[seq[string]]()
): WorkspacePackage =
  WorkspacePackage(
    name: name,
    manifest: manifestAt(manifestRelativePath),
    manifestRelativePath: manifestRelativePath,
    rootDirectory: rootDirectoryOf(manifestRelativePath),
    sourceFilePatterns: sourceFiles,
  )

proc workspaceOf(packages: seq[WorkspacePackage], sharedChanges = scAll): Workspace =
  Workspace(strategy: wsIndependent, sharedChanges: sharedChanges, packages: packages)

suite "glob matching":
  test "a pattern without wildcards has to match exactly":
    check globMatches("src/main.nim", "src/main.nim")
    check not globMatches("src/main.nim", "src/main.nims")
    check not globMatches("src/main.nim", "other/main.nim")

  test "a single star stops at a path separator":
    check globMatches("src/*.nim", "src/main.nim")
    check not globMatches("src/*.nim", "src/inner/main.nim")

  test "a double star crosses path separators":
    check globMatches("src/**", "src/main.nim")
    check globMatches("src/**", "src/inner/deeper/main.nim")

  test "a double star also matches nothing at all":
    check globMatches("src/**", "src/")
    check not globMatches("src/**", "src")

  test "a question mark matches one character but not a separator":
    check globMatches("src/mai?.nim", "src/main.nim")
    check not globMatches("src/mai??.nim", "src/main.nim")
    check not globMatches("src?main.nim", "src/main.nim")

  test "a pattern can end in a wildcard mid-name":
    check globMatches("packages/web-*/index.js", "packages/web-ui/index.js")
    check not globMatches("packages/web-*/index.js", "packages/cli/index.js")

  test "a leading ./ is ignored on either side":
    check globMatches("./src/**", "src/main.nim")
    check globMatches("src/**", "./src/main.nim")

  test "backslashes are read as path separators":
    check globMatches("src/**", "src\\main.nim")
    check not globMatches("src/*.nim", "src\\inner\\main.nim")

suite "attributing a changed file":
  let packages = @[
    package("web", "packages/web/package.json"),
    package("cli", "packages/cli/cli.nimble"),
  ]

  test "a file inside a package belongs to it alone":
    check workspaceOf(packages).affectedPackageNames(@["packages/web/index.js"]) ==
      @["web"]

  test "a package's own manifest belongs to it":
    check workspaceOf(packages).affectedPackageNames(@["packages/cli/cli.nimble"]) ==
      @["cli"]

  test "one commit can touch several packages":
    check workspaceOf(packages).affectedPackageNames(
      @["packages/web/index.js", "packages/cli/src/main.nim"]
    ) == @["web", "cli"]

  test "packages are reported in workspace order, not in the order touched":
    check workspaceOf(packages).affectedPackageNames(
      @["packages/cli/src/main.nim", "packages/web/index.js"]
    ) == @["web", "cli"]

  test "a package touched twice is reported once":
    check workspaceOf(packages).affectedPackageNames(
      @["packages/web/index.js", "packages/web/README.md"]
    ) == @["web"]

  test "no changed files affect nothing":
    check workspaceOf(packages).affectedPackageNames(@[]).len == 0

suite "files no package claims":
  let packages = @[
    package("web", "packages/web/package.json"),
    package("cli", "packages/cli/cli.nimble"),
  ]

  test "sharedChanges = all hands the file to every package":
    check workspaceOf(packages).affectedPackageNames(@["README.md"]) == @["web", "cli"]

  test "sharedChanges = none drops the file":
    check workspaceOf(packages, sharedChanges = scNone)
      .affectedPackageNames(@["README.md"]).len == 0

  test "the old per-change bookkeeping directory is skipped rather than shared":
    check workspaceOf(packages)
      .affectedPackageNames(@[".nimver/changes/abc123.txt"]).len == 0

  test "the config itself is a shared change":
    check workspaceOf(packages).affectedPackageNames(@[".nimver/config.ini"]) ==
      @["web", "cli"]

  test "packages sharing a directory tie for nearest, so sharedChanges decides":
    let siblings = @[package("web", "package.json"), package("cli", "cli.nimble")]
    check siblings.workspaceOf().affectedPackageNames(@["src/main.nim"]) ==
      @["web", "cli"]
    check siblings
      .workspaceOf(sharedChanges = scNone)
      .affectedPackageNames(@["src/main.nim"]).len == 0

  test "a sibling's own manifest still belongs to it":
    let siblings = @[package("web", "package.json"), package("cli", "cli.nimble")]
    check siblings.workspaceOf().affectedPackageNames(@["cli.nimble"]) == @["cli"]

suite "nested packages":
  let packages =
    @[package("root", "root.nimble"), package("web", "packages/web/package.json")]

  test "the nearest manifest wins over an ancestor's":
    check workspaceOf(packages).affectedPackageNames(@["packages/web/index.js"]) ==
      @["web"]

  test "a file outside every nested package falls to the ancestor":
    check workspaceOf(packages, sharedChanges = scNone).affectedPackageNames(
      @["src/main.nim"]
    ) == @["root"]

  test "a package at the repo root claims files no nested package holds":
    check workspaceOf(packages, sharedChanges = scNone).affectedPackageNames(
      @["README.md"]
    ) == @["root"]

suite "explicit sourceFiles":
  test "a pattern claims a file outside the package's own directory":
    let packages = @[
      package("web", "packages/web/package.json", some(@["packages/web/**", "docs/**"])),
      package("cli", "packages/cli/cli.nimble"),
    ]
    check workspaceOf(packages, sharedChanges = scNone).affectedPackageNames(
      @["docs/guide.md"]
    ) == @["web"]

  test "a pattern wins over another package's nearest-ancestor claim":
    let packages = @[
      package("web", "packages/web/package.json", some(@["packages/**"])),
      package("cli", "packages/cli/cli.nimble"),
    ]
    check workspaceOf(packages).affectedPackageNames(@["packages/cli/src/main.nim"]) ==
      @["web"]

  test "a file matching no pattern still falls back to nearest ancestor":
    let packages = @[
      package("web", "packages/web/package.json", some(@["docs/**"])),
      package("cli", "packages/cli/cli.nimble"),
    ]
    check workspaceOf(packages, sharedChanges = scNone).affectedPackageNames(
      @["packages/web/index.js"]
    ) == @["web"]

  test "overlapping patterns are rejected rather than picking a winner":
    let packages = @[
      package("web", "packages/web/package.json", some(@["shared/**"])),
      package("cli", "packages/cli/cli.nimble", some(@["shared/**"])),
    ]
    expect IOError:
      discard workspaceOf(packages).affectedPackageNames(@["shared/util.js"])

suite "looking up a package":
  let projectWorkspace = workspaceOf(
    @[
      package("web", "packages/web/package.json"),
      package("cli", "packages/cli/cli.nimble"),
    ]
  )

  test "packages are named in declaration order":
    check projectWorkspace.packageNames() == @["web", "cli"]

  test "a package is found by name":
    check projectWorkspace.findPackage("cli").manifestRelativePath ==
      "packages/cli/cli.nimble"

  test "an unknown name is rejected, listing what there is":
    expect IOError:
      discard projectWorkspace.findPackage("api")

suite "layout from detected manifests":
  ## What the workspace looks like when the config declares no packages, so the
  ## repository root's manifests are all there is to go on.
  let emptyConfig = NimverConfig()

  test "a lone nimble file names its package after the file":
    let layout = workspaceLayout("/repo", emptyConfig, @["cli.nimble"], quiet = true)
    check layout.packageNames() == @["cli"]
    check layout.packages[0].rootDirectory.len == 0

  test "a lone package.json is named root, since its filename says nothing":
    check workspaceLayout("/repo", emptyConfig, @["package.json"], quiet = true)
      .packageNames() == @["root"]

  test "detected siblings keep their filenames as names":
    check workspaceLayout(
      "/repo", emptyConfig, @["cli.nimble", "package.json"], quiet = true
    )
      .packageNames() == @["cli.nimble", "package.json"]

  test "detected siblings are released together unless asked otherwise":
    check workspaceLayout(
      "/repo", emptyConfig, @["cli.nimble", "package.json"], quiet = true
    ).strategy == wsFixed

  test "an explicit independent strategy is honoured for detected siblings":
    let independent =
      NimverConfig(strategyWasSpecified: true, workspaceStrategy: wsIndependent)
    check workspaceLayout(
      "/repo", independent, @["cli.nimble", "package.json"], quiet = true
    ).strategy == wsIndependent

  test "a repository with no manifest at all is rejected":
    expect IOError:
      discard workspaceLayout("/repo", emptyConfig, @[], quiet = true)

  test "declared packages are used as given, ignoring what was detected":
    let declared = NimverConfig(
      packages: @[
        PackageConfig(name: "web", manifestPath: "./packages/web/package.json"),
        PackageConfig(name: "cli", manifestPath: "packages/cli/cli.nimble"),
      ]
    )
    let layout = workspaceLayout("/repo", declared, @["stray.nimble"], quiet = true)
    check layout.packageNames() == @["web", "cli"]
    check layout.packages[0].manifestRelativePath == "packages/web/package.json"
    check layout.packages[0].rootDirectory == "packages/web"
