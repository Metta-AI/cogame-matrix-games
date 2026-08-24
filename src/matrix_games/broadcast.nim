## The two spectator views.
##
## Fork of paintbot's `src/ctf/broadcast.nim`: `BroadcastTracker` keeps the
## once-per-match payloads (the beat timeline, the lull spans, the whole lead
## series) so they can ride the FIRST HUD frame, and `buildStateJson` keeps
## paintbot's key names EXACTLY -- `t, mt, ph, pl, sp, mx, st, lp, sk, ff, en,
## mm, bs, teams, roster, events, lead, beats, lulls, over, hold` -- so
## `client/chrome_common.js` runs unmodified over a matrix-games stream.
##
## What changed from CTF: `teams` carries the K TOKEN-TYPE keys (`red`,
## `blue`, and `green` when K == 3 -- names chrome_common's TEAM_ORDER/teamCol
## already know, so the momentum legend gets its colours free), `lead` is the
## convention-share series rather than a lives lead, and the eight seats ride
## in a separate `seats[]` array read only by the appended game block. That
## separation is why an 8-seat game never collides with chrome_common's 2-4
## team assumption.

import std/[json]
import sim_types, sim_config, matrices, sim_state, events, indices

type
  BroadcastTracker* = object
    beats*: JsonNode         ## the whole scrubber timeline, shipped on frame 1
    lulls*: JsonNode
    lead*: JsonNode
    built*: bool

proc tokenKey*(index: int): string =
  if index >= 0 and index < TokenChromeKeys.len: TokenChromeKeys[index]
  else: "red"

proc seatTeam*(sim: Sim, slot: int): string =
  ## The chrome "team" of a seat is the token type it is currently most
  ## committed to -- so `teamCol` tints its plate with the token's colour.
  tokenKey(argmaxLowest(sim.cogs[slot].inv))

proc buildBeats*(sim: Sim): JsonNode =
  ## One `interact` row per resolution, promoted to `bigpay` when either side
  ## cleared BigPayCp; one `leadchange` row per lead change; one `over` row at
  ## the final tick. Those FOUR are the only kinds emitted, which is what
  ## makes "a CSS rule per kind" a closed assertion in `tests/test_viewer.nim`.
  result = newJArray()
  for record in sim.events.records:
    case record{"k"}.getStr()
    of "interact":
      let rowCp = record{"rowCp"}.getInt()
      let colCp = record{"colCp"}.getInt()
      let big = rowCp >= BigPayCp or colCp >= BigPayCp
      result.add(%*{
        "t": record{"t"}.getInt(),
        "k": (if big: "bigpay" else: "interact"),
        "seat": record{"row"}.getInt(),
        "other": record{"col"}.getInt(),
        "cp": max(rowCp, colCp)})
    of "leadchange":
      result.add(%*{
        "t": record{"t"}.getInt(), "k": "leadchange",
        "seat": record{"seat"}.getInt(), "other": -1,
        "cp": record{"scoreCp"}.getInt()})
    else:
      discard
  result.add(%*{
    "t": max(0, sim.tick - 1), "k": "over",
    "seat": sim.leader(), "other": -1,
    "cp": sim.cogs[sim.leader()].scoreCp})

proc buildLulls*(sim: Sim): JsonNode =
  ## Every stretch of >= LullTicks with no resolution, so the starter's
  ## auto-skip button has something real to skip.
  result = newJArray()
  var marks: seq[int] = @[0]
  for record in sim.events.records:
    if record{"k"}.getStr() == "interact":
      marks.add(record{"t"}.getInt())
  marks.add(max(0, sim.tick - 1))
  for index in 1 ..< marks.len:
    if marks[index] - marks[index - 1] >= LullTicks:
      result.add(%[marks[index - 1], marks[index]])

proc buildLead*(sim: Sim): JsonNode =
  ## `lead = {"teams": [...K token keys...], "pts": [[t, share0, ...], ...]}`,
  ## shipped whole on frame 1 so chrome_common's momentum curve draws its full
  ## width immediately (paintbot's `lead` trick).
  var teams = newJArray()
  for index in 0 ..< sim.spec.k:
    teams.add(%tokenKey(index))
  var pts = newJArray()
  for row in sim.shareSeries:
    pts.add(%row)
  %*{"teams": teams, "pts": pts}

proc ensureBuilt*(tracker: var BroadcastTracker, sim: Sim) =
  if tracker.built:
    return
  tracker.built = true
  tracker.beats = buildBeats(sim)
  tracker.lulls = buildLulls(sim)
  tracker.lead = buildLead(sim)

