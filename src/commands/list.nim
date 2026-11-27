import std/[sequtils, strutils]
import results
import ../config
import ../effects
import ../semver
import ../track
import ../workspace

proc aligned(rows: seq[seq[string]]): seq[string] =
  let columns = rows.mapIt(it.len).max()
  var widths = newSeq[int](columns)
  for row in rows:
    for column, cell in row:
      widths[column] = max(widths[column], cell.len)
  for row in rows:
    var cells: seq[string]
    for column, cell in row:
      cells.add(cell.alignLeft(widths[column]))
    result.add(cells.join("  ").strip(leading = false))

proc cmdList*(repoRoot: string, effects: var Effects): Result[void, string] =
  let config = ?loadUserConfig(repoRoot)
  let projectWorkspace = ?loadWorkspace(repoRoot, config, effects)
  let tracks = ?readTracks(repoRoot)
  var rows: seq[seq[string]]
  for package in projectWorkspace.packages:
    let track = tracks.trackFor(package.name)
    rows.add(
      @[
        package.name,
        $(?currentVersion(package)),
        package.manifestRelativePaths.join(", "),
        (if track.hasTrack(): "track '" & track.name & "'" else: ""),
      ]
    )
  effects.add(say(aligned(rows).join("\n")))
  ok()
