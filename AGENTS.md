# Working in this repository

## Judging whether a change is breaking

**Always compare against the latest release tag, never against unreleased
commits.**

```sh
git describe --tags --abbrev=0     # the baseline everything is measured from
git log --oneline "$(git describe --tags --abbrev=0)"..HEAD
```

A change is breaking only if a repository that worked with that *released*
version would now fail or behave differently. Ask: "someone installed the last
tagged release, set it up, and upgrades - does their setup still work?"

Anything introduced *after* the last tag is unreleased and not yet part of the
public surface. Reshaping it is therefore **not** breaking, even when it looks
drastic:

- renaming or removing a config key that no release ever read
- changing the default of a setting no release ever had
- moving or deleting modules, renaming internal types
- reworking a feature added earlier on the same unreleased branch

So a feature and its later redesign both land as plain `feat:` / `refactor:`
as long as no tagged release ever exposed the earlier shape.

What *is* breaking, by contrast:

- a repository layout the released version accepted now errors out
- a released config value, CLI flag, or command changes meaning or disappears
- release output a user depends on changes shape (tag names, commit subjects)

Mark those with `!` and a `BREAKING CHANGE:` footer explaining the migration.
A breaking marker forces `major` regardless of the type's configured bump.

Remember that bump levels never stack: the release takes the *highest* pending
level, so one stray `!` turns an entire release into a major.

## Change notes must match their commits

The `post-commit` hook records a note under `.nimver/changes/` for the commit it
runs on, and rewrites it on amend. Rewording during a rebase is handled by
`post-rewrite` once the rebase finishes, which re-records every rewritten commit
and folds the corrections into HEAD - so relabelling `fix:` to `feat:` updates
`bump=` on its own.

Those hooks only run when they are installed: `.agents/prepare` writes them for
a fresh checkout, and `nimver install-hooks --force` regenerates them. If you
rewrite history with hooks bypassed (`NIMVER_AMENDING=1`, or a checkout without
hooks), fix the affected notes yourself - otherwise the changelog contradicts
the history.

## Everyday conventions

- Toolchain comes from mise: prefer mise tasks, otherwise prefix commands with `mise exec --`.
- Format Nim with nph before committing: `mise exec -- nph <files>`.
- Run the tests with `mise run test`, not `nimble test` directly: the suites
  shell out to `nimver`, so the task installs the binary first and would
  otherwise exercise whatever was compiled last.
- Do not trust the exit status: nimble exits 0 even when a suite fails
  (v0.22.2), and it stops at the first failing suite rather than running the
  rest. Read the output - `All tests passed` is the only line that means it.
- Suites are `tests/test_*.nim` and shared fixtures live in
  `tests/support.nim`; throwaway repos are created under the system temp
  directory.
- This repository versions itself with nimver, so its own hooks run on every
  commit. Keep commit messages Conventional; the `version` type is ignored so
  release commits do not record notes.
