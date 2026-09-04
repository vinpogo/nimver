## One pending change: a commit that a release has not gone out with yet.
##
## Changes are not stored anywhere - `history` derives them from the commits
## themselves, so a message and its bump level can never drift apart.

import ./semver

const ChangesRelPrefix* = ".nimver/changes/"
  ## Where nimver used to keep a file per pending change. Nothing writes there
  ## any more, but commits from that era still carry those files, and they are
  ## bookkeeping rather than anyone's source: attribution skips them.

type ChangeEntry* = object
  commitType*: string
  scope*: string
  bumpLevel*: BumpLevel
  breaking*: bool
  affectedPackages*: seq[string]
  message*: string
  releaseNote*: string
  breakingNote*: string
