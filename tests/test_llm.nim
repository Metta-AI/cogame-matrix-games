## The decision layer: tolerant extraction, strict validation, one retry, then
## the `counter` fallback -- and the batching contract.
##
## The transport is replaced by `LlmClient.batchHook`, so a timeout, a 429, a
## 403 and outright junk are all exercised without a network. What the hook
## also proves is the shape of the call: ONE batch carrying EVERY open seat,
## never a loop of single calls, with consecutive batches spaced by at least
## `minBeatSeconds`.

import std/[json, strutils, unicode, unittest]
import support/helpers
import matrix_games/[sim_types, sim_config, matrices, sim_state, sim,
  scripted, llm]

proc observationSet(): seq[JsonNode] =
  var state = initSim(testConfig("prisoners-dilemma", 41))
  state.runBeat()
  for slot in 0 ..< Seats:
    result.add(buildObservation(state, slot))

suite "reply extraction":
  test "fenced, prose-prefixed and trailing-prose replies all parse":
    check extractJsonObject("```json\n{\"intent\":\"hold\"}\n```"){
      "intent"}.getStr() == "hold"
    check extractJsonObject(
      "Sure, here is my move: {\"intent\":\"hold\"} -- hope that helps."){
      "intent"}.getStr() == "hold"
    check extractJsonObject("{\"intent\":\"hold\"}\nI held."){
      "intent"}.getStr() == "hold"
    expect MatrixGamesError:
      discard extractJsonObject("I decline to answer.")

  test "the echoed head of a prose reply is cut on runes, not bytes":
    ## This branch fires precisely on a prose preamble, which is where the
    ## multi-byte characters are: a byte slice at 160 lands mid-rune and puts
    ## invalid UTF-8 into the message (the bullwhip bug).
    try:
      discard extractJsonObject(repeat("\u4e2d", 300) & " sorry, no object")
      check false
    except MatrixGamesError as error:
      check validateUtf8(error.msg) == -1
      check error.msg.runeLen <= 200

suite "reply validation":
  setup:
    let observations = observationSet()
    let obs = observations[0]

  test "token names are case-insensitive and an integer index is accepted":
    check parseOrder(%*{"intent": "gather", "token": "DEFECT"}, obs).token == 1
    check parseOrder(%*{"intent": "gather", "token": "cooperate"},
      obs).token == 0
    check parseOrder(%*{"intent": "deny", "token": 1}, obs).token == 1

  test "target aliases are case-insensitive and resolve to slots":
    let order = parseOrder(%*{"intent": "hunt", "target": "fErN"}, obs)
    check order.target == slotOfAlias("Fern")
    check order.token == -1

  test "an unknown intent, a missing token or a bad target is invalid":
    expect MatrixGamesError:
      discard parseOrder(%*{"intent": "sprint"}, obs)
    expect MatrixGamesError:
      discard parseOrder(%*{"intent": "gather"}, obs)
    expect MatrixGamesError:
      discard parseOrder(%*{"intent": "gather", "token": "gold"}, obs)
    expect MatrixGamesError:
      discard parseOrder(%*{"intent": "hunt"}, obs)
    expect MatrixGamesError:
      discard parseOrder(%*{"intent": "hunt", "target": "Ash"}, obs)
    expect MatrixGamesError:
      discard parseOrder(%*{"intent": "avoid", "target": "Nobody"}, obs)

  test "say and notes are rune-truncated at parse time":
    let order = parseOrder(%*{
      "intent": "hold", "say": repeat("\u4e2d", 200),
      "notes": repeat("\u4e2d", 900)}, obs)
    check order.say.runeLen <= MaxSayRunes
    check order.notes.runeLen <= MaxNotesRunes
    check validateUtf8(order.say) == -1
    check validateUtf8(order.notes) == -1

  test "the legal lists in the prompt are the ones the validator applies":
    var tokens: seq[string]
    for name in obs{"legal"}{"tokens"}:
      tokens.add(name.getStr())
    let user = userPrompt(obs, "operator guidance here")
    for name in tokens:
      check name in user
    for name in obs{"legal"}{"targets"}:
      check name.getStr() in user
    check "operator guidance here" in user
    check "begin with the character {" in systemPrompt(obs)

