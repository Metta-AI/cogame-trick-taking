## Trick-taking entrypoint: reads the Coworld runtime contract and starts
## either a live episode server or a replay viewer server.

import
  std/[json, sysrand],
  bitworld/runtime,
  tricks/server,
  tricks/sim

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(TricksError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  let runtimeConfig = readRuntimeConfig()

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    var config = defaultGameConfig()
    config.update(runtimeConfig.config)
    if not seedPinned(runtimeConfig.config):
      ## An unpinned seed randomizes the deal, the seating permutation and
      ## the aliases, so none of them is precomputable.
      config.seed = randomSeed()
      echo "trick-taking: seed not pinned; randomized"
    ## Fit the budget AFTER the seed is settled, so a pinned seed
    ## reproduces the episode exactly.
    config = sampleEpisode(config)
    echo "trick-taking: module=", config.module,
      " seats=", config.players.len,
      " hands=", config.hands,
      " model=", config.model
    runGameServer(config, runtimeConfig)
