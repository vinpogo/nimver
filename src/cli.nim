## The command line, read against a table of the commands a program has. Help
## and mistakes come back as values: nothing here prints.

import std/[options, sequtils, strutils, tables]
import results
import ./effects

type
  OptionSpec* = object
    long*: string
    short*: char
    hasValue*: bool
    help*: string

  ArgumentSpec* = object
    name*: string
    ## Only after every required argument.
    optional*: bool
    help*: string

  ## What a command does once its command line has been read: the exit code
  ## it ends with, its effects queued but not yet performed.
  Handler =
    proc(invocation: Invocation, effects: var Effects): Result[int, string] {.nimcall.}

  ## Built by `initCommand`.
  CommandSpec* = object
    name: string
    summary: string
    handler: Handler
    options: seq[OptionSpec]
    arguments: seq[ArgumentSpec]
    commands: seq[CommandSpec]

  ## Built by `initCli`.
  Cli* = object
    name: string
    version: string
    header: string
    footer: string
    commands: seq[CommandSpec]

  InvocationKind* = enum
    ikRun
    ## Nothing to run: the text to print, help or the version.
    ikPrint

  Invocation* = object
    case kind*: InvocationKind
    of ikRun:
      handler: Handler
      ## Both by the identifier a handler reads them as, `dryRun` for
      ## `--dry-run`. Flags given are here with an empty value.
      options: Table[string, string]
      arguments: Table[string, string]
    of ikPrint:
      text*: string

const HelpOption = OptionSpec(long: "help", short: 'h', help: "show this help")

proc identifier(name: string): string =
  ## `dryRun` for `dry-run`.
  let parts = name.split('-')
  parts[0] & parts[1 ..^ 1].mapIt(it.capitalizeAscii).join

proc typeName(value: string): string =
  "string"

proc typeName(value: Option[string]): string =
  "Option[string]"

proc typeName(value: bool): string =
  "bool"

proc expectedFields(
    options: seq[OptionSpec], arguments: seq[ArgumentSpec]
): seq[string] =
  ## The fields a handler's tuple must have, as `name: type`.
  for argument in arguments:
    result.add(
      identifier(argument.name) & ": " &
        (if argument.optional: "Option[string]" else: "string")
    )
  for option in options:
    result.add(
      identifier(option.long) & ": " &
        (if option.hasValue: "Option[string]" else: "bool")
    )

proc fieldsOf(T: typedesc[tuple]): seq[string] =
  var call: T
  for fieldName, value in call.fieldPairs:
    result.add(fieldName & ": " & typeName(value))

proc usageOf(option: OptionSpec): string =
  if option.hasValue:
    "--" & option.long & " <" & option.long & ">"
  else:
    "--" & option.long

proc flagsOf(option: OptionSpec): string =
  if option.short == '\0':
    "    " & usageOf(option)
  else:
    "-" & option.short & ", " & usageOf(option)

proc usageOf(argument: ArgumentSpec): string =
  if argument.optional:
    "[<" & argument.name & ">]"
  else:
    "<" & argument.name & ">"

proc synopsis(name: string, command: CommandSpec): string =
  result = name
  for argument in command.arguments:
    result.add(" " & usageOf(argument))
  for option in command.options:
    result.add(" [" & usageOf(option) & "]")

proc synopses(prefix: string, commands: seq[CommandSpec]): seq[string] =
  for command in commands:
    let name = prefix & " " & command.name
    result.add(synopsis(name, command))
    result.add(synopses(name, command.commands))

proc overview*(cli: Cli): string =
  result = cli.header & "\n\nUsage:\n"
  for line in synopses(cli.name, cli.commands):
    result.add("  " & line & "\n")
  result.add("  " & cli.name & " version\n")
  result.add("  " & cli.name & " help\n")
  result.add("\n" & cli.footer)

proc section(title: string, rows: seq[(string, string)]): string =
  let width = rows.mapIt(it[0].len).max()
  result = "\n\n" & title & ":"
  for (key, help) in rows:
    result.add("\n  " & key.alignLeft(width) & "  " & help)

proc helpFor(name: string, command: CommandSpec): string =
  result = "Usage:\n"
  for line in @[synopsis(name, command)] & synopses(name, command.commands):
    result.add("  " & line & "\n")
  result.add("\n" & command.summary)
  if command.commands.len > 0:
    result.add(section("Commands", command.commands.mapIt((it.name, it.summary))))
  if command.arguments.len > 0:
    result.add(section("Arguments", command.arguments.mapIt((usageOf(it), it.help))))
  result.add(
    section("Options", (command.options & HelpOption).mapIt((flagsOf(it), it.help)))
  )

proc initCli*(name, version, header, footer: string, commands: seq[CommandSpec]): Cli =
  Cli(name: name, version: version, header: header, footer: footer, commands: commands)

proc named(commands: seq[CommandSpec], name: string): Option[CommandSpec] =
  for command in commands:
    if command.name == name:
      return some(command)

proc argumentValues(
    name: string, command: CommandSpec, words: seq[string]
): Result[Table[string, string], string] =
  ## Words fill the arguments in order.
  let required = command.arguments.filterIt(not it.optional)
  let most = command.arguments.len
  if words.len notin required.len .. most:
    if most == 0 and command.commands.len > 0:
      return err(
        "unknown command '" & words[0] & "' for `" & name & "`. See `" & name &
          " --help`."
      )
    let expected =
      if required.len == most:
        $most
      else:
        $required.len & " to " & $most
    return err(
      "`" & name & "` expects " & expected &
        (if required.len == 1 and most == 1: " argument" else: " arguments") & ", got " &
        $words.len & ". See `" & name & " --help`."
    )

  var values: Table[string, string]
  for (argument, word) in zip(command.arguments, words):
    values[identifier(argument.name)] = word
  ok(values)

