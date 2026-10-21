import ../effects

const NimblePkgVersion {.strdefine.} = "unknown"

proc cmdVersion*(): Effects =
  @[say(NimblePkgVersion)]
