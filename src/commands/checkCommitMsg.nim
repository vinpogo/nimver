import ../commitparser
import ../config
import ../result

proc cmdCheckCommitMsg*(repoRoot: string, msgFilePath: string) =
  let raw = readFile(msgFilePath)
  let parseResult = parseCommitMessage(raw)
  if isFailure(parseResult):
    stderr.writeLine("nimver: invalid commit message: " & parseResult.error)
    quit(1)

  let cfg = loadConfig(repoRoot)
  let maybeLevel = validateAndLookup(cfg, parseResult.value)
  if isFailure(maybeLevel):
    stderr.writeLine("nimver: " & maybeLevel.error)
    quit(1)
