# Changelog

## [5.1.1] - 2026-09-24

### Commits
- fix(ci): fetch full history in tests workflow
- chore(ci): update release runner versions

## [5.1.0] - 2026-09-24

- Setting up nimver now requires a git tag to detect commit ranges. This also includes setup for new packages in an independently versioned monorepo.
- Transitioning from 0.x to 1.0.0 is now a dedicated decision using a `--stable` flag. This works for a plain `bump` and via tracks. See README to learn more.

### tracks
- Nimver now supports release tracks via the `nimver track` command and it's sub command. Refer to the README to learn more.

### Commits
- chore(ci): link changelog in releases
- feat(tracks): support prerelease release tracks
- fix: require a baseline release tag before bumping
- feat: support stable releases below 1.0.0

## [5.0.0] - 2026-09-18

### Breaking Changes
- a package name containing a space or a backslash was accepted before and is now refused when the config is read. Such a name only ever worked in a `fixed` workspace or as a lone package, where it never reached a tag; rename the package and re-tag its last release under the new name.
- a configuration with an unknown section or setting, a setting written before any section, or a line that does not parse is now refused instead of quietly ignored. A `[package.<name>]` section with no settings at all is likewise an error - a package missing its manifest - rather than a package silently dropped.

### Commits
- build(ci): drop macos amd64 release target
- feat(config): accept scoped package names
- fix(config)!: reject package names a release cannot use
- fix(config)!: check a configuration before reading meaning into it
- fix(config): keep the checker working on the Node bundle

## [4.1.0] - 2026-09-04

- UPPERCASE, /, -, _ and numbers characters are now supported for commit types, scopes can additionally contain . and , .
- Allow mapping a commit type to unknown commit types. A new config entry `[commits.unknownType] = reject | ignore | none | minor | major | patch` controls the behavior.
- All `Release-Note` footers will now be used for the changelog entry of a commit if present.

### changelog-entry
- The changelog entry now puts `Release-Note` footers in it's own section. Commit subjects are now not grouped by type anymore, but the plain commit header is added to a new Commits section. This should make the CHANGELOG more readable and valuable for consumers to read.

### Commits
- feat: allow more characters in commitparser
- feat: allow unknown types if wanted
- feat: allow `Release-Note` footer to override the changelog entry
- refactor(commitparser): unify footer handling
- refactor(changelog-entry): restructure changelog entry

## [4.0.0] - 2026-09-04

### Breaking Changes
- use commits as source of truth instead of change files
- remove --no-commit and --no-tag options from `bump` command

### Fixes
- ignore wip commits
- introducing packages correctly bounds the history for all packages
- removing packages correctly bounds the history for the remaining package
- empty strategy incorrectly parsed as value error

### Refactoring
- humanize the implementation
- humanize parseCommitMessage
- exract bump command
- make entrypoint more readable
- cleanup gitutils
- cleanup checkCommitMsg
- cleanup config.nim
- make checkCommitMsg more readable
- config.nim once again
- split logic out from bump.nim
- separate the history range from what a walk makes of it

### Chores
- fix mise.toml
- remove leftovers from --no-commit and --no-tag removal
- remove useless comments
- hopefully make zed setup more stable
- add lock file
- trim AGENTS.md
- now really better editor setup
- drop mise
- remove last traces of mise
- pin actions

### Tests
- add tests for package addition/removal
- add more test coverage
- fix tests

### Features
- add test job
- add npm package

## [3.0.0] - 2026-08-21

### Breaking Changes
- remove ability to attribute shared changes to a package via config

### Documentation
- de-slop README

## [2.2.0] - 2026-08-21

### Documentation
- curate readme a bit
- add note abou quoting config values

### Features
- allow `bump` to bump all independent packages at once

### Fixes
- independently bumped packages with sibling manifests share the same changelog

## [2.1.0] - 2026-08-20

### Features
- add manifest adapters
- add fixed workspace versioning
- add independent workspace versioning
- version sibling manifests together

### Tests
- split the end-to-end suite into focused files

### Chores
- add .agents/prepare checkout script

### Fixes
- resolve Git directory paths through git rev-parse
- only replace git hooks that carry a generated-by marker
- re-record change notes after a rebase

### Documentation
- record how breaking changes are assessed

### Refactoring
- tag releases by package only when several exist

## [2.0.0] - 2026-08-12

### Breaking Changes
- rename tool to nimver

## [1.2.0] - 2026-08-12

### Fixes
- print only the version number

### Features
- commit and tag by default on bump

## [1.1.0] - 2026-08-12

### Features
- add version command

## [1.0.0] - 2026-08-12

### Breaking Changes
- declare v1.0.0

### Chores
- add MIT license

## [0.3.0] - 2026-08-11

### Documentation
- add readme

### Features
- skip release commits via ignore bump level

### Fixes
- dedupe change notes across commit amends

### Tests
- add end-to-end test suite

### Refactoring
- dedupe change notes via commit diff, not parent hash

## [0.2.1] - 2026-08-11

### Fixes
- correct commit-msg tree-snapshot timing bug

## [0.2.0] - 2026-08-11

### Features
- implement conventional commit versioning
