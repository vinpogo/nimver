import std/[os]
import ../config
import ../changes

proc cmdInit*(repoRoot: string) =
  createDir(changesDir(repoRoot))
  let cfgPath = configPath(repoRoot)
  if fileExists(cfgPath):
    echo "Config already exists at ", cfgPath
  else:
    writeFile(cfgPath, DefaultConfig)
    echo "Created ", cfgPath
  echo "Run `nimver install-hooks` to wire up the commit-msg hook."
