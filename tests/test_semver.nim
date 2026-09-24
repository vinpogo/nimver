## Unit tests for version parsing and bumping, and for the bump levels
## themselves: their ordering is what decides a release, since a release takes
## the highest level among its pending changes.

import std/[unittest]
import semver

suite "parsing versions":
  test "plain major.minor.patch":
    let version = parseSemVer("1.2.3")
    check version.major == 1
    check version.minor == 2
    check version.patch == 3

  test "surrounding whitespace is ignored":
    check $parseSemVer("  0.4.11\n") == "0.4.11"

  test "a track suffix is kept, and says which track and which iteration":
    let version = parseSemVer("1.2.3-rc.1")
    check version.core == parseSemVer("1.2.3")
    check version.track == "rc"
    check version.iteration == 1
    check version.isPrerelease()
    check $version == "1.2.3-rc.1"

  test "a release has no track":
    let version = parseSemVer("1.2.3")
    check version.track == ""
    check version.iteration == 0
    check not version.isPrerelease()

  test "a suffix nimver did not write is still dropped":
    # Everything nimver writes is `<letters>.<n>`. A suffix of any other shape
    # belongs to whoever wrote it, and reading meaning into it would claim
    # versions that are not ours.
    check $parseSemVer("1.2.3-SNAPSHOT") == "1.2.3"
    check $parseSemVer("1.2.3-rc1") == "1.2.3"
    check $parseSemVer("1.2.3-rc.1.2") == "1.2.3"
    check $parseSemVer("1.2.3-rc.0") == "1.2.3"
    check $parseSemVer("1.2.3-rc.x") == "1.2.3"
    check $parseSemVer("1.2.3-2.1") == "1.2.3"
    check $parseSemVer("1.2.3-") == "1.2.3"

  test "build metadata is dropped":
    check $parseSemVer("1.2.3+build.5") == "1.2.3"

  test "a dash inside build metadata does not confuse the track split":
    check $parseSemVer("1.2.3+build-5") == "1.2.3"
    check $parseSemVer("1.2.3-rc.1+build.5") == "1.2.3-rc.1"

  test "two versions differing only in their track are not the same version":
    check parseSemVer("1.2.3") != parseSemVer("1.2.3-rc.1")
    check parseSemVer("1.2.3-rc.1") != parseSemVer("1.2.3-rc.2")
    check parseSemVer("1.2.3-rc.1") != parseSemVer("1.2.3-beta.1")

  test "too few components are rejected":
    expect ValueError:
      discard parseSemVer("1.2")

  test "too many components are rejected":
    expect ValueError:
      discard parseSemVer("1.2.3.4")

  test "a tag-style leading v is rejected":
    expect ValueError:
      discard parseSemVer("v1.2.3")

  test "non-numeric components are rejected":
    expect ValueError:
      discard parseSemVer("1.x.3")

  test "an empty string is rejected":
    expect ValueError:
      discard parseSemVer("")

suite "bumping versions":
  let version = parseSemVer("1.2.3")

  test "major resets minor and patch":
    check $version.bump(blMajor) == "2.0.0"

  test "minor resets patch":
    check $version.bump(blMinor) == "1.3.0"

  test "patch increments patch":
    check $version.bump(blPatch) == "1.2.4"

  test "none leaves the version alone":
    check $version.bump(blNone) == "1.2.3"

  test "ignore leaves the version alone":
    check $version.bump(blIgnore) == "1.2.3"

  test "a zero major stays below one":
    check $parseSemVer("0.1.0").bump(blMinor) == "0.2.0"

  test "bumping a prerelease yields a release":
    # A track is put back on afterwards, by whoever knows which one and at
    # which iteration.
    check $parseSemVer("1.2.3-rc.4").bump(blPatch) == "1.2.4"
    check $parseSemVer("1.2.3-rc.4").bump(blMajor) == "2.0.0"

  test "none and ignore leave a prerelease as it stands":
    check $parseSemVer("1.2.3-rc.4").bump(blNone) == "1.2.3-rc.4"
    check $parseSemVer("1.2.3-rc.4").bump(blIgnore) == "1.2.3-rc.4"

suite "putting a version on a track":
  test "onTrack keeps the core and spells the suffix":
    check $parseSemVer("1.2.0").onTrack("alpha", 9) == "1.2.0-alpha.9"

  test "onTrack replaces a track already there":
    check $parseSemVer("1.2.0-alpha.9").onTrack("beta", 1) == "1.2.0-beta.1"

  test "core strips the track":
    check $parseSemVer("1.2.0-alpha.9").core == "1.2.0"

  test "a rendered prerelease parses back to itself":
    for spelled in ["1.2.0-alpha.1", "0.1.0-rc.21", "10.0.3-nightly.100"]:
      check $parseSemVer(spelled) == spelled

suite "bump levels":
  test "parsing is case-insensitive and ignores whitespace":
    check parseBumpLevel("MAJOR") == blMajor
    check parseBumpLevel(" minor ") == blMinor
    check parseBumpLevel("Patch") == blPatch
    check parseBumpLevel("none") == blNone
    check parseBumpLevel("ignore") == blIgnore

  test "an unknown level is rejected":
    expect ValueError:
      discard parseBumpLevel("huge")

  test "an empty level is rejected":
    expect ValueError:
      discard parseBumpLevel("")

  test "rendering round-trips through parsing":
    for level in BumpLevel:
      check parseBumpLevel($level) == level

  test "levels order from ignore up to major, which is what highestBumpLevel folds on":
    check blIgnore < blNone
    check blNone < blPatch
    check blPatch < blMinor
    check blMinor < blMajor
