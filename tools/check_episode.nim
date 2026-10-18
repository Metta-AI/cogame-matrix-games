## Validate actual private actions against all public replay frames and events.
import std/[os, json]
import matrix_games/qualification
let args = commandLineParams()
doAssert args.len == 2, "usage: check_episode TRAJECTORY_JSONL REPLAY_JSON"
verifyEpisode(readFile(args[0]), parseFile(args[1]))
echo "complete episode rederived"