proc buildSeats*(sim: Sim): JsonNode =
  ## The eight seats, read ONLY by the appended game block. Real POLICY names
  ## live here -- spectator side -- and never in a seat's observation.
  result = newJArray()
  for slot, cog in sim.cogs:
    result.add(%*{
      "s": slot,
      "alias": aliasOf(slot),
      "name": sim.names[slot],
      "livery": liveryOf(slot),
      "color": liveryHexOf(slot),
      "camp": campOf(slot, sim.spec.crossCampOnly),
      "kind": sim.policyKinds[slot],
      "x": cog.x, "y": cog.y, "facing": cog.facing,
      "inv": cog.inv, "mix": mix(cog.inv),
      "scoreCp": cog.scoreCp, "interactions": cog.interactions,
      "frozen": cog.freeze > 0,
      "source": $sim.orderSources[slot],
      "intent": $sim.orders[slot].intent,
      "say": sim.says[slot],
      "connected": sim.connected[slot]})

proc buildTeams*(sim: Sim): JsonNode =
  ## `teams` carries the K token-type keys, each `{share, tokensLeft, cells}`.
  result = newJObject()
  var totals = newSeq[int](sim.spec.k)
  var grand = 0
  for cog in sim.cogs:
    for index in 0 ..< sim.spec.k:
      totals[index] += cog.inv[index]
      grand += cog.inv[index]
  var left = newSeq[int](sim.spec.k)
  var cells = newSeq[int](sim.spec.k)
  for spawner in sim.spawners:
    cells[spawner.token].inc
    if spawner.hasToken:
      left[spawner.token].inc
  for index in 0 ..< sim.spec.k:
    result[tokenKey(index)] = %*{
      "share": (if grand <= 0: 0 else: (totals[index] * 1000) div grand),
      "tokensLeft": left[index],
      "cells": cells[index]}

proc buildRoster*(sim: Sim): JsonNode =
  ## chrome_common reads `roster[i].s` / `.name` / `.team`; the token key a
  ## seat is most committed to is its chrome "team", which is what tints its
  ## plate and the momentum legend.
  result = newJArray()
  for slot, cog in sim.cogs:
    result.add(%*{
      "s": slot, "name": sim.names[slot], "team": seatTeam(sim, slot),
      "pol": sim.names[slot], "alive": true, "lives": 0,
      "score": cog.scoreCp})

proc buildStateJson*(sim: Sim, tracker: var BroadcastTracker,
    playing = true, speed = 1, loop = false, skipLulls = false,
    fastForward = false, enabled = true, firstFrame = false): JsonNode =
  ## The chrome frame. The key set is paintbot's, plus `seats`.
  tracker.ensureBuilt(sim)
  var frameEvents = newJArray()
  for record in sim.events.records:
    if record{"t"}.getInt(-1) == sim.tick:
      frameEvents.add(record)
  let over = sim.done or sim.tick >= maxTicks(sim.config)
  result = %*{
    "t": sim.tick,
    "mt": maxTicks(sim.config),
    "ph": (if over: "gameover" else: "playing"),
    "pl": playing,
    "sp": speed,
    "mx": max(1, maxTicks(sim.config)),
    "st": 0,
    "lp": loop,
    "sk": skipLulls,
    "ff": fastForward,
    "en": enabled,
    "mm": false,
    "bs": 0,
    "teams": buildTeams(sim),
    "roster": buildRoster(sim),
    "events": frameEvents,
    "over": over,
    "hold": 0,
    "seats": buildSeats(sim),
    "beat": sim.beat,
    "beats_played": sim.beat,
    "variant": sim.spec.name,
    "indices": {
      "interactions": sim.idx.interactions,
      "coopRate": sim.idx.coopRate(sim.spec),
      "conventionCounts": sim.idx.conventionJson()}
  }
  ## The three once-per-match payloads ride the FIRST frame whole.
  if firstFrame:
    result["beats"] = tracker.beats
    result["lulls"] = tracker.lulls
    result["lead"] = tracker.lead
  else:
    result["beats"] = newJArray()
    result["lulls"] = newJArray()
    result["lead"] = newJNull()

proc globalSnapshot*(sim: Sim, tracker: var BroadcastTracker): JsonNode =
  ## The live `/global` frame: the chrome state plus the protocol envelope.
  result = buildStateJson(sim, tracker, firstFrame = true)
  result["type"] = %"state"
  result["game"] = %"matrix-games"
  result["protocol"] = %GlobalProtocol
  result["done"] = %sim.done
  result["reason"] = %sim.reason
  result["ending"] = %sim.ending
