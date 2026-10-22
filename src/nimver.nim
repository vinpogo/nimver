import std/options
import ./sysio
import ./effects
import ./gitutils
import ./cli
import results
import ./commands/init
import ./commands/installHooks
import ./commands/checkCommitMsg
import ./commands/bump
import ./commands/track
import ./commands/changelog

const
  NimblePkgVersion {.strdefine.} = "unknown"
  PackageOption = OptionSpec(
    long: "package",
    short: 'p',
    hasValue: true,
    help: "only this package, in an independent workspace",
  )
  Nimver = initCli(
    name = "nimver",
    version = NimblePkgVersion,
    header = "nimver - semantic versioning from Conventional Commits",
    footer = "See https://github.com/vinpogo/nimver for details.",
    commands = @[
      initCommand(
        name = "init",
        summary = "Write a default config to .nimver/config.ini.",
        handler = proc(call: tuple[], effects: var Effects): Result[int, string] =
          ?cmdInit(?findRepoRoot(), effects)
          ok(0),
      ),
      initCommand(
        name = "install-hooks",
        summary = "Install the commit-msg hook that checks every commit message.",
        options = @[
          OptionSpec(
            long: "force",
            short: 'f',
            help: "overwrite a commit-msg hook that is already there",
          )
        ],
        handler = proc(
            call: tuple[force: bool], effects: var Effects
        ): Result[int, string] =
          ?cmdInstallHooks(?findRepoRoot(), call.force, effects)
          ok(0),
      ),
      initCommand(
        name = "bump",
        summary = "Release what the commits since the last release add up to.",
        options = @[
          OptionSpec(
            long: "dry-run",
            short: 'd',
            help: "show the release without writing, committing or tagging",
          ),
          OptionSpec(
            long: "stable", short: 's', help: "cut 1.0.0 rather than another 0.x"
          ),
        ],
        arguments = @[
          ArgumentSpec(
            name: "package",
            optional: true,
            help: "release only this package, in an independent workspace",
          )
        ],
        handler = proc(
            call: tuple[package: Option[string], dryRun, stable: bool],
            effects: var Effects,
        ): Result[int, string] =
          ?cmdBump(?findRepoRoot(), call.package, call.dryRun, call.stable, effects)
          ok(0),
      ),
      initCommand(
        name = "changelog",
        summary = "Print the changelog entry a release was cut with.",
        arguments = @[
          ArgumentSpec(name: "version", help: "the version released, e.g. 1.2.0"),
          ArgumentSpec(
            name: "package",
            optional: true,
            help: "the package it was released for, in an independent workspace",
          ),
        ],
        handler = proc(
            call: tuple[version: string, package: Option[string]], effects: var Effects
        ): Result[int, string] =
          ?cmdChangelog(?findRepoRoot(), call.package, call.version, effects)
          ok(0),
      ),
      initCommand(
        name = "track",
        summary = "Say which track you are on.",
        commands = @[
          initCommand(
            name = "enter",
            summary = "Cut prereleases on a track from the next bump on.",
            options = @[
              PackageOption,
              OptionSpec(
                long: "stable",
                short: 's',
                help: "the first version cut below 1.0.0 is 1.0.0",
              ),
            ],
            arguments =
              @[ArgumentSpec(name: "name", help: "the track, e.g. alpha or rc")],
            handler = proc(
                call: tuple[name: string, package: Option[string], stable: bool],
                effects: var Effects,
            ): Result[int, string] =
              ?cmdTrackEnter(
                ?findRepoRoot(), call.name, call.package, call.stable, effects
              )
              ok(0),
          ),
          initCommand(
            name = "exit",
            summary = "Cut releases again from the next bump on.",
            options = @[PackageOption],
            handler = proc(
                call: tuple[package: Option[string]], effects: var Effects
            ): Result[int, string] =
              ?cmdTrackExit(?findRepoRoot(), call.package, effects)
              ok(0),
          ),
        ],
        handler = proc(call: tuple[], effects: var Effects): Result[int, string] =
          ?cmdTrackStatus(?findRepoRoot(), effects)
          ok(0),
      ),
      initCommand(
        name = "check-commit-msg",
        summary = "Check a commit message file. Run by the commit-msg hook.",
        arguments = @[
          ArgumentSpec(
            name: "path-to-message-file", help: "the file git hands the commit-msg hook"
          )
        ],
        handler = proc(
            call: tuple[pathToMessageFile: string], effects: var Effects
        ): Result[int, string] =
          cmdCheckCommitMsg(?findRepoRoot(), call.pathToMessageFile, effects),
      ),
    ],
  )

proc dispatch(args: seq[string], effects: var Effects): Result[int, string] =
  ## The exit code the command ends with, its effects queued but not yet
  ## performed.
  let invocation = ?Nimver.parse(args)
  case invocation.kind
  of ikPrint:
    effects.add(say(invocation.text))
    ok(0)
  of ikRun:
    invocation.handle(effects)

proc run(args: seq[string]): int =
  ## The one place a command's effects are performed. A command that failed
  ## still has what it queued performed first, so that what it said before
  ## failing is not lost.
  var effects: Effects
  let exitCode = dispatch(args, effects)
  perform(effects).isOkOr:
    writeError("nimver: " & error)
    return 1
  exitCode.valueOr:
    writeError("nimver: " & error)
    return 1

when isMainModule:
  quit(run(cliArgs()))
