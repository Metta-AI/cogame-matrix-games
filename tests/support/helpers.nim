## Shared test helpers. NOT a test: it lives under `tests/support/` so the
## `tests/*.nim` glob CI runs never executes it on its own.

import std/[json]
import matrix_games/[sim_types, sim_config, matrices, sim_state, sim,
  scripted, llm]

proc testConfig*(matrix: string, seed: int, beats = BeatsDefault): GameConfig =
  result = defaultGameConfig()
  result.matrix = matrix
  result.seed = seed
  result.beats = beats
  result.players = @[]
  result.tokens = @[]
  for slot in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "policy-" & $slot))
    result.tokens.add("token-" & $slot)
  result.validate()

proc runScripted*(matrix: string, seed: int, kinds: seq[ScriptKind],
    beats = BeatsDefault): Sim =
  ## A full headless episode with every seat on a scripted baseline. This is
  ## the cert seat mix, and the harness every feasibility gate uses.
  var state = initSim(testConfig(matrix, seed, beats))
  for slot in 0 ..< Seats:
    state.names[slot] = "matrix-games-" & $kinds[slot]
    state.policyKinds[slot] = "scripted"
  for beat in 0 ..< state.config.beats:
    var decisions = newSeq[Decision](Seats)
    for slot in 0 ..< Seats:
      decisions[slot] = scriptedDecision(buildObservation(state, slot),
        kinds[slot], osScripted)
    state.installOrders(decisions)
    state.runBeat()
  state.finish("complete", "full_match")
  state

proc uniform*(kind: ScriptKind): seq[ScriptKind] =
  for _ in 0 ..< Seats:
    result.add(kind)

proc certMix*(): seq[ScriptKind] =
  ## The certification fixture's seat mix: `matrix-games-player` has no
  ## credentials offline and plays `counter`, then the five declared
  ## baselines, then two more.
  @[skCounter, skCounter, skTitForTat, skFixedPick, skAlwaysFirst,
    skAlwaysSecond, skCounter, skTitForTat]

proc meanScore*(state: Sim): float =
  var total = 0.0
  for value in state.scores():
    total += value
  total / Seats.float
