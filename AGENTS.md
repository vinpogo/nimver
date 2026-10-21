# Working in this repository

## Judging whether a change is breaking

**Always compare against the latest release tag, never against unreleased
commits.**

A change is breaking only if a repository that worked with that *released*
version would now fail or behave differently. Ask: "someone installed the last
tagged release, set it up, and upgrades - does their setup still work?"

What *is* breaking:

- a repository layout the released version accepted now errors out
- a released config value, CLI flag, or command changes meaning or disappears
- release output a user depends on changes shape (tag names, commit subjects)
- the version a given history produces changes

Mark those with `!` and a `BREAKING CHANGE:` footer explaining the migration.
A breaking marker forces `major` regardless of the type's configured bump - and
below 1.0.0 that `major` is cut as a minor (see README, "Below 1.0.0"). nimver
itself is past 1.0.0, so its own releases are unaffected by that holding.

## Every command is a pipeline

- A command reads what it needs and returns a nim-results `Result[T, string]`.
  It never prints, writes a file or runs a mutating `git` command itself: it
  queues `Effect`s (`src/effects.nim`), and `run` in `src/nimver.nim` performs
  them once the command is done.
- A failed command still has what it queued performed before its error is
  printed, so queue a change only after the command's last step that can fail.
- nimver's own code does not raise. Return `err(...)`, chain with `?`, and wrap
  a standard library call that raises in `catch(...).mapErr(e => e.msg)`.
  Defects are the exception.

## Everyday conventions

- After cloning, run `nimble setup`: with `nimble.lock` present, a plain `nim c`
  finds the `results` dependency only through the `nimble.paths` it writes.

- Avoid writing comments unless they are necessary. Always prefer readable code over comments.
- Format Nim with nph before committing: `nph <files>`.
- Do not trust the exit status: nimble exits 0 even when a suite fails
  (v0.22.2), and it stops at the first failing suite rather than running the
  rest. Read the output - `All tests passed` is the only line that means it.
- Suites are `tests/test_*.nim` and shared fixtures live in
  `tests/support.nim`; throwaway repos are created under the system temp
  directory.
- This repository versions itself with nimver, so its own hooks run on every
  commit. Keep commit messages Conventional.
