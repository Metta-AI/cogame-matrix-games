## Bounded orders and legality, for all five baselines x all seven variants x
## seeds 1..8, every seat scripted.
##
## The load-bearing assertion is the LAST one: a baseline reads
## `buildObservation(slot)` and NOTHING else. It is checked by handing the
## baselines a frozen observation object with no `Sim` anywhere in scope --
## the same object an LLM seat receives -- and requiring a legal order back.

import std/[json, times, unittest]
import support/helpers
import matrix_games/[sim_types, sim_config, matrices, arena_map, sim_state,
  scripted, sim, indices, llm]

const AllKinds = [skCounter, skTitForTat, skFixedPick, skAlwaysFirst,
  skAlwaysSecond]

proc checkOrder(order: IntentOrder, obs: JsonNode, slot: int) =
  let k = obs{"rules"}{"K"}.getInt()
  check order.intent in {inGather, inDeny, inHunt, inAvoid, inHold}
  if order.intent in {inGather, inDeny}:
    check order.token >= 0
    check order.token < k
  else:
    check order.token == -1
  if order.intent in {inHunt, inAvoid}:
    check order.target >= 0
    check order.target < Seats
    check order.target != slot
    var eligible = false
    for name in obs{"legal"}{"targets"}:
      if slotOfAlias(name.getStr()) == order.target:
        eligible = true
    check eligible
  else:
    check order.target == -1

suite "scripted baselines":
  test "every baseline emits a bounded, legal order in every variant":
    for matrix in MatrixNames:
      for kind in AllKinds:
        for seed in 1 .. 8:
          var state = initSim(testConfig(matrix, seed, beats = 3))
          for beat in 0 ..< state.config.beats:
            var decisions = newSeq[Decision](Seats)
            for slot in 0 ..< Seats:
              let obs = buildObservation(state, slot)
              let order = scriptedOrder(obs, kind)
              checkOrder(order, obs, slot)
              decisions[slot] = Decision(order: order, source: osScripted)
            state.installOrders(decisions)
            state.runBeat()

  test "no cog ever occupies a wall cell or shares one, inv stays in range":
    for matrix in MatrixNames:
      for kind in AllKinds:
        let state = runScripted(matrix, 3, uniform(kind), beats = 4)
        for frame in state.frames:
          for slot in 0 ..< Seats:
            check isFloor(frame.c[slot * 4], frame.c[slot * 4 + 1])
            for other in slot + 1 ..< Seats:
              check not (frame.c[slot * 4] == frame.c[other * 4] and
                         frame.c[slot * 4 + 1] == frame.c[other * 4 + 1])
          for value in frame.inv:
            check value >= 0
            check value <= state.config.tokenCap

  test "a baseline reads ONLY the observation object, and never raises":
    ## The observation is captured once and the Sim goes out of scope: what is
    ## left is exactly what an LLM seat is sent.
    var frozen: seq[JsonNode]
    block:
      var state = initSim(testConfig("running-with-scissors", 77))
      state.runBeat()
      for slot in 0 ..< Seats:
        frozen.add(buildObservation(state, slot))
    for kind in AllKinds:
      for slot in 0 ..< Seats:
        let order = scriptedOrder(frozen[slot], kind)
        checkOrder(order, frozen[slot], slot)

  test "an observation with fields missing degrades instead of raising":
    ## A baseline that throws is a seat that does not play.
    for kind in AllKinds:
      let order = scriptedOrder(%*{}, kind)
      check order.intent in {inGather, inDeny, inHunt, inAvoid, inHold}

  test "no baseline takes longer than 1 ms per beat":
    var frozen: seq[JsonNode]
    block:
      var state = initSim(testConfig("prisoners-dilemma", 5))
      for _ in 0 ..< 4:
        var decisions = newSeq[Decision](Seats)
        for slot in 0 ..< Seats:
          decisions[slot] = scriptedDecision(buildObservation(state, slot),
            skCounter, osScripted)
        state.installOrders(decisions)
        state.runBeat()
      for slot in 0 ..< Seats:
        frozen.add(buildObservation(state, slot))
    for kind in AllKinds:
      let started = epochTime()
      for _ in 0 ..< 100:
        for slot in 0 ..< Seats:
          discard scriptedOrder(frozen[slot], kind)
      let perBeatMs = (epochTime() - started) * 1000.0 / 100.0
      check perBeatMs < 1.0
