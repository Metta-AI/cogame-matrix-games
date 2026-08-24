## The deterministic per-tick kernel: how one beat's intent becomes 50 ticks
## of move / turn / interact.
##
## A seat submits ONE intent per beat; this module executes it, tick by tick,
## with no randomness and no floats. Pathing is a breadth-first search over
## free cells whose ties break in the direction order N, E, S, W, so the same
## state always yields the same step. A cog with no legal step waits.
##
## The kernel is the game's executor, not a policy: it reads sim state
## directly. Policies -- the LLM seats and all five scripted baselines --
## read `buildObservation(slot)` and nothing else.

import sim_types, sim_config, matrices, sim_state, arena_map

proc rayCells*(sim: Sim, x, y, dir, reach: int): seq[(int, int)] =
  ## The beam ray: up to `reach` cells along `dir`, stopping at the first
  ## wall. The cell the shooter stands on is not part of it.
  var cx = x
  var cy = y
  for _ in 1 .. reach:
    cx += DirDx[dir]
    cy += DirDy[dir]
    if isWall(cx, cy):
      break
    result.add((cx, cy))

proc rayTarget*(sim: Sim, slot: int): int =
  ## The FIRST cog in the shooter's ray, or -1.
  let cog = sim.cogs[slot]
  for cell in rayCells(sim, cog.x, cog.y, cog.facing, sim.config.beamRange):
    let other = sim.occupant(cell[0], cell[1])
    if other >= 0 and other != slot:
      return other
  -1

proc alignedDir*(sim: Sim, slot, target: int): int =
  ## The cardinal direction along which `target` sits inside beam range with
  ## no wall between, or -1. Ties cannot happen: two cells cannot be aligned
  ## on both axes unless they are the same cell.
  if target < 0 or target == slot:
    return -1
  let me = sim.cogs[slot]
  let them = sim.cogs[target]
  for dir in 0 ..< 4:
    for cell in rayCells(sim, me.x, me.y, dir, sim.config.beamRange):
      let other = sim.occupant(cell[0], cell[1])
      if other == target:
        return dir
      if other >= 0:
        break
  -1

proc bfsDistances*(toX, toY: int): seq[int] =
  ## Breadth-first distance field over free cells, measured FROM the goal.
  ## -1 marks a wall or an unreachable cell. The field is a pure function of
  ## the map and the goal, so it is identical on every host.
  result = newSeq[int](BoardW * BoardH)
  for index in 0 ..< result.len:
    result[index] = -1
  if isWall(toX, toY):
    return
  var queue = newSeq[(int, int)]()
  result[toY * BoardW + toX] = 0
  queue.add((toX, toY))
  var head = 0
  while head < queue.len:
    let cell = queue[head]
    head.inc
    let here = result[cell[1] * BoardW + cell[0]]
    for dir in 0 ..< 4:
      let nx = cell[0] + DirDx[dir]
      let ny = cell[1] + DirDy[dir]
      if isWall(nx, ny):
        continue
      let key = ny * BoardW + nx
      if result[key] >= 0:
        continue
      result[key] = here + 1
      queue.add((nx, ny))

proc bfsStep*(sim: Sim, fromX, fromY, toX, toY: int): int =
  ## The direction of the first step of a shortest path from (fromX, fromY)
  ## to (toX, toY) over free cells, or -1 when the goal is unreachable or
  ## already reached. Ties break in the direction order N, E, S, W.
  ##
  ## Cells currently holding another cog are AVOIDED, and when no free
  ## neighbour strictly reduces the distance the cog takes the best free
  ## sidestep instead. Without that, two cogs walking into each other lock
  ## solid for the rest of the episode -- each waiting for a cell the other is
  ## standing on -- and a seat finishes with zero resolutions.
  ## `tests/test_indices.nim` gate (a) is what caught it.
  if fromX == toX and fromY == toY:
    return -1
  let dist = bfsDistances(toX, toY)
  let here = dist[fromY * BoardW + fromX]
  if here < 0:
    return -1
  result = -1
  var best = here
  for dir in 0 ..< 4:
    let nx = fromX + DirDx[dir]
    let ny = fromY + DirDy[dir]
    if isWall(nx, ny) or sim.occupant(nx, ny) >= 0:
      continue
    let d = dist[ny * BoardW + nx]
    if d >= 0 and d < best:
      best = d
      result = dir
  if result >= 0:
    return
  ## Nothing gets closer and is free: take the least-bad free sidestep so the
  ## pair unlocks on the next tick.
  var sideBest = here + 1
  for dir in 0 ..< 4:
    let nx = fromX + DirDx[dir]
    let ny = fromY + DirDy[dir]
    if isWall(nx, ny) or sim.occupant(nx, ny) >= 0:
      continue
    let d = dist[ny * BoardW + nx]
    if d >= 0 and d <= sideBest:
      sideBest = d
      result = dir

