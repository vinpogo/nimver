## The command-line parser on its own, against a table shaped like nimver's,
## and the flags nimver answers before any command.

import std/[options, os, strutils, unittest]
import results
import cli
import effects
import ./support

type
  BumpCall = tuple[package: Option[string], dryRun, stable: bool]
  ChangelogCall = tuple[version: string, package: Option[string]]
  EnterCall = tuple[name: string, package: Option[string]]
  ExitCall = tuple[package: Option[string]]

const
  Package = OptionSpec(long: "package", short: 'p', hasValue: true, help: "only this")
  Sample = initCli(
    name = "tool",
    version = "1.2.3",
    header = "tool - does things",
    footer = "See the docs.",
    commands = @[
      initCommand(
        name = "bump",
        summary = "Release.",
        options = @[
          OptionSpec(long: "dry-run", short: 'd', help: "do not write"),
          OptionSpec(long: "stable", help: "go stable"),
        ],
        arguments =
          @[ArgumentSpec(name: "package", optional: true, help: "which package")],
        handler = proc(call: BumpCall, effects: var Effects): Result[int, string] =
          ok(0),
      ),
      initCommand(
        name = "changelog",
        summary = "Show an entry.",
        arguments = @[
          ArgumentSpec(name: "version"), ArgumentSpec(name: "package", optional: true)
        ],
        handler = proc(call: ChangelogCall, effects: var Effects): Result[int, string] =
          ok(0),
      ),
      initCommand(
        name = "track",
        summary = "Report.",
        commands = @[
          initCommand(
            name = "enter",
            summary = "Enter.",
            options = @[Package],
            arguments = @[ArgumentSpec(name: "name")],
            handler = proc(call: EnterCall, effects: var Effects): Result[int, string] =
              ok(call.name.len),
          ),
          initCommand(
            name = "exit",
            summary = "Exit.",
            options = @[Package],
            handler = proc(call: ExitCall, effects: var Effects): Result[int, string] =
              ok(0),
          ),
        ],
        handler = proc(call: tuple[], effects: var Effects): Result[int, string] =
          ok(1),
      ),
      initCommand(
        name = "secret",
        summary = "Nothing to take.",
        handler = proc(call: tuple[], effects: var Effects): Result[int, string] =
          ok(2),
      ),
    ],
  )

proc parsed(words: varargs[string]): Invocation =
  Sample.parse(@words).get

proc refusal(words: varargs[string]): string =
  Sample.parse(@words).isOkOr:
    return error
  raiseAssert "expected a refusal"

suite "choosing the command":
  test "a subcommand is chosen when the next word names one":
    check parsed("track", "enter", "beta").to(EnterCall).name == "beta"

  test "a word after a command with subcommands is an unknown command":
    check refusal("track", "sideways") ==
      "unknown command 'sideways' for `tool track`. See `tool track --help`."

  test "no words is a failure that carries the overview":
    check refusal() == "no command given\n\n" & Sample.overview()

  test "an unknown command is a failure that carries the overview":
    check refusal("bogus") == "unknown command 'bogus'\n\n" & Sample.overview()

suite "handlers":
  test "the chosen command's handler is what runs":
    var effects: Effects
    check parsed("track", "enter", "beta").handle(effects).get == 4

  test "handlers taking the same tuple stay apart":
    var effects: Effects
    check parsed("track").handle(effects).get == 1
    check parsed("secret").handle(effects).get == 2

suite "options":
  test "flags are given or not":
    let call = parsed("bump", "--dry-run").to(BumpCall)
    check call.dryRun
    check not call.stable

  test "a short flag is the long one":
    check parsed("bump", "-d").to(BumpCall).dryRun

  test "a value follows its option, before or after the arguments":
    for words in [
      @["track", "enter", "beta", "--package", "web"],
      @["track", "enter", "beta", "-p", "web"],
      @["track", "enter", "--package", "web", "beta"],
    ]:
      let call = Sample.parse(words).get.to(EnterCall)
      check call.package == some("web")
      check call.name == "beta"

  test "an option not given has no value":
    check parsed("track", "exit").to(ExitCall).package.isNone

  test "an unknown option is refused rather than taken for an argument":
    check refusal("bump", "--stabel") == "unknown option '--stabel' for `tool bump`"
    check refusal("changelog", "--x", "1.0.0") ==
      "unknown option '--x' for `tool changelog`"

  test "short flags are not combined":
    check refusal("bump", "-ds") == "unknown option '-ds' for `tool bump`"

  test "a value is never joined to its option":
    check refusal("track", "exit", "--package=web") ==
      "unknown option '--package=web' for `tool track exit`"
    check refusal("bump", "--dry-run=yes") ==
      "unknown option '--dry-run=yes' for `tool bump`"

  test "an option needs its value":
    check refusal("track", "exit", "--package") == "`--package` needs a <package>"
    check refusal("track", "exit", "--package", "") == "`--package` needs a <package>"

  test "an unknown option is refused even when help is asked for":
    check refusal("bump", "--stabel", "--help") ==
      "unknown option '--stabel' for `tool bump`"