proc resolved(command: CommandSpec, words: seq[string]): (CommandSpec, seq[string]) =
  ## The deepest command below `command` that the leading words name, and the
  ## words left after it.
  if words.len > 0:
    let maybeSub = command.commands.named(words[0])
    if maybeSub.isSome:
      return maybeSub.get.resolved(words[1 ..^ 1])
  (command, words)

proc matching(options: seq[OptionSpec], word: string): Option[OptionSpec] =
  for option in options:
    if word == "--" & option.long or
        (option.short != '\0' and word == "-" & option.short):
      return some(option)

proc missingValue(option: OptionSpec): string =
  "`--" & option.long & "` needs a <" & option.long & ">"

proc optionsGiven(
    name: string, command: CommandSpec, words: seq[string]
): Result[(Table[string, string], seq[string]), string] =
  ## The options among `words`, by identifier, and the words left over for
  ## the arguments.
  var options: Table[string, string]
  var argumentWords: seq[string]
  var maybeAwaiting = none(OptionSpec)
  for word in words:
    if maybeAwaiting.isSome:
      if word.len == 0:
        return err(missingValue(maybeAwaiting.get))
      options[identifier(maybeAwaiting.get.long)] = word
      maybeAwaiting = none(OptionSpec)
    elif not word.startsWith("-") or word == "-":
      argumentWords.add(word)
    else:
      let maybeOption = (command.options & HelpOption).matching(word)
      if maybeOption.isNone:
        return err("unknown option '" & word & "' for `" & name & "`")
      let option = maybeOption.get
      if not option.hasValue:
        options[identifier(option.long)] = ""
      else:
        maybeAwaiting = some(option)
  if maybeAwaiting.isSome:
    return err(missingValue(maybeAwaiting.get))
  ok((options, argumentWords))

proc parse*(cli: Cli, args: seq[string]): Result[Invocation, string] =
  ## Help and the version asked for are a success; a command line that names
  ## no command is a failure that carries the overview.
  if args.len == 0:
    return err("no command given\n\n" & cli.overview())
  if args[0] in ["help", "--help", "-h"]:
    return ok(Invocation(kind: ikPrint, text: cli.overview()))
  if args[0] in ["version", "--version", "-v"]:
    return ok(Invocation(kind: ikPrint, text: cli.version))

  let (command, rest) = CommandSpec(commands: cli.commands).resolved(args)
  if rest.len == args.len:
    return err("unknown command '" & args[0] & "'\n\n" & cli.overview())
  let name = (@[cli.name] & args[0 ..< args.len - rest.len]).join(" ")

  let (options, argumentWords) = ?optionsGiven(name, command, rest)
  if "help" in options:
    return ok(Invocation(kind: ikPrint, text: helpFor(name, command)))
  let arguments = ?argumentValues(name, command, argumentWords)
  ok(
    Invocation(
      kind: ikRun, handler: command.handler, options: options, arguments: arguments
    )
  )

proc to*[T: tuple](invocation: Invocation, _: typedesc[T]): T =
  ## The command line read into `T`, field by field: a required argument as a
  ## `string`, an optional one or an option that takes a value as an
  ## `Option[string]`, a flag as a `bool`.
  for name, value in result.fieldPairs:
    when value is bool:
      value = name in invocation.options
    elif value is string:
      value = invocation.arguments.getOrDefault(name)
    else:
      if name in invocation.arguments:
        value = some(invocation.arguments[name])
      elif name in invocation.options:
        value = some(invocation.options[name])

proc commandFor(
    name, summary: string,
    handler: Handler,
    fields: seq[string],
    options: seq[OptionSpec],
    arguments: seq[ArgumentSpec],
    commands: seq[CommandSpec],
): CommandSpec =
  let required = arguments.filterIt(not it.optional)
  doAssert arguments[0 ..< required.len] == required,
    "`" & name & "` declares a required argument after an optional one"
  let names =
    arguments.mapIt(identifier(it.name)) &
    (options & HelpOption).mapIt(identifier(it.long))
  doAssert names.deduplicate.len == names.len,
    "`" & name & "` declares a name twice, or one of its own called help"
  let shorts = (options & HelpOption).filterIt(it.short != '\0').mapIt(it.short)
  doAssert shorts.deduplicate.len == shorts.len,
    "`" & name & "` declares a short option twice, or one of its own called -h"
  let expected = expectedFields(options, arguments)
  for field in fields:
    doAssert field in expected,
      "`" & name & "` declares nothing its handler can read as `" & field & "`"
  for field in expected:
    doAssert field in fields,
      "the handler of `" & name & "` does not read `" & field & "`"
  CommandSpec(
    name: name,
    summary: summary,
    handler: handler,
    options: options,
    arguments: arguments,
    commands: commands,
  )

template initCommand*[T: tuple](
    name, summary: string,
    options: seq[OptionSpec] = @[],
    arguments: seq[ArgumentSpec] = @[],
    commands: seq[CommandSpec] = @[],
    handler: proc(call: T, effects: var Effects): Result[int, string],
): CommandSpec =
  ## `handler` takes the command line read into a tuple of the command's
  ## arguments and options by name. A tuple that does not match them, or a
  ## table that could not be read unambiguously, is a defect: a `const` table
  ## with one does not build. A template rather than a generic proc, so that
  ## two handlers taking the same tuple stay two handlers.
  block:
    const call = handler
    proc run(
        invocation: Invocation, effects: var Effects
    ): Result[int, string] {.gensym, nimcall.} =
      call(invocation.to(T), effects)

    commandFor(name, summary, run, fieldsOf(T), options, arguments, commands)

proc handle*(invocation: Invocation, effects: var Effects): Result[int, string] =
  invocation.handler(invocation, effects)
