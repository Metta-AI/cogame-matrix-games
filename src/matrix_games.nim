## Matrix Games entrypoint: reads the Coworld runtime contract and starts
## either a live episode server or a replay viewer server.
##
## Seed randomisation happens HERE, BEFORE `config.update` honours a pinned
## seed, so every seed-derived draw -- the spawner layout and `fixed-pick`'s
## type -- follows the FINAL seed. That is paintbot's rule (`src/ctf.nim`) and
## it is the reason a replay reproduces bit-exactly.

import std/[json, strutils, sysrand]
import bitworld/runtime
import matrix_games/sim_types
import matrix_games/sim_config
import matrix_games/server

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(MatrixGamesError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configText: string): bool =
  if configText.strip().len == 0:
    return false
  try:
    let node = parseJson(configText)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("matrix-games: bad runtime configuration: " & error.msg, 2)

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    if runtimeConfig.config.strip().len == 0:
      quit("matrix-games: COGAME_CONFIG_URI is required " &
        "(no game config was given)", 2)
    var config = defaultGameConfig()
    try:
      config.update(runtimeConfig.config)
    except CatchableError as error:
      quit("matrix-games: invalid game config: " & error.msg, 2)
    if not seedPinned(runtimeConfig.config):
      config.seed = randomSeed()
      echo "matrix-games: seed not pinned; randomized to ", config.seed
    if config.tokens.len == 0:
      quit("matrix-games: the game config must carry one token per seat", 2)
    if config.players.len != config.numAgents:
      quit("matrix-games: the game config must name " & $config.numAgents &
        " players", 2)
    echo "matrix-games: seats=", config.numAgents,
      " matrix=", config.matrix,
      " beats=", config.beats,
      " ticksPerBeat=", config.ticksPerBeat,
      " model=", config.model
    try:
      runGameServer(config, runtimeConfig)
    except CatchableError as error:
      quit("matrix-games: " & error.msg, 2)
