## The mutable world: the `Sim` object, its seeded construction, the state
## digest, event emission and the per-observer sight memory.
##
## Fork of paintbot's `src/ctf/sim_state.nim`. The seeded draws -- the spawner
## layout and the `fixed-pick` baseline's type -- all happen HERE, after
## `src/matrix_games.nim` has finalised the seed, which is paintbot's rule and
## the reason seed randomisation precedes `config.update`.

import std/[algorithm, json]
import sim_types, sim_config, matrices, arena_map, events, indices

type
  Frame* = object
    ## One recorded tick. Flat integer blocks, positional, no ids and no
    ## floats -- see the replay layout in the design note.
    t*: int
    c*: seq[int]             ## 8 x (x, y, facing, freeze)
    inv*: seq[int]           ## 8 x K
    tok*: seq[int]           ## one 0/1 per spawner, in spawners[] order
    sc*: seq[int]            ## 8 cumulative centipoints

  Sim* = object
    config*: GameConfig
    spec*: MatrixSpec
    rng*: Pcg32
    tick*: int
    beat*: int
    cogs*: seq[Cog]
    spawners*: seq[Spawner]
    zones*: seq[Zone]
    orders*: seq[IntentOrder]
    orderSources*: seq[OrderSource]
    haveOrder*: seq[bool]
    says*: seq[string]
    notes*: seq[string]
    names*: seq[string]      ## policy names -- spectator side ONLY
    policyKinds*: seq[string]
    connected*: seq[bool]
    memX*, memY*, memTick*: seq[seq[int]]   ## observer -> target sight memory
    events*: EventBuffer
    frames*: seq[Frame]
    shareSeries*: seq[seq[int]]
    scoreSeries*: seq[seq[int]]
    idx*: Indices
    lastLeader*: int
    done*: bool
    reason*: string
    ending*: string

const
  ## Opening pads. Eight distinct floor cells, none inside a token zone
  ## rectangle or the mixed band, so no seat starts the episode already
  ## standing on a spawner.
  OpeningCells*: array[Seats, array[2, int]] = [
    [9, 1], [14, 1], [9, 4], [14, 4],
    [5, 9], [18, 9], [3, 12], [20, 12]
  ]

proc shuffled(cells: seq[(int, int)], rng: var Pcg32, take: int):
    seq[(int, int)] =
  ## Fisher-Yates on the seeded stream, then a canonical (y, x) sort of the
  ## drawn subset so `spawners[]` -- and therefore the replay's `tok` block --
  ## has one stable order.
  var pool = cells
  var count = min(take, pool.len)
  for i in countdown(pool.high, 1):
    let j = rng.below(i + 1)
    let tmp = pool[i]
    pool[i] = pool[j]
    pool[j] = tmp
  var drawn = pool[0 ..< count]
  drawn.sort(proc (a, b: (int, int)): int =
    if a[1] != b[1]: cmp(a[1], b[1]) else: cmp(a[0], b[0]))
  drawn

proc buildZones*(spec: MatrixSpec): seq[Zone] =
  result.add(Zone(token: 0, x0: ZoneAx0, y0: ZoneAy0, x1: ZoneAx1,
    y1: ZoneAy1, cx: (ZoneAx0 + ZoneAx1) div 2, cy: (ZoneAy0 + ZoneAy1) div 2))
  result.add(Zone(token: 1, x0: ZoneBx0, y0: ZoneBy0, x1: ZoneBx1,
    y1: ZoneBy1, cx: (ZoneBx0 + ZoneBx1) div 2, cy: (ZoneBy0 + ZoneBy1) div 2))
  if spec.k >= 3:
    result.add(Zone(token: 2, x0: ZoneCx0, y0: ZoneCy0, x1: ZoneCx1,
      y1: ZoneCy1, cx: (ZoneCx0 + ZoneCx1) div 2,
      cy: (ZoneCy0 + ZoneCy1) div 2))
  result.add(Zone(token: -1, x0: 1, y0: MixedY0, x1: BoardW - 2, y1: MixedY1,
    cx: BoardW div 2, cy: MixedY0))

