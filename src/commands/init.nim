import std/[os]
import ../config

proc cmdInit*(repoRoot: string) =
  let cfgPath = configPath(repoRoot)
  if fileExists(cfgPath):
    echo "Config already exists at ", cfgPath
  else:
    createDir(cfgPath.parentDir())
    writeFile(cfgPath, DefaultConfig)
    echo "Created ", cfgPath
  echo "Run `nimver install-hooks` to wire up the commit-msg hook."
