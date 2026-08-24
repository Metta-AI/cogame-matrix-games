## The replay file: strict UTF-8 JSON, one document, protocol
## `matrix.replay.v1`.
##
## Paintbot writes a binary `COWLDCTF` file of INPUTS and re-simulates on
## playback. Matrix Games records STATE instead, so playback never
## re-simulates, a seek is an array index, and there is no native/wasm
## divergence to chase -- which is why this module replaces both
## `src/ctf/replays.nim` and `src/ctf/replay_runtime.nim`.
##
## Replay bytes are SELF-SUFFICIENT: names, policy names, liveries, camps, the
## variant, the whole config including the matrix, the seed, the map, the
## spawner layout, per-tick state, the index summary, every event and the full
## `results` object are all in the file. No server is contacted except S3 for
## the `.replay` file itself.

import std/[json, unicode]
import sim_types, sim_config, matrices, arena_map, sim_state, events, indices,
  sim

proc framesJson*(state: Sim): JsonNode =
  result = newJArray()
  for frame in state.frames:
    result.add(%*{
      "t": frame.t, "c": frame.c, "inv": frame.inv, "tok": frame.tok,
      "sc": frame.sc})

proc spawnersJson*(state: Sim): JsonNode =
  result = newJArray()
  for spawner in state.spawners:
    result.add(%*{"x": spawner.x, "y": spawner.y, "token": spawner.token})

proc seriesJson*(state: Sim): JsonNode =
  var share = newJArray()
  for row in state.shareSeries:
    share.add(%row)
  var score = newJArray()
  for row in state.scoreSeries:
    score.add(%row)
  %*{"share": share, "score": score}

proc replayJson*(state: Sim, results: JsonNode): JsonNode =
  var names = newJArray()
  var policyNames = newJArray()
  var liveries = newJArray()
  var camps = newJArray()
  for slot in 0 ..< state.cogs.len:
    names.add(%aliasOf(slot))
    policyNames.add(%state.names[slot])
    liveries.add(%liveryOf(slot))
    camps.add(%campOf(slot, state.spec.crossCampOnly))
  %*{
    "protocol": ReplayProtocol,
    "game": "matrix-games",
    "gameVersion": GameVersion,
    "variant": state.spec.name,
    "seed": state.config.seed,
    "names": names,
    "policyNames": policyNames,
    "liveries": liveries,
    "camps": camps,
    "config": state.config.configJson(),
    "map": {"w": BoardW, "h": BoardH, "walls": walls()},
    "spawners": spawnersJson(state),
    "frames": framesJson(state),
    "series": seriesJson(state),
    "indices": {
      "conventionCounts": state.idx.conventionJson(),
      "coopRate": state.idx.coopRate(state.spec),
      "exploitabilityCp": state.idx.exploitabilityJson(state.spec)},
    "events": state.events.toJson(),
    "results": results
  }

proc replayBytes*(state: Sim): string =
  $replayJson(state, resultsJson(state))

proc parseReplayBytes*(data: string): JsonNode =
  ## Strict: the bytes must be valid UTF-8 before they are parsed at all,
  ## because a byte-truncated multi-byte character renders in a browser and
  ## only fails later, in a strict parser, on a hosted replay nobody can open.
  if validateUtf8(data) >= 0:
    raise newException(MatrixGamesError,
      "replay bytes are not valid UTF-8 at byte " & $validateUtf8(data))
  let node = parseJson(data)
  if node{"protocol"}.getStr() != ReplayProtocol:
    raise newException(MatrixGamesError,
      "unexpected replay protocol: " & node{"protocol"}.getStr())
  node
