import std/[json, strformat]
import std/tables
import support/helpers
import matrix_games/[sim_types, matrices, sim_state, sim, replays, global]

for matrix in ["prisoners-dilemma", "chicken", "rationalizable-coordination"]:
  for seed in 1 .. 12:
    let state = runScripted(matrix, seed, @[skAlwaysFirst, skAlwaysSecond,
      skCounter, skTitForTat, skAlwaysSecond, skAlwaysFirst, skFixedPick,
      skCounter], beats = 6)
    let replay = parseReplayBytes(replayBytes(state))
    let view = initViewer(replay)
    var kinds: seq[string]
    var counts = {"interact": 0, "bigpay": 0, "leadchange": 0, "over": 0}.toTable
    for beat in view.beats:
      let k = beat{"k"}.getStr()
      if counts.hasKey(k): counts[k].inc
    echo &"{matrix} seed={seed} interact={counts[\"interact\"]} bigpay={counts[\"bigpay\"]} lead={counts[\"leadchange\"]} over={counts[\"over\"]} ticks={state.tick}"
