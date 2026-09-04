# Changelog

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
