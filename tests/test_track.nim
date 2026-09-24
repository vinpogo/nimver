## Unit tests for the track a version is cut on: what a name may be, and what
## `.nimver/track` says about which package is on which.

import std/[os, tables, unittest]
import track

suite "track names":
  test "letters are accepted, in any case":
    for name in ["alpha", "beta", "rc", "nightly", "RC", "Alpha"]:
      check trackNameProblem(name) == ""

  test "an empty name is refused":
    check trackNameProblem("") == "must not be empty"

  test "anything but letters is refused":
    # Each of these would otherwise reach `git tag`, or make the tag ambiguous
    # about where the track ends and the iteration begins.
    for name in ["rc.2", "rc1", "2", "a-b", "a_b", "a/b", "a b", "-rc", "..", "a.lock"]:
      check trackNameProblem(name) == "may only contain letters"

  test "case is preserved, so two spellings are two tracks":
    check trackNameProblem("Alpha") == ""
    check trackNameProblem("alpha") == ""

suite "reading .nimver/track":
  proc selection(contents: string): TrackSelection =
    parseTrackSelection(contents, ".nimver/track")

  test "a bare name is the default for every package":
    let tracks = selection("alpha\n")
    check tracks.default == "alpha"
    check tracks.byPackage.len == 0

  test "an empty file puts nobody on a track":
    for contents in ["", "\n", "   \n\n"]:
      let tracks = selection(contents)
      check tracks.default == ""
      check not tracks.anyTrack()

  test "a keyed line overrides one package":
    let tracks = selection("alpha\ncli = beta\n")
    check tracks.default == "alpha"
    check tracks.byPackage["cli"] == "beta"

  test "an empty value takes one package off the track":
    let tracks = selection("alpha\nweb =\n")
    check tracks.byPackage["web"] == ""

  test "comments and blank lines are ignored":
    let tracks = selection("; the whole repo\nalpha\n\n# except\nweb =\n")
    check tracks.default == "alpha"
    check tracks.byPackage["web"] == ""

  test "surrounding whitespace is ignored":
    let tracks = selection("  alpha  \n  cli   =   beta  \n")
    check tracks.default == "alpha"
    check tracks.byPackage["cli"] == "beta"

  test "a second default is refused":
    expect IOError:
      discard selection("alpha\nbeta\n")

  test "an invalid track name is refused, wherever it is written":
    # The file is hand-editable, and an unchecked name goes straight into
    # `git tag`.
    expect IOError:
      discard selection("rc.2\n")
    expect IOError:
      discard selection("web = rc.2\n")

  test "a line with no package name is refused":
    expect IOError:
      discard selection("= alpha\n")

  test "a package that no longer exists is not an error":
    # A workspace may legitimately have dropped one, and a release is not the
    # place to fail over a stale line.
    let tracks = selection("alpha\nlonggone = beta\n")
    check tracks.byPackage["longgone"] == "beta"

suite "which track a package is on":
  test "an override wins over the default":
    let tracks = parseTrackSelection("alpha\ncli = beta\n", "t")
    check tracks.trackFor("cli").name == "beta"

  test "the default applies to a package with no override":
    let tracks = parseTrackSelection("alpha\ncli = beta\n", "t")
    check tracks.trackFor("web").name == "alpha"

  test "an empty override takes a package off, default or not":
    let tracks = parseTrackSelection("alpha\nweb =\n", "t")
    check not tracks.trackFor("web").hasTrack()
    check tracks.trackFor("cli").hasTrack()

  test "nothing configured means no track":
    let tracks = TrackSelection()
    check not tracks.trackFor("web").hasTrack()
    check not tracks.anyTrack()

  test "an override alone is enough to be on a track":
    let tracks = parseTrackSelection("web = alpha\n", "t")
    check tracks.anyTrack()
    check tracks.trackFor("web").name == "alpha"
    check not tracks.trackFor("cli").hasTrack()

suite "writing .nimver/track":
  let repoRoot = getTempDir() / "nimver-track-unit"

  setup:
    removeDir(repoRoot)
    createDir(repoRoot)

  test "a written selection reads back the same":
    var tracks = TrackSelection(default: "alpha")
    tracks.byPackage["web"] = "beta"
    tracks.byPackage["cli"] = ""
    writeTracks(repoRoot, tracks)

    let readBack = readTracks(repoRoot)
    check readBack.default == "alpha"
    check readBack.byPackage["web"] == "beta"
    check readBack.byPackage["cli"] == ""

  test "overrides are written in a stable order":
    # The file is committed, so a table's own order would reshuffle the diff.
    var tracks = TrackSelection(default: "alpha")
    for name in ["web", "cli", "api"]:
      tracks.byPackage[name] = "beta"
    check renderTrackSelection(tracks) == "alpha\napi = beta\ncli = beta\nweb = beta\n"

  test "a package taken off the track is written without a trailing space":
    var tracks = TrackSelection(default: "alpha")
    tracks.byPackage["web"] = ""
    check renderTrackSelection(tracks) == "alpha\nweb =\n"

  test "a missing file means no track":
    check not readTracks(repoRoot).anyTrack()

  test "clearing deletes the file, and says nothing when there is none":
    writeTracks(repoRoot, TrackSelection(default: "alpha"))
    check fileExists(trackPath(repoRoot))
    clearTracks(repoRoot)
    check not fileExists(trackPath(repoRoot))
    clearTracks(repoRoot)
    check not readTracks(repoRoot).anyTrack()
