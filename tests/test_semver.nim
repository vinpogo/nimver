## Unit tests for version parsing and bumping, and for the bump levels
## themselves: their ordering is what decides a release, since a release takes
## the highest level among its pending changes.

import std/[unittest]
import semver
import results

suite "parsing versions":
  test "plain major.minor.patch":
    let version = parseSemVer("1.2.3").value
    check version.major == 1
    check version.minor == 2
    check version.patch == 3

  test "surrounding whitespace is ignored":
    check $parseSemVer("  0.4.11\n").value == "0.4.11"

  test "a track suffix is kept, and says which track and which iteration":
    let version = parseSemVer("1.2.3-rc.1").value
    check version.core == parseSemVer("1.2.3").value
    check version.track == "rc"
    check version.iteration == 1
    check version.isPrerelease()
    check $version == "1.2.3-rc.1"

  test "a release has no track":
    let version = parseSemVer("1.2.3").value
    check version.track == ""
    check version.iteration == 0
    check not version.isPrerelease()

  test "a suffix nimver did not write is still dropped":
    # Everything nimver writes is `<letters>.<n>`. A suffix of any other shape
    # belongs to whoever wrote it, and reading meaning into it would claim
    # versions that are not ours.
    check $parseSemVer("1.2.3-SNAPSHOT").value == "1.2.3"
    check $parseSemVer("1.2.3-rc1").value == "1.2.3"
    check $parseSemVer("1.2.3-rc.1.2").value == "1.2.3"
    check $parseSemVer("1.2.3-rc.0").value == "1.2.3"
    check $parseSemVer("1.2.3-rc.x").value == "1.2.3"
    check $parseSemVer("1.2.3-2.1").value == "1.2.3"
    check $parseSemVer("1.2.3-").value == "1.2.3"

  test "build metadata is dropped":
    check $parseSemVer("1.2.3+build.5").value == "1.2.3"

  test "a dash inside build metadata does not confuse the track split":
    check $parseSemVer("1.2.3+build-5").value == "1.2.3"
    check $parseSemVer("1.2.3-rc.1+build.5").value == "1.2.3-rc.1"

  test "two versions differing only in their track are not the same version":
    check parseSemVer("1.2.3").value != parseSemVer("1.2.3-rc.1").value
    check parseSemVer("1.2.3-rc.1").value != parseSemVer("1.2.3-rc.2").value
    check parseSemVer("1.2.3-rc.1").value != parseSemVer("1.2.3-beta.1").value

  test "too few components are rejected":
    check parseSemVer("1.2").isErr

  test "too many components are rejected":
    check parseSemVer("1.2.3.4").isErr

  test "a tag-style leading v is rejected":
    check parseSemVer("v1.2.3").isErr

  test "non-numeric components are rejected":
    check parseSemVer("1.x.3").isErr

  test "an empty string is rejected":
    check parseSemVer("").isErr

suite "bumping versions":
  let version = parseSemVer("1.2.3").value

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
    check $parseSemVer("0.1.0").value.bump(blMinor) == "0.2.0"

  test "any 0.x bumped by a major lands on 1.0.0, which is what a promotion cuts":
    # So the pinned version and the bumped one agree wherever both could apply.
    for spelled in ["0.0.0", "0.0.3", "0.4.2", "0.99.7"]:
      check parseSemVer(spelled).value.bump(blMajor) == FirstStableVersion

  test "bumping a prerelease yields a release":
    # A track is put back on afterwards, by whoever knows which one and at
    # which iteration.
    check $parseSemVer("1.2.3-rc.4").value.bump(blPatch) == "1.2.4"
    check $parseSemVer("1.2.3-rc.4").value.bump(blMajor) == "2.0.0"

  test "none and ignore leave a prerelease as it stands":
    check $parseSemVer("1.2.3-rc.4").value.bump(blNone) == "1.2.3-rc.4"
    check $parseSemVer("1.2.3-rc.4").value.bump(blIgnore) == "1.2.3-rc.4"

suite "putting a version on a track":
  test "onTrack keeps the core and spells the suffix":
    check $parseSemVer("1.2.0").value.onTrack("alpha", 9) == "1.2.0-alpha.9"

  test "onTrack replaces a track already there":
    check $parseSemVer("1.2.0-alpha.9").value.onTrack("beta", 1) == "1.2.0-beta.1"

  test "core strips the track":
    check $parseSemVer("1.2.0-alpha.9").value.core == "1.2.0"

  test "a rendered prerelease parses back to itself":
    for spelled in ["1.2.0-alpha.1", "0.1.0-rc.21", "10.0.3-nightly.100"]:
      check $parseSemVer(spelled).value == spelled

suite "staying below 1.0.0":
  test "a major of zero is not stable, and a prerelease counts by its core":
    # `1.0.0-rc.1` counting as stable is what makes a promotion stick across
    # the iterations of a track: the shift is off from the first one on.
    check not parseSemVer("0.0.0").value.isStable()
    check not parseSemVer("0.9.9").value.isStable()
    check not parseSemVer("0.9.0-rc.1").value.isStable()
    check parseSemVer("1.0.0").value.isStable()
    check parseSemVer("1.0.0-rc.1").value.isStable()
    check parseSemVer("2.3.4").value.isStable()

  test "below 1.0.0 a major takes the minor and a minor the patch":
    # `^0.4.2` only ever promised 0.4.x, so 0.4 to 0.5 is already the break
    # that 1.x spells as a major. Held on the level, so a project that maps its
    # types differently is held the same way.
    let unstable = parseSemVer("0.4.2").value
    check heldBelowStable(blMajor, unstable) == blMinor
    check heldBelowStable(blMinor, unstable) == blPatch

  test "patch is the floor: a held level never becomes nothing":
    # Held any lower, a release with changes in it would have nothing left to
    # cut, and `isReleasable` would contradict itself.
    check heldBelowStable(blPatch, parseSemVer("0.4.2").value) == blPatch

  test "0.0.x is held exactly like any other 0.x":
    let earliest = parseSemVer("0.0.3").value
    check heldBelowStable(blMajor, earliest) == blMinor
    check heldBelowStable(blMinor, earliest) == blPatch

  test "at 1.0.0 and above nothing is held":
    for spelled in ["1.0.0", "1.0.0-rc.1", "4.2.0"]:
      let stable = parseSemVer(spelled).value
      for level in BumpLevel:
        check heldBelowStable(level, stable) == level

  test "none and ignore are not bumps, so they are left where they are":
    let unstable = parseSemVer("0.4.2").value
    check heldBelowStable(blNone, unstable) == blNone
    check heldBelowStable(blIgnore, unstable) == blIgnore

suite "bump levels":
  test "parsing is case-insensitive and ignores whitespace":
    check parseBumpLevel("MAJOR").value == blMajor
    check parseBumpLevel(" minor ").value == blMinor
    check parseBumpLevel("Patch").value == blPatch
    check parseBumpLevel("none").value == blNone
    check parseBumpLevel("ignore").value == blIgnore

  test "an unknown level is rejected":
    check parseBumpLevel("huge").isErr

  test "an empty level is rejected":
    check parseBumpLevel("").isErr

  test "rendering round-trips through parsing":
    for level in BumpLevel:
      check parseBumpLevel($level).value == level

  test "levels order from ignore up to major, which is what highestBumpLevel folds on":
    check blIgnore < blNone
    check blNone < blPatch
    check blPatch < blMinor
    check blMinor < blMajor
