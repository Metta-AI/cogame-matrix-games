import std/[json, tables]
import support/worst_case
import matrix_games/[sim_types, replays, global]

let replay = parseReplayBytes(readFile("tests/fixtures/worst_case_text.replay"))
let view = initViewer(replay)
var counts = initCountTable[string]()
for beat in view.beats:
  counts.inc(beat{"k"}.getStr())
echo counts
echo "ticks ", view.tickCount
