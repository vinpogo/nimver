import ../sysio
import ../effects
import results
import ../config

proc cmdInit*(repoRoot: string, effects: var Effects): Result[void, string] =
  let cfgPath = configPath(repoRoot)
  if fileAt(cfgPath):
    effects.add(say("Config already exists at " & cfgPath))
  else:
    effects.add(createDirectory(cfgPath.parentDir()))
    effects.add(writeTo(cfgPath, DefaultConfig))
    effects.add(say("Created " & cfgPath))
  effects.add(say("Run `nimver install-hooks` to wire up the commit-msg hook."))
  ok()
