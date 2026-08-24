## The viewer side: one packet per tick, for BOTH delivery modes.
##
## Fork of paintbot's `src/ctf/global.nim`, heavily reduced. What is kept is
## the job that module does: turn one tick of recorded state into exactly what
## the browser draws, with the chrome frame smuggled alongside the board frame
## in the same packet, and one board render scale derived from the map size.
## What is DELETED, because matrix games has no use for it: fog of war and
## FOV, the first-person picture-in-picture, articulated rigs beyond the
## standing cog, the grenade / spray / shield / barrier families, endzone
## bakes, perks and handicaps.
##
## Matrix Games records STATE, not inputs, so playback never re-simulates: a
## seek is an array index and there is no native/wasm divergence to chase.
## That is why `ctf_mismatch_tick` is dropped and why `#mmwarn` is gone from
## the page.

import std/[json]
import sim_types, matrices

type
  ViewerState* = object
    replay*: JsonNode
    k*: int
    tokens*: seq[string]
    spec*: MatrixSpec
    frames*: JsonNode
    events*: JsonNode
    tickCount*: int
    spawnerTokens*: seq[int]
    eventsAt*: seq[seq[int]]      ## tick -> indexes into `events`
    orderAt*: seq[seq[int]]       ## tick -> per-seat latest order event index
    interactionsAt*: seq[seq[int]]## tick -> per-seat cumulative resolutions
    totalAt*: seq[int]            ## tick -> cumulative resolutions in the room
    coopMassAt*: seq[int]
    massAt*: seq[int]
    conventionAt*: seq[seq[int]]  ## tick -> flattened k*k running histogram
    beats*: JsonNode
    lulls*: JsonNode
    lead*: JsonNode

const
  WasmViewerBudgetBytes* = 1_600_000_000
    ## wasm32 has a 2 GB address space; the capacity check is kept from
    ## paintbot even though a 24 x 14 board can never trip it.

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  ## Paintbot's rule, reduced: supersample small boards, never let the render
  ## buffer approach the wasm32 budget. Matrix Games is always 24 x 14, so
  ## this always answers 2.
  if mapWidth * mapHeight * CellPx * CellPx * 4 * 4 < WasmViewerBudgetBytes: 2
  else: 1

proc predictedViewerRenderBytes*(mapWidth, mapHeight: int): int64 =
  let scale = boardRenderScaleFor(mapWidth, mapHeight).int64
  mapWidth.int64 * mapHeight.int64 * CellPx.int64 * CellPx.int64 * 4 *
    scale * scale

proc tokenKeyOf*(index: int): string =
  if index >= 0 and index < TokenChromeKeys.len: TokenChromeKeys[index]
  else: "red"