suite "arguments":
  test "words fill the arguments in order, optional ones only when given":
    let alone = parsed("changelog", "1.2.0").to(ChangelogCall)
    check alone.version == "1.2.0"
    check alone.package.isNone

    let both = parsed("changelog", "1.2.0", "web").to(ChangelogCall)
    check both.version == "1.2.0"
    check both.package == some("web")

  test "a wrong number of arguments says how many are expected":
    check refusal("changelog") ==
      "`tool changelog` expects 1 to 2 arguments, got 0. See `tool changelog --help`."
    check refusal("changelog", "a", "b", "c") ==
      "`tool changelog` expects 1 to 2 arguments, got 3. See `tool changelog --help`."
    check refusal("bump", "a", "b") ==
      "`tool bump` expects 0 to 1 arguments, got 2. See `tool bump --help`."
    check refusal("track", "enter") ==
      "`tool track enter` expects 1 argument, got 0. See `tool track enter --help`."
    check refusal("secret", "x") ==
      "`tool secret` expects 0 arguments, got 1. See `tool secret --help`."

suite "checking the table":
  test "a required argument after an optional one is a defect":
    expect AssertionDefect:
      discard initCommand(
        name = "changelog",
        summary = "",
        arguments = @[
          ArgumentSpec(name: "package", optional: true), ArgumentSpec(name: "version")
        ],
        handler = proc(call: ChangelogCall, effects: var Effects): Result[int, string] =
          ok(0),
      )

  test "a handler must read exactly what its command declares":
    const Arguments =
      @[ArgumentSpec(name: "version"), ArgumentSpec(name: "package", optional: true)]
    expect AssertionDefect:
      discard initCommand(
        name = "changelog",
        summary = "",
        arguments = Arguments,
        handler = proc(
            call: tuple[verison: string, package: Option[string]], effects: var Effects
        ): Result[int, string] =
          ok(0),
      )
    expect AssertionDefect:
      discard initCommand(
        name = "changelog",
        summary = "",
        arguments = Arguments,
        handler = proc(
            call: tuple[version: string, package: string], effects: var Effects
        ): Result[int, string] =
          ok(0),
      )
    expect AssertionDefect:
      discard initCommand(
        name = "changelog",
        summary = "",
        arguments = Arguments,
        handler = proc(
            call: tuple[version: string], effects: var Effects
        ): Result[int, string] =
          ok(0),
      )

  test "a name or short option given twice, or help redeclared, is a defect":
    expect AssertionDefect:
      discard initCommand(
        name = "exit",
        summary = "",
        options = @[Package],
        arguments = @[ArgumentSpec(name: "package", optional: true)],
        handler = proc(call: ExitCall, effects: var Effects): Result[int, string] =
          ok(0),
      )
    expect AssertionDefect:
      discard initCommand(
        name = "exit",
        summary = "",
        options = @[OptionSpec(long: "help")],
        handler = proc(
            call: tuple[help: bool], effects: var Effects
        ): Result[int, string] =
          ok(0),
      )
    expect AssertionDefect:
      discard initCommand(
        name = "exit",
        summary = "",
        options = @[OptionSpec(long: "hold", short: 'h')],
        handler = proc(
            call: tuple[hold: bool], effects: var Effects
        ): Result[int, string] =
          ok(0),
      )
    expect AssertionDefect:
      discard initCommand(
        name = "bump",
        summary = "",
        options = @[
          OptionSpec(long: "dry-run", short: 'd'), OptionSpec(long: "draft", short: 'd')
        ],
        handler = proc(
            call: tuple[dryRun, draft: bool], effects: var Effects
        ): Result[int, string] =
          ok(0),
      )

suite "version":
  test "version, --version and -v answer with the version":
    for word in ["version", "--version", "-v"]:
      let answer = parsed(word)
      check answer.kind == ikPrint
      check answer.text == "1.2.3"

suite "help":
  test "help, --help and -h answer with the overview":
    for word in ["help", "--help", "-h"]:
      let answer = parsed(word)
      check answer.kind == ikPrint
      check answer.text == Sample.overview()

  test "the overview lists every command, subcommands under their parent":
    let overview = parsed("--help")
    check overview.kind == ikPrint
    check overview.text == Sample.overview()
    check "  tool bump [<package>] [--dry-run] [--stable]\n" in overview.text
    check "  tool track\n  tool track enter <name> [--package <package>]\n" in
      overview.text
    check "  tool secret\n" in overview.text

  test "a command's help wins over its arguments, wherever it stands":
    check parsed("changelog", "--help").kind == ikPrint
    check parsed("changelog", "a", "-h", "b", "c").kind == ikPrint

    let help = parsed("bump", "a", "b", "--help")
    check help.kind == ikPrint
    check help.text.startsWith("Usage:\n  tool bump [<package>] [--dry-run] [--stable]")
    check "  -d, --dry-run  do not write" in help.text
    check "      --stable   go stable" in help.text
    check "  -h, --help     show this help" in help.text

  test "a command's help describes its arguments and subcommands":
    check "Arguments:\n  [<package>]  which package" in parsed("bump", "-h").text
    let track = parsed("track", "-h").text
    check track.startsWith(
      "Usage:\n  tool track\n  tool track enter <name> [--package <package>]\n" &
        "  tool track exit [--package <package>]\n\nReport."
    )
    check "Commands:\n  enter  Enter.\n  exit   Exit." in track

suite "nimver's own flags":
  test "-v, --version and version all print the version":
    let dir = TestRepoRoot / "cli-version"
    createDir(dir)
    let expected = run("nimver version", dir)
    check expected.code == 0
    check run("nimver -v", dir) == expected
    check run("nimver --version", dir) == expected