proc placeSpawners*(sim: var Sim) =
  ## Zone A (type 0), zone B (type 1), zone C (type 2, K == 3 only) each draw
  ## 16 spawners from their rectangle's free cells; the mixed scatter draws 12
  ## from the centre band and the n-th carries `n mod K`. Every spawner holds
  ## a token at t = 0.
  sim.spawners = @[]
  for zone in sim.zones:
    if zone.token < 0:
      continue
    let drawn = shuffled(freeCellsIn(zone.x0, zone.y0, zone.x1, zone.y1),
      sim.rng, ZoneSpawners)
    for cell in drawn:
      sim.spawners.add(Spawner(x: cell[0], y: cell[1], token: zone.token,
        hasToken: true, refillAt: -1))
  let mixed = shuffled(freeCellsIn(1, MixedY0, BoardW - 2, MixedY1),
    sim.rng, MixedSpawners)
  for index, cell in mixed:
    sim.spawners.add(Spawner(x: cell[0], y: cell[1],
      token: index mod sim.spec.k, hasToken: true, refillAt: -1))

proc endowment*(sim: Sim): seq[int] =
  result = newSeq[int](sim.spec.k)
  for i in 0 ..< sim.spec.k:
    result[i] = 1

proc initSim*(config: GameConfig): Sim =
  var cfg = config
  cfg.validate()
  result.config = cfg
  result.spec = matrixSpec(cfg.matrix)
  result.rng = initPcg32(cfg.seed)
  result.tick = 0
  result.beat = 0
  ## Seeded with the leader of the OPENING state, not -1. Every score is zero
  ## at tick 0 and `leader()` breaks the tie to slot 0, so a -1 seed made rule
  ## 9 fire on the very first tick and put a "Lead change" marker at t = 0 on
  ## every scrubber. Rule 9 emits when the leader differs from LAST TICK; at
  ## tick 0 there is no last tick, so the opening leader is the baseline.
  result.lastLeader = 0
  result.reason = ""
  result.ending = ""
  result.zones = buildZones(result.spec)
  result.placeSpawners()
  result.cogs = newSeq[Cog](Seats)
  for slot in 0 ..< Seats:
    var cog = Cog(
      slot: slot,
      x: OpeningCells[slot][0], y: OpeningCells[slot][1],
      facing: (if OpeningCells[slot][1] < BoardH div 2: 2 else: 0),
      inv: newSeq[int](result.spec.k),
      scoreCp: 0, freeze: 0, stepCd: 0, beamCd: 0, immune: 0,
      interactions: 0
    )
    for i in 0 ..< result.spec.k:
      cog.inv[i] = 1
    ## The `fixed-pick` baseline draws its type once, from the FINAL seed.
    cog.fixedType = (cfg.seed + slot) mod result.spec.k
    if cog.fixedType < 0:
      cog.fixedType += result.spec.k
    result.cogs[slot] = cog
  result.orders = newSeq[IntentOrder](Seats)
  result.orderSources = newSeq[OrderSource](Seats)
  result.haveOrder = newSeq[bool](Seats)
  result.says = newSeq[string](Seats)
  result.notes = newSeq[string](Seats)
  result.names = newSeq[string](Seats)
  result.policyKinds = newSeq[string](Seats)
  result.connected = newSeq[bool](Seats)
  for slot in 0 ..< Seats:
    result.orders[slot] = IntentOrder(intent: inHold, token: -1, target: -1)
    result.orderSources[slot] = osScripted
    result.names[slot] = aliasOf(slot)
    result.policyKinds[slot] = "scripted"
  result.memX = newSeq[seq[int]](Seats)
  result.memY = newSeq[seq[int]](Seats)
  result.memTick = newSeq[seq[int]](Seats)
  for observer in 0 ..< Seats:
    result.memX[observer] = newSeq[int](Seats)
    result.memY[observer] = newSeq[int](Seats)
    result.memTick[observer] = newSeq[int](Seats)
    for target in 0 ..< Seats:
      result.memX[observer][target] = result.cogs[target].x
      result.memY[observer][target] = result.cogs[target].y
      result.memTick[observer][target] = -1
  result.idx = initIndices(result.spec.k)

# ---- queries -----------------------------------------------------------

proc occupant*(sim: Sim, x, y: int): int =
  for slot, cog in sim.cogs:
    if cog.x == x and cog.y == y:
      return slot
  -1

proc spawnerAt*(sim: Sim, x, y: int): int =
  for index, spawner in sim.spawners:
    if spawner.x == x and spawner.y == y:
      return index
  -1

proc eligibleAgainst*(sim: Sim, a, b: int): bool =
  ## Every other cog, minus same-camp cogs in `bach-or-stravinsky`.
  if a == b or a < 0 or b < 0:
    return false
  if not sim.spec.crossCampOnly:
    return true
  rowCamp(a) != rowCamp(b)

