## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:matrix-train-bridge tools/train_bridge.nim
## matrix-train-bridge coworld_manifest_template.json [VARIANT]

import std/[json, os]
import matrix_games/[llm, sim, sim_config, sim_state, sim_types]

const OperatorPrompt = "Maximize your own cumulative payoff using only the visible yard and your inventory."
const MaxTokens = 3
const ActionWidth = 2 * MaxTokens + 2 * (Seats - 1) + 1

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(game: Sim, seat, id: int): JsonNode =
  let state = buildObservation(game, seat)
  %*{
    "kind": "decision",
    "game": "matrix-games",
    "decision_id": id,
    "seat": seat,
    "engine_seat": seat,
    "turn": game.beat,
    "semantic_view": state,
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(state)},
      {"role": "user", "content": userPrompt(state, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["intent"]},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, seat, id: int): JsonNode =
  let state = buildObservation(game, seat)
  var values = newJArray()
  for slot in 0 ..< Seats:
    values.add(%(if slot == seat: 1 else: 0))
  for key in ["beat", "beats", "ticksPerBeat", "tick"]:
    values.add(state[key])
  let rules = state["rules"]
  values.add(rules["K"])
  for key in ["rowPay", "colPay"]:
    for row in 0 ..< MaxTokens:
      for col in 0 ..< MaxTokens:
        values.add(if row < rules["K"].getInt() and col < rules["K"].getInt():
          rules[key][row][col] else: %0)
  for key in ["tokenCap", "beamRange", "freezeTicks", "stepCooldownTicks",
      "beamResetCooldown", "beamMissCooldown", "tokenRespawnTicks", "viewRadius"]:
    values.add(rules[key])
  values.add(%(if rules["crossCampOnly"].getBool(): 1 else: 0))
  let me = state["you"]
  for key in ["x", "y", "facing", "scoreCp", "freeze", "beamCd", "interactions", "fixedType"]:
    values.add(me[key])
  for key in ["inv", "mix"]:
    for token in 0 ..< MaxTokens:
      values.add(if token < me[key].len: me[key][token] else: %0)
  for other in state["cogs"]:
    for key in ["x", "y", "dist", "seenTicksAgo", "scoreCp", "interactions"]:
      values.add(other[key])
    for key in ["frozen", "eligible"]:
      values.add(%(if other[key].getBool(): 1 else: 0))
    for token in 0 ..< MaxTokens:
      values.add(if other["inv"].kind == JArray and token < other["inv"].len:
        other["inv"][token] else: %(-1))
  for token in 0 ..< MaxTokens:
    var count = 0
    var nearest = high(int)
    var x = -1
    var y = -1
    if token < state["legal"]["tokens"].len:
      let name = state["legal"]["tokens"][token].getStr()
      for visible in state["visibleTokens"]:
        if visible["token"].getStr() == name:
          inc count
          let dist = max(abs(visible["x"].getInt() - me["x"].getInt()),
            abs(visible["y"].getInt() - me["y"].getInt()))
          if dist < nearest:
            nearest = dist
            x = visible["x"].getInt()
            y = visible["y"].getInt()
    values.add(%count)
    values.add(%x)
    values.add(%y)
  var actions = newJArray()
  for intent in [inGather, inDeny]:
    for name in state["legal"]["tokens"]:
      actions.add(%*{"intent": $intent, "token": name.getStr()})
  for intent in [inHunt, inAvoid]:
    for name in state["legal"]["targets"]:
      actions.add(%*{"intent": $intent, "target": name.getStr()})
  actions.add(%*{"intent": "hold"})
  doAssert actions.len <= ActionWidth
  while actions.len < ActionWidth:
    actions.add(newJNull())
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: matrix-train-bridge MANIFEST [VARIANT]", 1)
  let variant = if args.len == 2: args[1] else: "running-with-scissors"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var seat = 0
  var id = 0
  var decisions = newSeq[Decision](Seats)
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = newJArray()
      for slot in 0 ..< Seats:
        runtimeConfig["tokens"].add(%("t" & $slot))
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      game = initSim(config)
      seat = 0
      id = 0
      decisions = newSeq[Decision](Seats)
      response = game.decision(seat, id)
    of "encode":
      doAssert not game.done
      response = game.encoding(seat, id)
    of "teacher":
      doAssert not game.done
      let state = buildObservation(game, seat)
      let teacher = scriptedDecision(state, skCounter, osScripted)
      let order = teacher.order
      var action = %*{"intent": $order.intent}
      if order.intent in {inGather, inDeny}:
        action["token"] = state["legal"]["tokens"][order.token]
      if order.intent in {inHunt, inAvoid}:
        action["target"] = %aliasOf(order.target)
      response = %*{"response": $action}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let order = parseOrder(action, buildObservation(game, seat))
      decisions[seat] = Decision(order: order, source: osLlm)
      inc seat
      if seat == Seats:
        game.installOrders(decisions)
        game.runBeat()
        seat = 0
        if game.beat == game.config.beats:
          game.settleComplete()
      inc id
      var observation: JsonNode
      if game.done:
        let outcome = resultsJson(game)
        var scores = newJObject()
        for slot in 0 ..< Seats:
          scores[$slot] = outcome["scores"][slot]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(seat, id)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
