## The five scripted baselines.
##
## ALL FIVE run against the same `buildObservation(slot)` object an LLM seat
## receives -- never raw sim state. That is what makes a baseline a
## legitimate policy rather than an oracle, and `tests/test_baseline.nim`
## asserts it by handing them a frozen observation with no `Sim` in scope.
##
## Each returns exactly one intent per beat. `counter` is also the FALLBACK
## move used whenever an LLM seat's decision fails, and the baseline the
## offline certification fixture leans on, because it is the strongest of the
## five and guarantees interactions happen.

import std/[json]
import sim_types

type
  Baseline* = object
    ## The small view of an observation the baselines share.
    k*: int
    tokens*: seq[string]
    bestResponseRow*: seq[int]
    bestResponseCol*: seq[int]
    crossCampOnly*: bool
    rowSide*: bool           ## false only for a column-camp cog in BoS
    inv*: seq[int]
    fixedType*: int
    eligible*: seq[int]      ## slots, ascending
    dist*: seq[int]          ## by slot; high(int) for an unknown cog
    lastSeen*: seq[int]      ## by slot: the argmax token it last showed

proc intList(node: JsonNode): seq[int] =
  if node == nil or node.kind != JArray:
    return @[]
  for value in node:
    result.add(value.getInt())

proc strList(node: JsonNode): seq[string] =
  if node == nil or node.kind != JArray:
    return @[]
  for value in node:
    result.add(value.getStr())

proc readBaseline*(obs: JsonNode): Baseline =
  ## Projects the observation JSON onto the fields the baselines use. Any
  ## missing field degrades to a safe default rather than raising: a baseline
  ## that throws is a seat that does not play.
  let rules = obs{"rules"}
  result.k = max(2, rules{"K"}.getInt(2))
  result.tokens = strList(rules{"tokens"})
  result.bestResponseRow = intList(rules{"bestResponseRow"})
  result.bestResponseCol = intList(rules{"bestResponseCol"})
  while result.bestResponseRow.len < result.k:
    result.bestResponseRow.add(0)
  while result.bestResponseCol.len < result.k:
    result.bestResponseCol.add(0)
  result.crossCampOnly = rules{"crossCampOnly"}.getBool(false)
  result.rowSide = not (result.crossCampOnly and
    obs{"camp"}.getStr() == "column")
  result.inv = intList(obs{"you"}{"inv"})
  if result.inv.len == 0:
    result.inv = newSeq[int](result.k)
  result.fixedType = obs{"you"}{"fixedType"}.getInt(0)
  result.dist = newSeq[int](Seats)
  result.lastSeen = newSeq[int](Seats)
  for slot in 0 ..< Seats:
    result.dist[slot] = high(int)
  let mySlot = obs{"slot"}.getInt(0)
  let cogs = obs{"cogs"}
  if cogs != nil and cogs.kind == JArray:
    for entry in cogs:
      let slot = slotOfAlias(entry{"alias"}.getStr())
      if slot < 0 or slot == mySlot:
        continue
      result.dist[slot] = entry{"dist"}.getInt(high(int))
      if entry{"eligible"}.getBool(true):
        result.eligible.add(slot)
  ## `lastSeen[alias]` -- the argmax token of that cog's mix at the MOST
  ## RECENT resolution in the public log involving it, either side. Defaults
  ## to token 0.
  let log = obs{"log"}
  if log != nil and log.kind == JArray:
    for entry in log:
      for side in ["row", "col"]:
        let slot = slotOfAlias(entry{side}.getStr())
        if slot < 0:
          continue
        let mixValues = intList(entry{(if side == "row": "rowMix"
                                       else: "colMix")})
        if mixValues.len > 0:
          result.lastSeen[slot] = argmaxLowest(mixValues)

proc nearestEligible*(view: Baseline): int =
  ## The eligible cog with the smallest Chebyshev distance using its last
  ## known cell; ties go to the lowest slot.
  result = -1
  var best = high(int)
  for slot in view.eligible:
    if view.dist[slot] < best:
      best = view.dist[slot]
      result = slot

proc commit*(view: Baseline, token: int): IntentOrder =
  ## Buy the token until `commitTarget`, then go looking for a fight.
  let want = clamp(token, 0, max(0, view.k - 1))
  if want < view.inv.len and view.inv[want] < CommitTarget:
    return IntentOrder(intent: inGather, token: want, target: -1)
  let target = view.nearestEligible()
  if target >= 0:
    return IntentOrder(intent: inHunt, token: -1, target: target)
  IntentOrder(intent: inHold, token: -1, target: -1)

proc scriptedOrder*(obs: JsonNode, kind: ScriptKind): IntentOrder =
  let view = readBaseline(obs)
  case kind
  of skAlwaysFirst:
    view.commit(0)
  of skAlwaysSecond:
    view.commit(min(1, view.k - 1))
  of skFixedPick:
    view.commit(view.fixedType)
  of skTitForTat:
    let target = view.nearestEligible()
    if target < 0:
      return view.commit(0)
    var order = view.commit(view.lastSeen[target])
    if order.intent == inHunt:
      order.target = target
    order
  of skCounter, skNone:
    let target = view.nearestEligible()
    if target < 0:
      return view.commit(0)
    let showed = view.lastSeen[target]
    let want =
      if view.rowSide: view.bestResponseRow[showed]
      else: view.bestResponseCol[showed]
    var order = view.commit(want)
    if order.intent == inHunt:
      order.target = target
    order

proc scriptedSay*(kind: ScriptKind): string =
  ## Scripted seats do talk -- `say` is spectator-only, and a silent baseline
  ## makes the feed look broken next to an LLM seat.
  case kind
  of skCounter, skNone: "reading the room"
  of skTitForTat: "mirroring what you showed me"
  of skFixedPick: "sticking to my pick"
  of skAlwaysFirst: "first token, every time"
  of skAlwaysSecond: "second token, every time"
