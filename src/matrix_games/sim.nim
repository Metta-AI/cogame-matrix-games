## The tick loop and the ten numbered rules, plus the seat observation every
## policy -- LLM or scripted -- reads.
##
## Fork of paintbot's `src/ctf/sim.nim`: same shape (a `stepOnce` that runs a
## fixed, numbered sequence of rules with all reads taken from the state as it
## stood at the start of the rule), with the CTF gameplay core replaced by the
## matrix-games rules. Where a rule must write in sequence it iterates seats
## in ascending slot order, and says so.

import std/[json]
import sim_types, sim_config, matrices, arena_map, sim_state, events, indices,
  kernel

# ---- rule 7 / 8 --------------------------------------------------------

proc resolve(sim: var Sim, shooter, target: int) =
  ## Rule 7 (resolution) and rule 8 (reset), which always run together.
  ##
  ## The ROW player is the shooter in every symmetric variant; in
  ## `bach-or-stravinsky` it is the row-camp (blue) participant regardless of
  ## who fired, because the matrix itself is asymmetric.
  var rowSeat = shooter
  var colSeat = target
  if sim.spec.crossCampOnly and not rowCamp(shooter):
    rowSeat = target
    colSeat = shooter
  let rowInv = sim.cogs[rowSeat].inv
  let colInv = sim.cogs[colSeat].inv
  let rowMixV = mix(rowInv)
  let colMixV = mix(colInv)
  let pay = payoffCp(sim.spec, rowInv, colInv)
  sim.cogs[rowSeat].scoreCp += pay.rowCp
  sim.cogs[colSeat].scoreCp += pay.colCp
  sim.cogs[rowSeat].interactions.inc
  sim.cogs[colSeat].interactions.inc
  let cellRow = argmaxLowest(rowInv)
  let cellCol = argmaxLowest(colInv)
  sim.record("interact", %*{
    "t": sim.tick, "beat": sim.beat, "row": rowSeat, "col": colSeat,
    "rowInv": rowInv, "colInv": colInv,
    "rowMix": rowMixV, "colMix": colMixV,
    "cellRow": cellRow, "cellCol": cellCol,
    "rowCp": pay.rowCp, "colCp": pay.colCp
  })
  sim.idx.noteResolution(sim.spec, rowSeat, colSeat, rowInv, colInv,
    rowMixV, colMixV, cellRow, cellCol, pay.rowCp, pay.colCp)
  ## Rule 8: both participants reset to the endowment and go on ice. This is
  ## what makes commitment cost time, what makes token denial pay, and what
  ## stops a hoarder farming a frozen neighbour.
  for seat in [rowSeat, colSeat]:
    for i in 0 ..< sim.spec.k:
      sim.cogs[seat].inv[i] = 1
    sim.cogs[seat].freeze = sim.config.freezeTicks
    sim.cogs[seat].immune = ImmuneTicks
    sim.cogs[seat].beamCd = sim.config.beamResetCooldown
    sim.record("reset", %*{"t": sim.tick, "seat": seat})

# ---- the tick ----------------------------------------------------------