proc initViewer*(replay: JsonNode): ViewerState =
  ## Indexes the replay so a seek is an array lookup rather than a scan.
  result.replay = replay
  let config = replay{"config"}
  if config == nil:
    raise newException(MatrixGamesError, "replay has no config")
  result.spec = matrixSpec(config{"matrix"}.getStr())
  result.k = result.spec.k
  result.tokens = result.spec.tokens
  result.frames = replay{"frames"}
  if result.frames == nil or result.frames.kind != JArray:
    raise newException(MatrixGamesError, "replay has no frames")
  result.tickCount = result.frames.len
  if result.tickCount == 0:
    raise newException(MatrixGamesError, "replay has zero frames")
  result.events = replay{"events"}
  if result.events == nil or result.events.kind != JArray:
    result.events = newJArray()
  for spawner in replay{"spawners"}:
    result.spawnerTokens.add(spawner{"token"}.getInt())

  result.eventsAt = newSeq[seq[int]](result.tickCount)
  for index in 0 ..< result.events.len:
    let t = result.events[index]{"t"}.getInt(-1)
    if t >= 0 and t < result.tickCount:
      result.eventsAt[t].add(index)

  result.orderAt = newSeq[seq[int]](result.tickCount)
  result.interactionsAt = newSeq[seq[int]](result.tickCount)
  result.conventionAt = newSeq[seq[int]](result.tickCount)
  result.totalAt = newSeq[int](result.tickCount)
  result.coopMassAt = newSeq[int](result.tickCount)
  result.massAt = newSeq[int](result.tickCount)
  var order = newSeq[int](Seats)
  var seatCount = newSeq[int](Seats)
  var convention = newSeq[int](result.k * result.k)
  var total = 0
  var coopMass = 0
  var mass = 0
  for slot in 0 ..< Seats:
    order[slot] = -1
  for t in 0 ..< result.tickCount:
    for index in result.eventsAt[t]:
      let record = result.events[index]
      case record{"k"}.getStr()
      of "order":
        let seat = record{"seat"}.getInt(-1)
        if seat >= 0 and seat < Seats:
          order[seat] = index
      of "interact":
        total.inc
        let rowSeat = record{"row"}.getInt(0)
        let colSeat = record{"col"}.getInt(0)
        if rowSeat >= 0 and rowSeat < Seats:
          seatCount[rowSeat].inc
        if colSeat >= 0 and colSeat < Seats:
          seatCount[colSeat].inc
        let cell = record{"cellRow"}.getInt(0) * result.k +
          record{"cellCol"}.getInt(0)
        if cell >= 0 and cell < convention.len:
          convention[cell].inc
        for side in ["rowInv", "colInv"]:
          for i, value in record{side}.getElems():
            mass += value.getInt()
            if i == result.spec.coopToken:
              coopMass += value.getInt()
      else:
        discard
    result.orderAt[t] = order
    result.interactionsAt[t] = seatCount
    result.conventionAt[t] = convention
    result.totalAt[t] = total
    result.coopMassAt[t] = coopMass
    result.massAt[t] = mass

  ## The three once-per-match payloads the chrome wants whole on frame 1 are
  ## DERIVED from the replay rather than stored in it: the replay carries the
  ## events and the share series, and these are functions of them.
  result.beats = newJArray()
  var lastLeader = -1
  for index in 0 ..< result.events.len:
    let record = result.events[index]
    case record{"k"}.getStr()
    of "interact":
      let rowCp = record{"rowCp"}.getInt()
      let colCp = record{"colCp"}.getInt()
      result.beats.add(%*{
        "t": record{"t"}.getInt(),
        "k": (if rowCp >= BigPayCp or colCp >= BigPayCp: "bigpay"
              else: "interact"),
        "seat": record{"row"}.getInt(),
        "other": record{"col"}.getInt(),
        "cp": max(rowCp, colCp)})
    of "leadchange":
      lastLeader = record{"seat"}.getInt()
      result.beats.add(%*{
        "t": record{"t"}.getInt(), "k": "leadchange",
        "seat": lastLeader, "other": -1,
        "cp": record{"scoreCp"}.getInt()})
    else:
      discard
  result.beats.add(%*{
    "t": max(0, result.tickCount - 1), "k": "over",
    "seat": max(0, lastLeader), "other": -1, "cp": 0})

  result.lulls = newJArray()
  var marks: seq[int] = @[0]
  for index in 0 ..< result.events.len:
    if result.events[index]{"k"}.getStr() == "interact":
      marks.add(result.events[index]{"t"}.getInt())
  marks.add(max(0, result.tickCount - 1))
  for index in 1 ..< marks.len:
    if marks[index] - marks[index - 1] >= LullTicks:
      result.lulls.add(%[marks[index - 1], marks[index]])

  var leadTeams = newJArray()
  for index in 0 ..< result.k:
    leadTeams.add(%tokenKeyOf(index))
  var pts = replay{"series"}{"share"}
  if pts == nil or pts.kind != JArray:
    pts = newJArray()
  result.lead = %*{"teams": leadTeams, "pts": pts}

proc seatsAt*(view: ViewerState, t: int): JsonNode =
  let frame = view.frames[t]
  let names = view.replay{"policyNames"}
  let camps = view.replay{"camps"}
  let liveries = view.replay{"liveries"}
  result = newJArray()
  for slot in 0 ..< Seats:
    var inv = newJArray()
    var invTotal = 0
    var invValues = newSeq[int](view.k)
    for i in 0 ..< view.k:
      let value = frame{"inv"}[slot * view.k + i].getInt()
      invValues[i] = value
      invTotal += value
      inv.add(%value)
    var mixNode = newJArray()
    for i in 0 ..< view.k:
      mixNode.add(%(if invTotal <= 0: 0
                    else: (invValues[i] * 1000) div invTotal))
    let orderIndex = view.orderAt[t][slot]
    var say = ""
    var intent = "hold"
    var source = "scripted"
    if orderIndex >= 0:
      say = view.events[orderIndex]{"say"}.getStr()
      intent = view.events[orderIndex]{"intent"}.getStr()
      source = view.events[orderIndex]{"source"}.getStr()
    result.add(%*{
      "s": slot,
      "alias": aliasOf(slot),
      "name": (if names != nil and names.len > slot: names[slot].getStr()
               else: aliasOf(slot)),
      "livery": (if liveries != nil and liveries.len > slot:
                   liveries[slot].getStr() else: liveryOf(slot)),
      "color": liveryHexOf(slot),
      "camp": (if camps != nil and camps.len > slot: camps[slot].getStr()
               else: "none"),
      "x": frame{"c"}[slot * 4 + 0].getInt(),
      "y": frame{"c"}[slot * 4 + 1].getInt(),
      "facing": frame{"c"}[slot * 4 + 2].getInt(),
      "frozen": frame{"c"}[slot * 4 + 3].getInt() > 0,
      "inv": inv, "mix": mixNode,
      "scoreCp": frame{"sc"}[slot].getInt(),
      "interactions": view.interactionsAt[t][slot],
      "intent": intent, "say": say, "source": source,
      "connected": true})