proc visible*(sim: Sim, observer, target: int): bool =
  if observer == target:
    return true
  let a = sim.cogs[observer]
  let b = sim.cogs[target]
  if chebyshev(a.x, a.y, b.x, b.y) > sim.config.viewRadius:
    return false
  lineOfSight(a.x, a.y, b.x, b.y)

proc updateSight*(sim: var Sim) =
  for observer in 0 ..< Seats:
    for target in 0 ..< Seats:
      if sim.visible(observer, target):
        sim.memX[observer][target] = sim.cogs[target].x
        sim.memY[observer][target] = sim.cogs[target].y
        sim.memTick[observer][target] = sim.tick

proc mix*(inv: seq[int]): seq[int] =
  ## The rational strategy vector as PERMILLE, so no float enters sim state.
  var total = 0
  for value in inv:
    total += value
  result = newSeq[int](inv.len)
  if total <= 0:
    return
  for i in 0 ..< inv.len:
    result[i] = (inv[i] * 1000) div total

proc tokensLeft*(sim: Sim, zone: Zone): int =
  for spawner in sim.spawners:
    if not spawner.hasToken:
      continue
    if zone.token >= 0:
      if spawner.token == zone.token and spawner.x >= zone.x0 and
          spawner.x <= zone.x1 and spawner.y >= zone.y0 and
          spawner.y <= zone.y1:
        result.inc
    elif spawner.y >= zone.y0 and spawner.y <= zone.y1:
      result.inc

proc leader*(sim: Sim): int =
  result = 0
  for slot in 1 ..< sim.cogs.len:
    if sim.cogs[slot].scoreCp > sim.cogs[result].scoreCp:
      result = slot

# ---- digest ------------------------------------------------------------

proc hashIn(hash: var uint32, value: int) {.inline.} =
  let raw = cast[uint32](int32(value))
  for shift in [0'u32, 8'u32, 16'u32, 24'u32]:
    hash = hash xor ((raw shr shift) and 0xFF'u32)
    hash = hash * 16777619'u32

proc gameHash*(sim: Sim): uint32 =
  ## FNV-1a over every field the step reads. Two runs of the same seed and
  ## the same order script must produce the same digest after 600 ticks, in
  ## one process and across a fresh Sim -- `tests/test_sim.nim`.
  result = 2166136261'u32
  result.hashIn(sim.tick)
  result.hashIn(sim.beat)
  for cog in sim.cogs:
    result.hashIn(cog.x)
    result.hashIn(cog.y)
    result.hashIn(cog.facing)
    result.hashIn(cog.scoreCp)
    result.hashIn(cog.freeze)
    result.hashIn(cog.stepCd)
    result.hashIn(cog.beamCd)
    result.hashIn(cog.immune)
    result.hashIn(cog.interactions)
    for value in cog.inv:
      result.hashIn(value)
  for spawner in sim.spawners:
    result.hashIn(spawner.x)
    result.hashIn(spawner.y)
    result.hashIn(spawner.token)
    result.hashIn(if spawner.hasToken: 1 else: 0)
    result.hashIn(spawner.refillAt)

# ---- recording ---------------------------------------------------------

proc record*(sim: var Sim, kind: string, fields: JsonNode) =
  sim.events.add(kind, fields)

proc captureFrame*(sim: var Sim) =
  var frame = Frame(t: sim.tick)
  for cog in sim.cogs:
    frame.c.add(cog.x)
    frame.c.add(cog.y)
    frame.c.add(cog.facing)
    frame.c.add(cog.freeze)
    for value in cog.inv:
      frame.inv.add(value)
    frame.sc.add(cog.scoreCp)
  for spawner in sim.spawners:
    frame.tok.add(if spawner.hasToken: 1 else: 0)
  sim.frames.add(frame)

proc captureSeries*(sim: var Sim) =
  ## `share[t] = [t, permille of type 0, ...]` -- the share of ALL cogs'
  ## inventory mass carried in each token type. This is the convention
  ## histogram as a time series and it drives the momentum strip.
  var totals = newSeq[int](sim.spec.k)
  var grand = 0
  for cog in sim.cogs:
    for i in 0 ..< sim.spec.k:
      totals[i] += cog.inv[i]
      grand += cog.inv[i]
  var row = @[sim.tick]
  for i in 0 ..< sim.spec.k:
    row.add(if grand <= 0: 0 else: (totals[i] * 1000) div grand)
  sim.shareSeries.add(row)
  var scores = @[sim.tick]
  for cog in sim.cogs:
    scores.add(cog.scoreCp)
  sim.scoreSeries.add(scores)