proc stepOnce*(sim: var Sim) =
  # 1. Timers.
  for slot in 0 ..< sim.cogs.len:
    if sim.cogs[slot].freeze > 0: sim.cogs[slot].freeze.dec
    if sim.cogs[slot].stepCd > 0: sim.cogs[slot].stepCd.dec
    if sim.cogs[slot].beamCd > 0: sim.cogs[slot].beamCd.dec
    if sim.cogs[slot].immune > 0: sim.cogs[slot].immune.dec

  # 2. Token respawn.
  for index in 0 ..< sim.spawners.len:
    if not sim.spawners[index].hasToken and
        sim.spawners[index].refillAt == sim.tick:
      sim.spawners[index].hasToken = true
      sim.spawners[index].refillAt = -1

  # 3. Intent evaluation, all reads against the state at the start of the
  #    rule, so ordering inside it cannot change the outcome.
  var micros = newSeq[Micro](sim.cogs.len)
  for slot in 0 ..< sim.cogs.len:
    micros[slot] = microFor(sim, slot)

  # 4. Movement, seats in ASCENDING SLOT ORDER. A cog whose target cell was
  #    taken by a lower slot this tick waits.
  for slot in 0 ..< sim.cogs.len:
    let micro = micros[slot]
    if micro.kind == mkTurn:
      sim.cogs[slot].facing = micro.dir
    elif micro.kind == mkStep and sim.cogs[slot].stepCd == 0:
      let nx = sim.cogs[slot].x + DirDx[micro.dir]
      let ny = sim.cogs[slot].y + DirDy[micro.dir]
      sim.cogs[slot].facing = micro.dir
      if isFloor(nx, ny) and sim.occupant(nx, ny) < 0:
        sim.cogs[slot].x = nx
        sim.cogs[slot].y = ny
        sim.cogs[slot].stepCd = sim.config.stepCooldownTicks

  # 5. Pickup, seats in ascending slot order.
  for slot in 0 ..< sim.cogs.len:
    let index = sim.spawnerAt(sim.cogs[slot].x, sim.cogs[slot].y)
    if index < 0 or not sim.spawners[index].hasToken:
      continue
    let token = sim.spawners[index].token
    if sim.cogs[slot].inv[token] >= sim.config.tokenCap:
      continue
    sim.cogs[slot].inv[token].inc
    sim.spawners[index].hasToken = false
    sim.spawners[index].refillAt = sim.tick + sim.config.tokenRespawnTicks
    sim.record("pickup", %*{
      "t": sim.tick, "seat": slot, "x": sim.cogs[slot].x,
      "y": sim.cogs[slot].y, "token": token
    })

  sim.updateSight()

  # 6. Beam fire, seats in ascending slot order.
  for slot in 0 ..< sim.cogs.len:
    if micros[slot].kind != mkFire:
      continue
    if sim.cogs[slot].beamCd != 0 or sim.cogs[slot].freeze > 0:
      continue
    let cells = rayCells(sim, sim.cogs[slot].x, sim.cogs[slot].y,
      sim.cogs[slot].facing, sim.config.beamRange)
    var hit = -1
    for cell in cells:
      let other = sim.occupant(cell[0], cell[1])
      if other >= 0 and other != slot:
        hit = other
        break
    sim.record("beam", %*{
      "t": sim.tick, "seat": slot, "x": sim.cogs[slot].x,
      "y": sim.cogs[slot].y, "dir": sim.cogs[slot].facing,
      "len": cells.len, "hitSeat": hit
    })
    if hit < 0:
      sim.cogs[slot].beamCd = sim.config.beamMissCooldown
      continue
    if sim.cogs[hit].immune > 0 or sim.cogs[hit].freeze > 0:
      sim.record("nocontest", %*{
        "t": sim.tick, "seat": slot, "target": hit, "why": "immune"})
      sim.cogs[slot].beamCd = sim.config.beamMissCooldown
      continue
    if sim.spec.crossCampOnly and rowCamp(slot) == rowCamp(hit):
      sim.record("nocontest", %*{
        "t": sim.tick, "seat": slot, "target": hit, "why": "same_camp"})
      sim.cogs[slot].beamCd = sim.config.beamMissCooldown
      continue
    # 7 + 8.
    sim.resolve(slot, hit)

  # 9. Indices are updated inside `resolve`; the leader check is here.
  let lead = sim.leader()
  if lead != sim.lastLeader:
    sim.lastLeader = lead
    sim.record("leadchange", %*{
      "t": sim.tick, "seat": lead, "scoreCp": sim.cogs[lead].scoreCp})

  # 10. Record.
  sim.captureFrame()
  sim.captureSeries()
  sim.tick.inc

proc closeBeat*(sim: var Sim) =
  var scores = newJArray()
  for cog in sim.cogs:
    scores.add(%cog.scoreCp)
  sim.record("beatclose", %*{
    "t": sim.tick, "beat": sim.beat, "scoreCp": scores,
    "interactions": sim.idx.interactions})
  sim.beat.inc

proc runBeat*(sim: var Sim) =
  ## One beat: `ticksPerBeat` ticks, then the beat close.
  for _ in 0 ..< sim.config.ticksPerBeat:
    if sim.done:
      return
    sim.stepOnce()
  sim.closeBeat()

