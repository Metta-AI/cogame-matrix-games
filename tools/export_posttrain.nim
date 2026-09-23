## Export complete Matrix Games episodes as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import matrix_games/[sim_types, sim_config, sim_state, sim, llm]

const OperatorPrompt = "Maximize your own cumulative payoff using only the visible yard and your inventory."
const Variants = ["running-with-scissors", "prisoners-dilemma", "chicken",
  "stag-hunt", "bach-or-stravinsky", "pure-coordination",
  "rationalizable-coordination"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for slot in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $slot))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    var game = initSim(config)
    var rows: seq[string]
    for beat in 0 ..< config.beats:
      var decisions = newSeq[Decision](Seats)
      for slot in 0 ..< Seats:
        let obs = buildObservation(game, slot)
        let teacher = scriptedDecision(obs, skCounter, osScripted)
        let order = teacher.order
        var completion = %*{
          "intent": $order.intent, "say": order.say, "notes": order.notes
        }
        if order.intent in {inGather, inDeny}:
          completion["token"] = obs["legal"]["tokens"][order.token]
        if order.intent in {inHunt, inAvoid}:
          completion["target"] = %aliasOf(order.target)
        let parsed = parseOrder(completion, obs)
        doAssert parsed == order
        decisions[slot] = Decision(order: parsed, source: osScripted)
        rows.add($(%*{
          "episode_id": "matrix-games-" & variant & "-" & $seed,
          "seed": "matrix-games-" & variant & "-" & $seed,
          "decision_id": beat * Seats + slot,
          "prompt": [
            {"role": "system", "content": systemPrompt(obs)},
            {"role": "user", "content": userPrompt(obs, OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "matrix-games",
          "action_schema_revision": "matrix-games-order-v1"
        }))
      game.installOrders(decisions)
      game.runBeat()
    game.settleComplete()
    let outcome = resultsJson(game)
    doAssert outcome["reason"].getStr() == "complete"
    doAssert rows.len == config.beats * Seats
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "ticks": outcome["ticks"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "matrix-games",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-counter",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
