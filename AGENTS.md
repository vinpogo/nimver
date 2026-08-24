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

Mark those with `!` and a `BREAKING CHANGE:` footer explaining the migration.
A breaking marker forces `major` regardless of the type's configured bump.

## Everyday conventions

- Avoid writing comments unless they are necessary. Always prefer readable code over comments.
- Toolchain comes from mise: prefer mise tasks, otherwise prefix commands with `mise exec --`.
- Format Nim with nph before committing: `mise exec -- nph <files>`.
- Do not trust the exit status: nimble exits 0 even when a suite fails
  (v0.22.2), and it stops at the first failing suite rather than running the
  rest. Read the output - `All tests passed` is the only line that means it.
- Suites are `tests/test_*.nim` and shared fixtures live in
  `tests/support.nim`; throwaway repos are created under the system temp
  directory.
- This repository versions itself with nimver, so its own hooks run on every
  commit. Keep commit messages Conventional.
