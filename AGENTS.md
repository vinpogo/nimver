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
runs on. Note recording is skipped during a rebase, so if you reword or relabel
a commit, fix its note in the same pass (`bump=`, `breaking=` and the stored
message) - otherwise the changelog contradicts the history.

## Everyday conventions

- Toolchain comes from mise: prefix commands with `mise exec --`.
- Format Nim with nph before committing: `mise exec -- nph <files>`.
- Run the tests with `mise exec -- nimble test`, but do not trust its exit
  status: nimble exits 0 even when a suite fails or never runs. Read the output
  and check the `Failing suites:` summary the task prints.
- Suites are `tests/test_*.nim`, shared fixtures live in `tests/support.nim`,
  and throwaway repos are created under the system temp directory.
- This repository versions itself with nimver, so its own hooks run on every
  commit. Keep commit messages Conventional; the `version` type is ignored so
  release commits do not record notes.
