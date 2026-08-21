# nimver

Semantic versioning for Nim and package.json projects, driven by [Conventional
Commits](https://www.conventionalcommits.org) and wired into Git via hooks.

Every commit is validated against the Conventional Commits format. When it
passes, a small note recording the resulting version bump (`major` / `minor`
/ `patch` / `none`) is folded into that same commit. Later, `bump` consolidates
all pending notes since the last release, bumps the project manifest's version
by the *highest* bump level found (bumps don't stack), and writes a grouped
entry to `CHANGELOG.md`.

## Install

```sh
nimble install nimver
```

## Setup (per repository)

From the root of the Git repository you want to version:

```sh
nimver init
nimver install-hooks
```

`init` creates `.nimver/config.ini` (pre-populated with sensible
defaults, see below) and a `.nimver/changes/` directory.
`install-hooks` writes `commit-msg`, `post-commit` and `post-rewrite` hooks into
`.git/hooks/` that delegate to this binary. Both `.nimver/`
and its contents should be committed to Git — the pending change notes
need to survive across separate commits until you run `bump`.

## Supported project manifests

`nimver bump` currently supports:

- `.nimble`
- `package.json`.

## Everyday use

Just commit normally, using Conventional Commits syntax:

```
type(scope)!: subject

optional body

optional footer, e.g.:
BREAKING CHANGE: describe the break
```

When you're ready to cut a release:

```sh
nimver bump                       # updates the manifest + CHANGELOG.md, commits, and tags
nimver bump --dry-run             # preview without writing anything
nimver bump --no-commit           # update files, but skip the commit (and the tag)
nimver bump --no-tag              # commit the release, but skip the git tag
nimver bump --no-commit --no-tag  # only touch the manifest/CHANGELOG.md, no git activity
```

## Workspaces

Repositories with multiple packages must list them explicitly in
`.nimver/config.ini`:

```ini
[workspace]
sharedChanges = all

[package.web]
manifest = packages/web/package.json

[package.cli]
manifest = packages/cli/cli.nimble
```

`sourceFiles` is optional per package and narrows what that package claims:

```ini
[package.web]
manifest = packages/web/package.json
sourceFiles = packages/web/**, docs/**
```

### Strategies

`strategy = independent` is the default: each package keeps its own version, so
`bump` takes the package to release:

```sh
nimver bump web
nimver bump cli --dry-run
```

Each package gets its own version, its own `CHANGELOG.md` next to its manifest,
a `version(<package>): vX.Y.Z` release commit, and a `<package>-vX.Y.Z` tag.
Plain `nimver bump` reports which packages have pending changes instead of
releasing several at once, so a release is always one commit and one tag.

`strategy = fixed` instead gives every package one shared version. All
configured manifests must start at the same version, and `nimver bump` moves all
of them to the same next version; a mismatch is reported before any file is
changed. The release commit is `version: vX.Y.Z`, tagged `vX.Y.Z`, and the
changelog is the repository-root `CHANGELOG.md`.

```ini
[workspace]
strategy = fixed
```

A workspace with a single package is unaffected by either strategy: `nimver bump`
needs no package name, and releases keep the flat `version: vX.Y.Z` commit,
`vX.Y.Z` tag, and root `CHANGELOG.md`. That holds whether the manifest was
detected or declared, so naming one package to exclude an unrelated sibling
manifest does not change how releases are tagged. Package-namespaced tags start
only once a workspace holds more than one package.

A commit that touches several packages records one note listing all of them, and
releasing a package consumes only its own entry:

```ini
packages=web,cli    # after `nimver bump web`:
packages=cli        # still pending for cli, same note file
```

The note is removed once its last package has been released, so filenames stay
stable and no note is rewritten just because a commit hash changed.

### Change attribution

A changed file is attributed to the package whose manifest is its *nearest
ancestor*, so no per-package file patterns are needed:

```text
packages/web/src/button.ts   -> web
packages/cli/src/main.nim    -> cli
```

Where `sourceFiles` is set, it wins over the nearest-ancestor rule; the patterns
of two packages must not overlap. A package's own manifest always belongs to it.

A manifest at the repository root acts as a catch-all for everything not inside
a more specific package. Two packages may share a directory only under
`strategy = fixed`, where they move together anyway. Under `independent` that is
rejected: the packages would be released separately, yet a change in the shared
directory could belong to either one, and `sourceFiles` cannot be inferred.

nimver does not filter files within a package (docs, fixtures, examples). Use
commit types for that: a `docs:` or `chore:` commit is mapped to `none` by
default, so it appears in the changelog without bumping the version.

Changed files that match no package are controlled by `sharedChanges`:

- `all` affects every package.
- `none` does not create a pending change for any package.
- `package.<name>` affects only the named package.

Change files remain one-per-commit and include a `packages` header listing the
affected packages. Repositories without any `[package.<name>]` sections remain
backward compatible: their root manifest is detected automatically and treated
as a single package named `root`.

## Configuration

`.nimver/config.ini` maps each Conventional Commit type to a
bump level. `none` means the type is valid and still shows up in the
changelog, but doesn't bump the version by itself. `ignore` means the type
is valid but is skipped entirely — no change file is recorded and it never
appears in the changelog. This is used for the `version` type, which is the
commit type `bump` uses for its own release commits (unless `--no-commit`
is passed), so running `bump` doesn't cause the release commit itself to
show up as a pending change the next time you run `bump`.

```ini
[types]
feat = minor
fix = patch
perf = patch
refactor = patch
revert = patch
docs = none
style = none
chore = none
test = none
build = none
ci = none
version = ignore
```

Any commit type not listed here is rejected by the `commit-msg` hook. Add
your own types (and adjust bump levels) as needed.

## Testing

```sh
nimble test
```

This builds the binary, then runs each `tests/test_*.nim` suite:

| Suite | Covers |
| --- | --- |
| `test_hooks.nim` | commit validation, note recording, amends, rebases |
| `test_manifests.nim` | manifest detection and version-only edits |
| `test_bump.nim` | releasing a single detected manifest |
| `test_workspace.nim` | attributing changed files to packages |
| `test_strategies.nim` | `fixed` and `independent` releases |

`tests/support.nim` holds the shared fixtures. Every test drives real `git` +
`nimver` invocations against a throwaway repo created under the system temp
directory (override with `NIMVER_TEST_DIR`), and each starts from a fresh repo.

Watch the output rather than the exit status: `nimble test` always exits 0,
because nimble swallows a failing task (v0.22.2). The task prints a
`Failing suites:` summary at the end when something fails.

## CLI reference

```
nimver init
nimver install-hooks [--force]
nimver bump [<package>] [--no-commit] [--no-tag] [--dry-run]
nimver version

Invoked by installed hooks (not usually run by hand):
  nimver check-commit-msg <path-to-message-file>
  nimver record-commit
  nimver record-rewrite <rebase|amend>
```

## Why three hooks?

A commit's tree is already fixed by the time `commit-msg` runs, so a file
written and staged there does not end up in the commit being created — it
would only surface in whatever commit comes next. To keep each commit
self-contained, `commit-msg` is used purely for validation (and can reject
the commit), while `post-commit` writes the actual bump-note file for the
commit that was just made and folds it in via a guarded `git commit --amend`.

`post-commit` also fires for each commit a rebase replays, but amending there
would move HEAD out from under the rebase sequencer and abort it, so it stands
down while a rebase is running. `post-rewrite` runs once the rebase is over,
with the list of commits it rewrote, and re-records their notes then. The
corrections are folded into HEAD rather than into each rewritten commit: moving
a note back to its own commit would mean rewriting history a second time, and a
release reads the set of pending notes, not which commit carries them.
