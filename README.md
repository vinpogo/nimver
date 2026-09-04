# nimver

Forget about manual versioning — `nimver` handles it for you.

It uses your Git commit history to determine the next version, and even writes your changelog for you. All you need to do is write nice [Conventional Commits](https://www.conventionalcommits.org).

## Install

From npm (needs Node 18+):

```sh
npm install --save-dev @vingy/nimver   # or: npm install -g @vingy/nimver
```

The package is scoped, but the command it installs is plain `nimver` (or `npx nimver`).

From Nimble:

```sh
nimble install nimver
```

Or grab a prebuilt binary for your platform from the [releases page](https://github.com/vinpogo/nimver/releases) and put it on your `PATH`. The binary has no runtime dependencies beyond `git`.

## Setup (per repository)

From the root of the Git repository you want to version:

```sh
nimver init
nimver install-hooks
```

`init` creates `.nimver/config.ini`, pre-populated with sensible defaults.
`install-hooks` writes a `commit-msg` hook into `.git/hooks/` that delegates to this binary, rejecting messages a release would not be able to read. `.nimver/` should be committed to Git.

## Everyday use

Just commit normally, using [Conventional Commits syntax](https://www.conventionalcommits.org/):

```
type(scope)!: subject

optional body

optional footer, e.g.:
BREAKING CHANGE: describe the break
```

When you're ready to cut a release:

```sh
nimver bump           # updates the manifest + CHANGELOG.md, commits, and tags
nimver bump --dry-run # what it would do, and the changelog entry it would write
```

### What counts as pending

`bump` looks back from `HEAD` to the last release of the package it is releasing — the newest commit carrying that package's release tag. Every commit in between is a pending change, and its type decides the bump.

Two things follow from reading history rather than a recorded state:

- **CI needs the history and the tags.** Shallow clones do not have them; on GitHub Actions that means `fetch-depth: 0` on `actions/checkout`.

## Supported project manifests

`nimver bump` currently supports:

- `.nimble`
- `package.json`

## Monorepos

Repositories with multiple packages must list them explicitly in `.nimver/config.ini`:

```ini
[workspace]
strategy = independent
sharedChanges = all

[package.web]
manifest = packages/web/package.json

[package.cli]
manifest = packages/cli/cli.nimble
sourceFiles = "src/cli/src/**"
```

`sourceFiles` is optional per package, see [Change attribution](#change-attribution).

### Strategy

The strategy controls how versioning is handled for the packages. There are two strategies: `independent` and `fixed`.

- `independent` — each package keeps its own version (default)
- `fixed` — all packages share the same version

When using `independent` strategy, you can bump the version of a single package without affecting others using `nimver bump <package>`.

If you don't declare any packages, `nimver` picks up the manifests directly in the repository root. Finding more than one there, it assumes `fixed`, since nothing says how they relate.

### Shared changes

Shared changes are files that belong to no package on their own. There are two options for handling them: `all` and `none`.

- `all` — all packages are affected (default)
- `none` — no packages are affected

### Changelogs

A changelog lives next to its manifest, so where you put manifests decides how many changelogs you get:

- **Each manifest in its own directory** — one `CHANGELOG.md` per package,
  written beside the manifest, with plain `## [1.2.0]` headings.
- **Several manifests in the same directory** (including the repository root) —
  those packages share the one `CHANGELOG.md` in that directory, and each
  section names its package: `## [web 1.2.0]`.

### Change attribution

A committed file is attributed to the package whose manifest is its _nearest
ancestor_, so no per-package file patterns are needed:

```text
packages/web/src/button.ts   -> web
packages/cli/src/main.nim    -> cli
```

When `sourceFiles` is set, it wins over the nearest-ancestor rule. The patterns of two packages must not overlap. Glob patterns must be quoted.

If two manifests share a directory, any file within that directory belongs to neither package and follows [Shared changes](#shared-changes) — set `sourceFiles` to attribute it to one of them.

## Commit types

You can manually configure the commit types and bump levels in `.nimver/config.ini`. These levels are available:

```ini
[types]
foo = major # bumps a major version e.g. 1.1.0 -> 2.0.0
bar = minor # bumps a minor version e.g. 0.1.1 -> 0.2.0
baz = patch # bumps a patch version e.g. 0.1.0 -> 0.1.1
qux = none # shows in changelog but doesn't bump version
quux = ignore # won't show up in changelog
```

A breaking change will always be treated as a major bump.

Each commit is read under the configuration *it* was made with, taken from its own tree — so changing a mapping today does not rewrite what last week's commits meant, and a package added mid-cycle cannot claim changes made before it existed.

Any commit type not listed here is rejected by the `commit-msg` hook (this behavior can be adjusted, see [Allowing unknown types](#allowing-unknown-types) for details). Add your own types (and adjust bump levels) as needed.

The default types are:

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
wip = ignore
```

### Allowing unknown types

By default any type not listed under `[types]` is refused by the `commit-msg` hook,
and skipped with a warning when a release reads the history back. You can instead allow unknown types to be treated as any of the standard types.

```ini
[commits]
unknownType = patch   ; or reject (the default) | ignore | none | minor | major
```

## CLI reference

```
nimver init
nimver install-hooks [--force]
nimver bump [<package>] [--dry-run]
nimver version

Invoked by the installed hook (not usually run by hand):
  nimver check-commit-msg <path-to-message-file>
```
