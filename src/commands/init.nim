import ../sysio
import ../config

proc cmdInit*(repoRoot: string) =
  let cfgPath = configPath(repoRoot)
  if fileAt(cfgPath):
    echo "Config already exists at ", cfgPath
  else:
    makeDirectory(cfgPath.parentDir())
    writeFileContents(cfgPath, DefaultConfig)
    echo "Created ", cfgPath
  echo "Run `nimver install-hooks` to wire up the commit-msg hook."