suite "the batch contract":
  test "one batch carries every open seat, and batches are paced":
    var config = testConfig("prisoners-dilemma", 42)
    config.minBeatSeconds = 1
    let observations = observationSet()
    var sizes: seq[int]
    let client = newStubClient(config, proc (system: seq[string],
        user: seq[string], timeout: int): seq[BatchReply] {.closure.} =
      check system.len == user.len
      sizes.add(system.len)
      for _ in 0 ..< system.len:
        result.add(BatchReply(text: "{\"intent\":\"hold\",\"say\":\"ok\"}")))
    let decisions = client.decideAll(observations, newSeq[string](Seats),
      newSeq[ScriptKind](Seats))
    check sizes == @[Seats]
    check client.batchSizes == @[Seats]
    for decision in decisions:
      check decision.source == osLlm
      check decision.order.intent == inHold
    ## A second batch must not start inside minBeatSeconds of the first.
    discard client.decideAll(observations, newSeq[string](Seats),
      newSeq[ScriptKind](Seats))
    check client.batchStarts.len == 2
    check client.batchStarts[1] - client.batchStarts[0] >=
      config.minBeatSeconds.float - 0.05

  test "scripted seats never enter the batch":
    var config = testConfig("prisoners-dilemma", 43)
    config.minBeatSeconds = 0
    let observations = observationSet()
    var sizes: seq[int]
    let client = newStubClient(config, proc (system: seq[string],
        user: seq[string], timeout: int): seq[BatchReply] {.closure.} =
      sizes.add(system.len)
      for _ in 0 ..< system.len:
        result.add(BatchReply(text: "{\"intent\":\"hold\"}")))
    var kinds = newSeq[ScriptKind](Seats)
    kinds[0] = skCounter
    kinds[1] = skAlwaysFirst
    let decisions = client.decideAll(observations, newSeq[string](Seats),
      kinds)
    check sizes == @[Seats - 2]
    check decisions[0].source == osScripted
    check decisions[1].source == osScripted
    check decisions[2].source == osLlm

suite "degrade, never hang":
  test "an invalid reply is retried ONCE, then falls back to counter":
    var config = testConfig("prisoners-dilemma", 44)
    config.minBeatSeconds = 0
    let observations = observationSet()
    var attempts = 0
    let client = newStubClient(config, proc (system: seq[string],
        user: seq[string], timeout: int): seq[BatchReply] {.closure.} =
      attempts.inc
      if attempts == 2:
        check "previous reply was invalid" in user[0]
      for _ in 0 ..< system.len:
        result.add(BatchReply(text: "{\"intent\":\"teleport\"}")))
    let decisions = client.decideAll(observations, newSeq[string](Seats),
      newSeq[ScriptKind](Seats))
    check attempts == 2
    for decision in decisions:
      check decision.source == osFallback
      check decision.order.intent in {inGather, inDeny, inHunt, inAvoid,
        inHold}

  test "a retry that succeeds is recorded as a retry, not a fallback":
    var config = testConfig("prisoners-dilemma", 45)
    config.minBeatSeconds = 0
    let observations = observationSet()
    var attempts = 0
    let client = newStubClient(config, proc (system: seq[string],
        user: seq[string], timeout: int): seq[BatchReply] {.closure.} =
      attempts.inc
      for _ in 0 ..< system.len:
        if attempts == 1:
          result.add(BatchReply(text: "no json here"))
        else:
          result.add(BatchReply(text: "{\"intent\":\"hold\"}")))
    let decisions = client.decideAll(observations, newSeq[string](Seats),
      newSeq[ScriptKind](Seats))
    for decision in decisions:
      check decision.source == osRetry

  test "timeouts, 429s, 403s and junk never raise and always yield an order":
    var config = testConfig("prisoners-dilemma", 46)
    config.minBeatSeconds = 0
    let observations = observationSet()
    let failures = @[
      BatchReply(error: "llm transport: Timeout was reached"),
      BatchReply(error: "llm throttled (429): slow down"),
      BatchReply(error: "llm auth failed (403) at https://x: denied"),
      BatchReply(text: "\u4e2d\u4e2d\u4e2d not json at all"),
      BatchReply(text: "{"),
      BatchReply(text: "{\"intent\":\"hunt\",\"target\":\"Ghost\"}"),
      BatchReply(text: "{\"intent\":\"gather\"}"),
      BatchReply(text: "[]")
    ]
    let client = newStubClient(config, proc (system: seq[string],
        user: seq[string], timeout: int): seq[BatchReply] {.closure.} =
      for index in 0 ..< system.len:
        result.add(failures[index mod failures.len]))
    let decisions = client.decideAll(observations, newSeq[string](Seats),
      newSeq[ScriptKind](Seats))
    check decisions.len == Seats
    for slot in 0 ..< Seats:
      check decisions[slot].source == osFallback
      let order = decisions[slot].order
      check order.intent in {inGather, inDeny, inHunt, inAvoid, inHold}
      if order.intent in {inGather, inDeny}:
        check order.token >= 0
      if order.intent in {inHunt, inAvoid}:
        check order.target >= 0
        check order.target != slot

  test "a client with no credentials disables itself and plays counter":
    var config = testConfig("prisoners-dilemma", 47)
    let observations = observationSet()
    var client = newStubClient(config, nil)
    client.disabled = true
    let decisions = client.decideAll(observations, newSeq[string](Seats),
      newSeq[ScriptKind](Seats))
    check client.batchSizes.len == 0
    for decision in decisions:
      check decision.source == osFallback