proc nearestTokenCell*(sim: Sim, slot, token: int): (int, int) =
  ## The cell holding a token of `token` nearest to the seat by Chebyshev
  ## distance; ties go to the lowest y, then the lowest x. (-1, -1) when the
  ## type has no live token anywhere.
  let me = sim.cogs[slot]
  var best = (-1, -1)
  var bestDist = high(int)
  for spawner in sim.spawners:
    if not spawner.hasToken or spawner.token != token:
      continue
    let dist = chebyshev(me.x, me.y, spawner.x, spawner.y)
    if dist < bestDist or
        (dist == bestDist and
          (spawner.y < best[1] or (spawner.y == best[1] and
            spawner.x < best[0]))):
      bestDist = dist
      best = (spawner.x, spawner.y)
  best

proc nearestOtherCog*(sim: Sim, slot: int): int =
  var best = -1
  var bestDist = high(int)
  let me = sim.cogs[slot]
  for other in 0 ..< sim.cogs.len:
    if other == slot:
      continue
    let dist = chebyshev(me.x, me.y, sim.cogs[other].x, sim.cogs[other].y)
    if dist < bestDist:
      bestDist = dist
      best = other
  best

proc denyTokenCell*(sim: Sim, slot, token: int): (int, int) =
  ## The cell holding a token of `token` NEAREST TO the nearest other cog --
  ## the point of `deny` is to take the token that rival is about to reach.
  let rival = nearestOtherCog(sim, slot)
  if rival < 0:
    return nearestTokenCell(sim, slot, token)
  let them = sim.cogs[rival]
  var best = (-1, -1)
  var bestDist = high(int)
  for spawner in sim.spawners:
    if not spawner.hasToken or spawner.token != token:
      continue
    let dist = chebyshev(them.x, them.y, spawner.x, spawner.y)
    if dist < bestDist or
        (dist == bestDist and
          (spawner.y < best[1] or (spawner.y == best[1] and
            spawner.x < best[0]))):
      bestDist = dist
      best = (spawner.x, spawner.y)
  best

proc zoneCentre*(sim: Sim, token: int): (int, int) =
  for zone in sim.zones:
    if zone.token == token:
      return (zone.cx, zone.cy)
  (BoardW div 2, BoardH div 2)

proc stepToward(sim: Sim, slot, toX, toY: int): Micro =
  let me = sim.cogs[slot]
  let dir = bfsStep(sim, me.x, me.y, toX, toY)
  if dir < 0:
    return Micro(kind: mkWait, dir: me.facing)
  Micro(kind: mkStep, dir: dir)

proc avoidStep(sim: Sim, slot, target: int): Micro =
  ## Step to the adjacent free cell that maximises Chebyshev distance from
  ## `target`, never entering a cell within 2 of it. Ties go to N, E, S, W.
  let me = sim.cogs[slot]
  let them = sim.cogs[target]
  var bestDir = -1
  var bestDist = chebyshev(me.x, me.y, them.x, them.y)
  for dir in 0 ..< 4:
    let nx = me.x + DirDx[dir]
    let ny = me.y + DirDy[dir]
    if isWall(nx, ny) or sim.occupant(nx, ny) >= 0:
      continue
    let dist = chebyshev(nx, ny, them.x, them.y)
    if dist < 2:
      continue
    if dist > bestDist:
      bestDist = dist
      bestDir = dir
  if bestDir < 0:
    return Micro(kind: mkWait, dir: me.facing)
  Micro(kind: mkStep, dir: bestDir)

