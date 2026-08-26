## In-memory workspaces for the unit suites. The fixtures in `support` spin up
## real repositories for the end-to-end suites; these build the same shapes as
## plain values, for the questions that need no repository to answer.

import std/[options, strutils]
import workspace
import config
import adapters/manifest

proc rootDirectoryOf(manifestRelativePath: string): string =
  ## Empty for a manifest in the repository root, which is what makes it contain
  ## every path. `parentDir` would call that `.` instead.
  let lastSeparatorIndex = manifestRelativePath.rfind('/')
  if lastSeparatorIndex == -1:
    ""
  else:
    manifestRelativePath[0 ..< lastSeparatorIndex]

proc testPackage*(
    name, manifestRelativePath: string, sourceFiles = none[seq[string]]()
): WorkspacePackage =
  WorkspacePackage(
    name: name,
    manifest: manifestAt(manifestRelativePath),
    manifestRelativePath: manifestRelativePath,
    rootDirectory: rootDirectoryOf(manifestRelativePath),
    sourceFilePatterns: sourceFiles,
  )

proc testWorkspace*(
    packages: seq[WorkspacePackage], strategy = wsIndependent, sharedChanges = scAll
): Workspace =
  Workspace(strategy: strategy, sharedChanges: sharedChanges, packages: packages)