proc finish*(sim: var Sim, reason, ending: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  var scores = newJArray()
  for cog in sim.cogs:
    scores.add(%cog.scoreCp)
  sim.record("end", %*{
    "t": sim.tick, "reason": reason, "ending": ending, "scoreCp": scores})

proc settleComplete*(sim: var Sim) =
  ## The end of the beat loop, in ONE place: an episode that played every beat
  ## without settling early ends `complete` / `full_match`. `server.runGame`
  ## calls this when the loop falls out, and so does every harness that plays a
  ## full episode, so the reason a test asserts is the reason production
  ## stamps rather than a second, parallel stamp that can drift from it.
  if not sim.done:
    sim.finish("complete", "full_match")

# ---- installing a beat's decisions -------------------------------------

proc installOrders*(sim: var Sim, decisions: seq[Decision]) =
  ## Called at each beat boundary, before the beat's 50 ticks run. Every
  ## recorded string is rune-truncated here, once, so nothing downstream has
  ## to remember to do it.
  for slot in 0 ..< min(decisions.len, sim.cogs.len):
    var order = decisions[slot].order
    order.say = cleanText(order.say, MaxSayRunes)
    order.notes = cleanText(order.notes, MaxNotesRunes)
    sim.orders[slot] = order
    sim.orderSources[slot] = decisions[slot].source
    sim.haveOrder[slot] = true
    sim.says[slot] = order.say
    sim.notes[slot] = order.notes
    sim.record("order", orderEvent(sim.tick, sim.beat, slot, order,
      decisions[slot].source, decisions[slot].latencyMs))

# ---- the seat observation ----------------------------------------------

proc legalTargets*(sim: Sim, slot: int): seq[int] =
  for other in 0 ..< sim.cogs.len:
    if sim.eligibleAgainst(slot, other):
      result.add(other)

proc buildObservation*(sim: Sim, slot: int): JsonNode =
  ## Everything visible to one seat, and NOTHING else. No policy name, no
  ## player name, no prompt, no other seat's intent/notes/say, no seed.
  ## Every scripted baseline reads this object and nothing else, which is
  ## what makes a baseline a legitimate policy (`tests/test_baseline.nim`).
  let me = sim.cogs[slot]
  let spec = sim.spec
  var rowPay = newJArray()
  var colPay = newJArray()
  for i in 0 ..< spec.k:
    rowPay.add(%spec.rowPay[i])
    colPay.add(%spec.colPay[i])
  var endow = newJArray()
  for _ in 0 ..< spec.k:
    endow.add(%1)

  var zones = newJArray()
  for zone in sim.zones:
    zones.add(%*{
      "token": (if zone.token < 0: "mixed" else: spec.tokens[zone.token]),
      "x0": zone.x0, "y0": zone.y0, "x1": zone.x1, "y1": zone.y1,
      "cx": zone.cx, "cy": zone.cy, "tokensLeft": sim.tokensLeft(zone)})

  var visibleTokens = newJArray()
  for spawner in sim.spawners:
    if not spawner.hasToken:
      continue
    if chebyshev(me.x, me.y, spawner.x, spawner.y) > sim.config.viewRadius:
      continue
    if not lineOfSight(me.x, me.y, spawner.x, spawner.y):
      continue
    visibleTokens.add(%*{"x": spawner.x, "y": spawner.y,
      "token": spec.tokens[spawner.token]})

  var cogs = newJArray()
  for other in 0 ..< sim.cogs.len:
    if other == slot:
      continue
    let seen = sim.visible(slot, other)
    let cx = sim.memX[slot][other]
    let cy = sim.memY[slot][other]
    var entry = %*{
      "alias": aliasOf(other),
      "camp": campOf(other, spec.crossCampOnly),
      "x": cx, "y": cy,
      "dist": chebyshev(me.x, me.y, cx, cy),
      "seenTicksAgo":
        (if sim.memTick[slot][other] < 0: -1
         else: sim.tick - sim.memTick[slot][other]),
      "scoreCp": sim.cogs[other].scoreCp,
      "interactions": sim.cogs[other].interactions,
      "frozen": sim.cogs[other].freeze > 0,
      "eligible": sim.eligibleAgainst(slot, other)
    }
    if seen:
      entry["inv"] = %sim.cogs[other].inv
      entry["mix"] = %mix(sim.cogs[other].inv)
    else:
      entry["inv"] = newJNull()
      entry["mix"] = newJNull()
    cogs.add(entry)

  ## The COMPLETE public log of every resolution in the episode: the beam is
  ## a visible event and everyone sees who did what to whom.
  var log = newJArray()
  for record in sim.events.records:
    if record{"k"}.getStr() != "interact":
      continue
    let rowSeat = record{"row"}.getInt()
    let colSeat = record{"col"}.getInt()
    log.add(%*{
      "beat": record{"beat"}.getInt(), "tick": record{"t"}.getInt(),
      "row": aliasOf(rowSeat), "col": aliasOf(colSeat),
      "cell": [spec.tokens[record{"cellRow"}.getInt()],
               spec.tokens[record{"cellCol"}.getInt()]],
      "rowMix": record{"rowMix"}, "colMix": record{"colMix"},
      "rowCp": record{"rowCp"}.getInt(), "colCp": record{"colCp"}.getInt()
    })

  var legalTokens = newJArray()
  for name in spec.tokens:
    legalTokens.add(%name)
  var legalTargetNames = newJArray()
  for other in sim.legalTargets(slot):
    legalTargetNames.add(%aliasOf(other))

  %*{
    "type": "state", "protocol": PlayerProtocol,
    "slot": slot, "name": aliasOf(slot),
    "camp": campOf(slot, spec.crossCampOnly),
    "variant": spec.name,
    "beat": sim.beat, "beats": sim.config.beats,
    "ticksPerBeat": sim.config.ticksPerBeat, "tick": sim.tick,
    "board": {"w": BoardW, "h": BoardH, "walls": walls()},
    "rules": {
      "K": spec.k, "tokens": legalTokens,
      "rowPay": rowPay, "colPay": colPay,
      "bestResponseRow": bestResponseRow(spec),
      "bestResponseCol": bestResponseCol(spec),
      "tokenCap": sim.config.tokenCap, "endowment": endow,
      "beamRange": sim.config.beamRange,
      "freezeTicks": sim.config.freezeTicks,
      "stepCooldownTicks": sim.config.stepCooldownTicks,
      "beamResetCooldown": sim.config.beamResetCooldown,
      "beamMissCooldown": sim.config.beamMissCooldown,
      "tokenRespawnTicks": sim.config.tokenRespawnTicks,
      "viewRadius": sim.config.viewRadius,
      "crossCampOnly": spec.crossCampOnly
    },
    "you": {
      "x": me.x, "y": me.y, "facing": me.facing, "inv": me.inv,
      "mix": mix(me.inv), "scoreCp": me.scoreCp, "freeze": me.freeze,
      "beamCd": me.beamCd, "interactions": me.interactions,
      "fixedType": me.fixedType
    },
    "zones": zones,
    "visibleTokens": visibleTokens,
    "cogs": cogs,
    "log": log,
    "indices": {
      "interactions": sim.idx.interactions,
      "coopRate": sim.idx.coopRate(spec),
      "conventionCounts": sim.idx.conventionJson(),
      "yourExploitabilityCp":
        (if sim.idx.resolutions[slot] > 0:
           %sim.idx.exploitabilityCp(spec, slot)
         else: newJNull())
    },
    "legal": {"tokens": legalTokens, "targets": legalTargetNames},
    "notes": sim.notes[slot]
  }

# ---- results -----------------------------------------------------------

proc scores*(sim: Sim): seq[float] =
  for cog in sim.cogs:
    result.add(cog.scoreCp.float / 100.0)

proc resultsJson*(sim: Sim): JsonNode =
  let scoreList = sim.scores()
  var best = low(float)
  for value in scoreList:
    if value > best:
      best = value
  var names = newJArray()
  var aliases = newJArray()
  var camps = newJArray()
  var scoresNode = newJArray()
  var win = newJArray()
  var perSeat = newJArray()
  var meanPayoff = newJArray()
  for slot, cog in sim.cogs:
    names.add(%sim.names[slot])
    aliases.add(%aliasOf(slot))
    camps.add(%campOf(slot, sim.spec.crossCampOnly))
    scoresNode.add(%scoreList[slot])
    win.add(%(scoreList[slot] == best))
    perSeat.add(%cog.interactions)
    meanPayoff.add(%(
      if cog.interactions <= 0: 0.0
      else: scoreList[slot] / cog.interactions.float))
  var tokens = newJArray()
  for name in sim.spec.tokens:
    tokens.add(%name)
  %*{
    "names": names,
    "scores": scoresNode,
    "win": win,
    "aliases": aliases,
    "camps": camps,
    "variant": sim.spec.name,
    "interactions": sim.idx.interactions,
    "perSeatInteractions": perSeat,
    "meanPayoff": meanPayoff,
    "exploitability": sim.idx.exploitabilityPoints(sim.spec),
    "coopRate": sim.idx.coopRate(sim.spec),
    "conventionCounts": sim.idx.conventionJson(),
    "tokens": tokens,
    "beats": sim.beat,
    "ticks": sim.tick,
    "reason": sim.reason,
    "ending": sim.ending
  }

proc summaryLine*(sim: Sim): string =
  "matrix-games: " & sim.spec.name & " " & $sim.beat & " beats, " &
    $sim.tick & " ticks, " & $sim.idx.interactions & " resolutions, " &
    sim.reason & "/" & sim.ending
