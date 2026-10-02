## Export complete Matrix Games episodes as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, options, os, osproc, posix, strutils]
import bitworld/decision_trajectory
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
  doAssert execProcess("git status --porcelain").strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  discard umask(Mode(0o077))
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
    let episodeId = "matrix-games-" & variant & "-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, "matrix-games-" & $seed, "matrix-games",
      "source-" & sourceRevision[0 .. 11], sourceRevision)
    for beat in 0 ..< config.beats:
      var decisions = newSeq[Decision](Seats)
      var observations = newSeq[JsonNode](Seats)
      var attempts: seq[DecisionAttempt]
      for slot in 0 ..< Seats:
        let obs = buildObservation(game, slot)
        observations[slot] = obs
        let teacher = scriptedDecision(obs, skCounter, osScripted)
        let order = teacher.order
        let completion = actionJson(order, obs)
        let parsed = parseOrder(extractJsonObject($completion), obs)
        doAssert parsed == order
        decisions[slot] = Decision(order: parsed, source: osScripted)
        var attempt = newDecisionAttempt("teacher", "scripted-counter", aoTeacher)
        attempt.prompt = %*[{"role": "system", "content": systemPrompt(obs)},
          {"role": "user", "content": userPrompt(obs, OperatorPrompt)}]
        attempt.response = %($completion)
        attempt.parsedAction = actionJson(parsed, obs)
        attempt.accepted = true
        attempts.add(attempt)
        rows.add($(%*{
          "episode_id": "matrix-games-" & variant & "-" & $seed,
          "seed": "matrix-games-" & $seed,
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
      if game.beat == config.beats:
        game.settleComplete()
      for slot in 0 ..< Seats:
        trajectory.recordDecision($ (beat * Seats + slot), $slot,
          %*{"view": observations[slot], "macro_ticks": config.ticksPerBeat,
            "tick_before": beat * config.ticksPerBeat, "tick_after": game.tick},
          @[attempts[slot]], some("teacher"), actionJson(game.orders[slot], observations[slot]),
          asAccepted, terminal = game.done)
    game.settleComplete()
    let outcome = resultsJson(game)
    doAssert outcome["reason"].getStr() == "complete"
    trajectory.finish(esCompleted, outcome, outcome["scores"])
    trajectory.writeCompleteEpisode(output / (episodeId & ".jsonl"))
    doAssert rows.len == config.beats * Seats
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"episode_id": episodeId, "seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "ticks": outcome["ticks"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "format": "coworld-private-complete-episodes-v1",
    "sft_format": "metta-posttraining-example-v1",
    "game": "matrix-games",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-counter",
    "target_policy": "scripted-counter",
    "review_status": "unreviewed",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