proc teamsAt*(view: ViewerState, t: int): JsonNode =
  let frame = view.frames[t]
  var totals = newSeq[int](view.k)
  var grand = 0
  for slot in 0 ..< Seats:
    for i in 0 ..< view.k:
      let value = frame{"inv"}[slot * view.k + i].getInt()
      totals[i] += value
      grand += value
  var left = newSeq[int](view.k)
  var cells = newSeq[int](view.k)
  for index, token in view.spawnerTokens:
    if token >= 0 and token < view.k:
      cells[token].inc
      if frame{"tok"}[index].getInt() != 0:
        left[token].inc
  result = newJObject()
  for i in 0 ..< view.k:
    result[tokenKeyOf(i)] = %*{
      "share": (if grand <= 0: 0 else: (totals[i] * 1000) div grand),
      "tokensLeft": left[i], "cells": cells[i]}

proc chromeStateAt*(view: ViewerState, t: int, firstFrame: bool): JsonNode =
  ## The SAME key set `broadcast.buildStateJson` emits, so chrome_common.js
  ## runs identically over a live stream and over a recorded replay. The
  ## transport flags carry neutral defaults; the page owns them and merges its
  ## own before handing the frame to chrome_common.
  let seats = view.seatsAt(t)
  var roster = newJArray()
  for entry in seats:
    var best = 0
    for i in 1 ..< view.k:
      if entry{"inv"}[i].getInt() > entry{"inv"}[best].getInt():
        best = i
    roster.add(%*{
      "s": entry{"s"}.getInt(), "name": entry{"name"}.getStr(),
      "team": tokenKeyOf(best), "pol": entry{"name"}.getStr(),
      "alive": true, "lives": 0, "score": entry{"scoreCp"}.getInt()})
  var frameEvents = newJArray()
  for index in view.eventsAt[t]:
    frameEvents.add(view.events[index])
  var convention = newJArray()
  for i in 0 ..< view.k:
    var row = newJArray()
    for j in 0 ..< view.k:
      row.add(%view.conventionAt[t][i * view.k + j])
    convention.add(row)
  let ticksPerBeat = max(1, view.replay{"config"}{"ticksPerBeat"}.getInt(50))
  result = %*{
    "t": t,
    "mt": view.tickCount,
    "ph": (if t >= view.tickCount - 1: "gameover" else: "playing"),
    "pl": true, "sp": 1, "mx": max(1, view.tickCount), "st": 0,
    "lp": false, "sk": false, "ff": false, "en": true, "mm": false, "bs": 0,
    "teams": view.teamsAt(t),
    "roster": roster,
    "events": frameEvents,
    "over": t >= view.tickCount - 1,
    "hold": 0,
    "seats": seats,
    "beat": t div ticksPerBeat,
    "beats_played": t div ticksPerBeat,
    "variant": view.spec.name,
    "indices": {
      "interactions": view.totalAt[t],
      "coopRate": (if view.spec.coopToken < 0 or view.massAt[t] <= 0:
                     newJNull()
                   else: %(view.coopMassAt[t].float /
                           view.massAt[t].float)),
      "conventionCounts": convention}
  }
  if firstFrame:
    result["beats"] = view.beats
    result["lulls"] = view.lulls
    result["lead"] = view.lead
  else:
    result["beats"] = newJArray()
    result["lulls"] = newJArray()
    result["lead"] = newJNull()

proc orNull(node: JsonNode): JsonNode =
  ## A nil JsonNode inside a JObject crashes `$`; a missing key becomes JSON
  ## null instead, so a truncated replay reports rather than aborts.
  if node == nil: newJNull() else: node

proc viewerMeta*(view: ViewerState): JsonNode =
  ## Everything the page needs ONCE. Self-sufficient: no server is contacted
  ## except S3 for the replay bytes themselves.
  %*{
    "protocol": orNull(view.replay{"protocol"}),
    "gameVersion": orNull(view.replay{"gameVersion"}),
    "variant": orNull(view.replay{"variant"}),
    "seed": orNull(view.replay{"seed"}),
    "config": orNull(view.replay{"config"}),
    "map": orNull(view.replay{"map"}),
    "spawners": orNull(view.replay{"spawners"}),
    "names": orNull(view.replay{"names"}),
    "policyNames": orNull(view.replay{"policyNames"}),
    "liveries": orNull(view.replay{"liveries"}),
    "camps": orNull(view.replay{"camps"}),
    "results": orNull(view.replay{"results"}),
    "indices": orNull(view.replay{"indices"}),
    "events": view.events,
    "beats": view.beats,
    "lulls": view.lulls,
    "lead": view.lead,
    "tickCount": view.tickCount,
    "fps": TargetFps,
    "cellPx": CellPx,
    "renderScale": boardRenderScaleFor(BoardW, BoardH),
    "playbackSpeeds": PlaybackSpeeds,
    "tokenKeys": TokenChromeKeys
  }

proc viewerPacket*(view: ViewerState, t: int, firstFrame: bool): JsonNode =
  ## One tick, board plus chrome, in one object -- paintbot's "smuggle the
  ## chrome TextMessage alongside the sprite packet" trick, in JSON. The
  ## once-per-match meta rides the first packet, so the page and the board
  ## renderer both get everything they need without a second export.
  let index = clamp(t, 0, view.tickCount - 1)
  result = %*{
    "t": index,
    "b": view.frames[index],
    "s": view.chromeStateAt(index, firstFrame)
  }
  if firstFrame:
    result["meta"] = view.viewerMeta()