proc facingToward(fromX, fromY, toX, toY: int): int =
  ## The cardinal direction that most reduces the gap; ties to the vertical
  ## axis first, keeping the N, E, S, W order.
  let dx = toX - fromX
  let dy = toY - fromY
  if abs(dy) >= abs(dx):
    if dy < 0: 0 else: 2
  else:
    if dx > 0: 1 else: 3

proc sweepStep(sim: Sim, slot: int): Micro =
  ## A hunter that reaches its target's last known cell and finds nobody has
  ## to keep looking, or the room deadlocks: two cogs each standing on the
  ## other's stale opening cell never see each other again, and a seat can
  ## finish an episode with zero resolutions (`tests/test_indices.nim` gate
  ## (a) catches exactly that). The sweep is deterministic and leaks nothing:
  ## it walks to the centre of the mixed band -- the busiest cell in the yard
  ## -- and, once there, turns one quarter every four ticks to scan.
  let me = sim.cogs[slot]
  let dir = bfsStep(sim, me.x, me.y, BoardW div 2, MixedY0)
  if dir >= 0:
    return Micro(kind: mkStep, dir: dir)
  if sim.tick mod 4 == 0:
    return Micro(kind: mkTurn, dir: (me.facing + 1) mod 4)
  Micro(kind: mkWait, dir: me.facing)

proc microFor*(sim: Sim, slot: int): Micro =
  ## One desired micro-action for one cog on one tick, evaluated against the
  ## state as it stood at the START of rule 3.
  let me = sim.cogs[slot]
  if me.freeze > 0:
    return Micro(kind: mkWait, dir: me.facing)
  let order = sim.orders[slot]
  case order.intent
  of inGather:
    let token = clamp(order.token, 0, sim.spec.k - 1)
    if me.inv[token] >= sim.config.tokenCap:
      let centre = zoneCentre(sim, token)
      return stepToward(sim, slot, centre[0], centre[1])
    let cell = nearestTokenCell(sim, slot, token)
    if cell[0] < 0:
      let centre = zoneCentre(sim, token)
      return stepToward(sim, slot, centre[0], centre[1])
    stepToward(sim, slot, cell[0], cell[1])
  of inDeny:
    let token = clamp(order.token, 0, sim.spec.k - 1)
    let cell = denyTokenCell(sim, slot, token)
    if cell[0] < 0:
      let centre = zoneCentre(sim, token)
      return stepToward(sim, slot, centre[0], centre[1])
    stepToward(sim, slot, cell[0], cell[1])
  of inHunt:
    let target = order.target
    if target < 0 or target >= sim.cogs.len or target == slot:
      return Micro(kind: mkWait, dir: me.facing)
    let dir = alignedDir(sim, slot, target)
    if dir >= 0:
      if me.facing != dir:
        return Micro(kind: mkTurn, dir: dir)
      if me.beamCd == 0:
        return Micro(kind: mkFire, dir: me.facing)
      return Micro(kind: mkWait, dir: me.facing)
    let known = (sim.memX[slot][target], sim.memY[slot][target])
    let toward = bfsStep(sim, me.x, me.y, known[0], known[1])
    if toward >= 0:
      return Micro(kind: mkStep, dir: toward)
    sweepStep(sim, slot)
  of inAvoid:
    let target = order.target
    if target < 0 or target >= sim.cogs.len or target == slot:
      return Micro(kind: mkWait, dir: me.facing)
    avoidStep(sim, slot, target)
  of inHold:
    if sim.rayTarget(slot) >= 0 and me.beamCd == 0:
      return Micro(kind: mkFire, dir: me.facing)
    if sim.tick mod 4 == 0:
      let other = nearestOtherCog(sim, slot)
      if other >= 0 and
          chebyshev(me.x, me.y, sim.cogs[other].x, sim.cogs[other].y) <= 6:
        let dir = facingToward(me.x, me.y, sim.cogs[other].x,
          sim.cogs[other].y)
        if dir != me.facing:
          return Micro(kind: mkTurn, dir: dir)
    Micro(kind: mkWait, dir: me.facing)
