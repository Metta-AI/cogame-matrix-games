## Reconstruct complete private episodes through the production simulator.
import std/[json, strutils]
import sim_types, sim_config, sim_state, sim, llm, prompts, replays

proc verifyEpisode*(jsonl: string, replay: JsonNode) =
  var records: seq[JsonNode]
  for line in jsonl.splitLines():
    if line.len > 0:
      records.add(parseJson(line))
  let episode = records[^1]
  doAssert episode["event_type"].getStr() == "episode"
  doAssert episode["status"].getStr() == "completed"
  doAssert episode["outcome"] == replay["results"]
  var config = defaultGameConfig()
  let raw = copy(replay["config"])
  raw["seed"] = replay["seed"]
  raw["tokens"] = newJArray()
  for seat in 0 ..< Seats:
    raw["tokens"].add(%("t" & $seat))
  config.update($raw)
  doAssert records.len == config.beats * Seats + 1
  doAssert episode["seed_family"].getStr() == "matrix-games-" & $config.seed
  var game = initSim(config)
  for seat in 0 ..< Seats:
    game.names[seat] = replay["policyNames"][seat].getStr()
  var orders: seq[JsonNode]
  for event in replay["events"]:
    if event["k"].getStr() == "order":
      orders.add(event)
  doAssert orders.len == config.beats * Seats
  for beat in 0 ..< config.beats:
    var decisions = newSeq[Decision](Seats)
    for seat in 0 ..< Seats:
      let index = beat * Seats + seat
      let row = records[index]
      doAssert row["event_type"].getStr() == "decision"
      doAssert row["decision_index"].getInt() == index and row["seat"].getStr() == $seat
      doAssert row["episode_id"] == episode["episode_id"]
      doAssert row["source_revision"] == episode["source_revision"]
      let observation = row["observation"]
      let view = buildObservation(game, seat)
      doAssert observation["view"] == view, "private observation differs from simulator"
      doAssert observation["tick_before"].getInt() == game.tick
      doAssert observation["macro_ticks"].getInt() == config.ticksPerBeat
      doAssert observation["tick_after"].getInt() == game.tick + config.ticksPerBeat
      let metadata = observation["prompt_template"]
      let selection = promptSelection(%*{"promptVariant": metadata["selection"],
        "promptSeed": metadata["seed"]})
      let system = systemPrompt(selection, view)
      let user = userPrompt(view, observation["operator_prompt"].getStr())
      doAssert metadata == selection.promptMetadata(system, user)
      for attempt in row["attempts"]:
        if attempt["policy"].getStr() in ["matrix-prompt", "scripted-counter"]:
          let messages = attempt["prompt"]
          doAssert messages[0] == %*{"role": "system", "content": system}
          doAssert messages[1]["role"].getStr() == "user"
          doAssert messages[1]["content"].getStr() in [user, user & retryHint(view)]
      let action = row["executed_action"]
      let order = parseOrder(action, view)
      doAssert actionJson(order, view) == action
      let event = orders[index]
      doAssert event["seat"].getInt() == seat and event["beat"].getInt() == beat
      decisions[seat] = Decision(order: order,
        source: parseEnum[OrderSource](event["source"].getStr()),
        latencyMs: event["latencyMs"].getInt())
    game.installOrders(decisions)
    game.runBeat()
  game.settleComplete()
  doAssert replayJson(game, resultsJson(game)) == replay,
    "private actions do not reconstruct every public frame, event and outcome"
