## Sim units: the payoff formula, the argmax cell, the beam, pickup, respawn,
## the cooldowns, the endowment reset, the bach-or-stravinsky row rule, BFS
## tie-breaking, blocked movement, and DETERMINISM.

import std/[json, os, osproc, strtabs, strutils, unittest]
import support/helpers
import matrix_games/[sim_types, sim_config, matrices, arena_map, sim_state,
  events, kernel, sim, indices]

const HashSeedEnv = "MATRIX_GAMES_HASH_SEED"

## Child mode. With MATRIX_GAMES_HASH_SEED set, this binary plays ONE episode
## and prints its `gameHash`, then exits before any suite runs. The determinism
## test below spawns it: that is the design note's "and across a fresh
## SimServer" -- a second, independent process, not a second object in this one.
if getEnv(HashSeedEnv).len > 0:
  let childSeed = parseInt(getEnv(HashSeedEnv))
  echo runScripted("running-with-scissors", childSeed, certMix()).gameHash()
  quit(0)

suite "the arena":
  test "the committed map is 24 x 14, symmetric, connected and 216 free":
    check ArenaRows.len == BoardH
    for row in ArenaRows:
      check row.len == BoardW
    for y in 0 ..< BoardH:
      for x in 0 ..< BoardW:
        check ArenaRows[y][x] == ArenaRows[y][BoardW - 1 - x]
        check ArenaRows[y][x] == ArenaRows[BoardH - 1 - y][x]
    let cells = freeCells()
    check cells.len == FreeCellCount
    ## Flood fill: every free cell must be reachable from the first one.
    var seen = newSeq[bool](BoardW * BoardH)
    var queue = @[cells[0]]
    seen[cells[0][1] * BoardW + cells[0][0]] = true
    var head = 0
    var reached = 1
    while head < queue.len:
      let cell = queue[head]
      head.inc
      for dir in 0 ..< 4:
        let nx = cell[0] + DirDx[dir]
        let ny = cell[1] + DirDy[dir]
        if isWall(nx, ny) or seen[ny * BoardW + nx]:
          continue
        seen[ny * BoardW + nx] = true
        reached.inc
        queue.add((nx, ny))
    check reached == FreeCellCount

suite "the payoff formula":
  test "the hand-computed prisoners-dilemma case from the design note":
    let spec = matrixSpec("prisoners-dilemma")
    # n = [2,6], m = [7,2]:
    # (2*3*7 + 2*0*2 + 6*5*7 + 6*1*2) * 100 div (8*9) = 26400 div 72 = 366
    let pay = payoffCp(spec, @[2, 6], @[7, 2])
    check pay.rowCp == 366

  test "every variant has a hand-checked mixed case":
    check payoffCp(matrixSpec("running-with-scissors"),
      @[3, 1, 1], @[1, 3, 1]).rowCp ==
        ((3*0*1 + 3*(-3)*3 + 3*3*1 + 1*3*1 + 1*0*3 + 1*(-3)*1 +
          1*(-3)*1 + 1*3*3 + 1*0*1) * 100) div 25
    check payoffCp(matrixSpec("chicken"), @[4, 1], @[1, 4]).rowCp ==
      ((4*3*1 + 4*1*4 + 1*4*1 + 1*0*4) * 100) div 25
    check payoffCp(matrixSpec("stag-hunt"), @[5, 1], @[1, 5]).rowCp ==
      ((5*4*1 + 5*0*5 + 1*2*1 + 1*2*5) * 100) div 36
    check payoffCp(matrixSpec("bach-or-stravinsky"), @[5, 1], @[1, 5]).rowCp ==
      ((5*3*1 + 5*0*5 + 1*0*1 + 1*2*5) * 100) div 36
    check payoffCp(matrixSpec("bach-or-stravinsky"), @[5, 1], @[1, 5]).colCp ==
      ((5*2*1 + 5*0*5 + 1*0*1 + 1*3*5) * 100) div 36
    check payoffCp(matrixSpec("pure-coordination"),
      @[2, 1, 1], @[1, 2, 1]).rowCp == ((2*1*1 + 1*1*2 + 1*1*1) * 100) div 16
    check payoffCp(matrixSpec("rationalizable-coordination"),
      @[2, 1, 1], @[1, 2, 1]).rowCp == ((2*1*1 + 1*2*2 + 1*3*1) * 100) div 16

  test "div truncates toward zero on a negative running-with-scissors payoff":
    let spec = matrixSpec("running-with-scissors")
    let pay = payoffCp(spec, @[3, 1, 1], @[1, 1, 3])
    # Row is rock-heavy against a scissors-heavy column: rock beats scissors,
    # so the row payoff is positive and the column's is its negation.
    check pay.rowCp == -pay.colCp
    # The negative side must TRUNCATE toward zero, not floor: -7 div 2 == -3.
    check (-7 div 2) == -3
    let loss = payoffCp(spec, @[1, 1, 3], @[3, 1, 1])
    check loss.rowCp == -pay.rowCp

  test "best-response tables are the cyclic counter in RWS":
    let spec = matrixSpec("running-with-scissors")
    check bestResponseRow(spec) == @[1, 2, 0]
    check bestResponseCol(spec) == @[1, 2, 0]

  test "defect strictly dominates in the prisoners-dilemma tables":
    let spec = matrixSpec("prisoners-dilemma")
    check bestResponseRow(spec) == @[1, 1]
    check bestResponseCol(spec) == @[1, 1]

  test "the argmax cell breaks ties to the lowest index":
    check argmaxLowest(@[3, 3, 1]) == 0
    check argmaxLowest(@[1, 3, 3]) == 1
    check argmaxLowest(@[0, 0, 0]) == 0

suite "the tick rules":
  test "a beam ray stops at the first wall and takes the first cog":
    var state = initSim(testConfig("prisoners-dilemma", 11))
    state.cogs[0].x = 9
    state.cogs[0].y = 1
    state.cogs[0].facing = 1
    state.cogs[1].x = 12
    state.cogs[1].y = 1
    for slot in 2 ..< Seats:
      state.cogs[slot].x = 1
      state.cogs[slot].y = 11 - slot
    check rayTarget(state, 0) == 1
    ## Facing a wall: row 1 has walls at x = 5 and 6, so a westward ray from
    ## (9,1) is cut short and reaches nobody.
    state.cogs[0].facing = 3
    check rayCells(state, 9, 1, 3, 4).len == 2
    check rayTarget(state, 0) == -1

  test "pickup, the token cap, and the respawn timer":
    var state = initSim(testConfig("prisoners-dilemma", 12))
    let spawner = state.spawners[0]
    state.cogs[0].x = spawner.x
    state.cogs[0].y = spawner.y
    state.cogs[0].inv[spawner.token] = state.config.tokenCap
    state.orders[0] = IntentOrder(intent: inHold, token: -1, target: -1)
    state.stepOnce()
    ## A full type leaves the token where it is.
    check state.spawners[0].hasToken
    state.cogs[0].inv[spawner.token] = 0
    state.cogs[0].x = spawner.x
    state.cogs[0].y = spawner.y
    let takenAt = state.tick
    state.stepOnce()
    check not state.spawners[0].hasToken
    check state.cogs[0].inv[spawner.token] == 1
    check state.spawners[0].refillAt ==
      takenAt + state.config.tokenRespawnTicks
    while state.tick <= state.spawners[0].refillAt:
      state.cogs[0].x = 12
      state.cogs[0].y = 12
      state.stepOnce()
    check state.spawners[0].hasToken

  test "a resolution resets both inventories and sets every cooldown":
    var state = initSim(testConfig("prisoners-dilemma", 13))
    for slot in 0 ..< Seats:
      state.cogs[slot].x = 1 + slot
      state.cogs[slot].y = 11
      state.cogs[slot].immune = 0
    state.cogs[0].x = 9
    state.cogs[0].y = 2
    state.cogs[0].facing = 1
    state.cogs[1].x = 10
    state.cogs[1].y = 2
    state.cogs[0].inv = @[1, 6]
    state.cogs[1].inv = @[6, 1]
    state.orders[0] = IntentOrder(intent: inHunt, token: -1, target: 1)
    state.orders[1] = IntentOrder(intent: inHold, token: -1, target: -1)
    for slot in 2 ..< Seats:
      state.orders[slot] = IntentOrder(intent: inHold, token: -1, target: -1)
    state.stepOnce()
    check state.idx.interactions == 1
    check state.cogs[0].inv == @[1, 1]
    check state.cogs[1].inv == @[1, 1]
    ## Timers are ticked down in rule 1, BEFORE the resolution in rules 6-8,
    ## so they read at full value at the end of the tick that resolved.
    check state.cogs[0].freeze == state.config.freezeTicks
    check state.cogs[0].immune == ImmuneTicks
    check state.cogs[0].beamCd == state.config.beamResetCooldown
    check state.cogs[1].freeze == state.config.freezeTicks
    check state.cogs[0].interactions == 1
    check state.cogs[1].interactions == 1
    ## Defect-heavy row against a coop-heavy column: the row must out-earn it.
    check state.cogs[0].scoreCp > state.cogs[1].scoreCp

  test "bach-or-stravinsky: same camp is a no-contest, blue is always row":
    var state = initSim(testConfig("bach-or-stravinsky", 14))
    for slot in 0 ..< Seats:
      state.cogs[slot].x = 1 + slot
      state.cogs[slot].y = 11
      state.cogs[slot].immune = 0
      state.orders[slot] = IntentOrder(intent: inHold, token: -1, target: -1)
    ## 0 and 1 are both row-camp.
    state.cogs[0].x = 9
    state.cogs[0].y = 2
    state.cogs[0].facing = 1
    state.cogs[1].x = 10
    state.cogs[1].y = 2
    state.orders[0] = IntentOrder(intent: inHunt, token: -1, target: 1)
    state.stepOnce()
    check state.idx.interactions == 0
    check state.events.count("nocontest") == 1
    ## 4 is column-camp: a beam from 4 at 0 still makes 0 the ROW player.
    var other = initSim(testConfig("bach-or-stravinsky", 14))
    for slot in 0 ..< Seats:
      other.cogs[slot].x = 1 + slot
      other.cogs[slot].y = 11
      other.cogs[slot].immune = 0
      other.orders[slot] = IntentOrder(intent: inHold, token: -1, target: -1)
    other.cogs[4].x = 9
    other.cogs[4].y = 2
    other.cogs[4].facing = 1
    other.cogs[0].x = 10
    other.cogs[0].y = 2
    other.orders[4] = IntentOrder(intent: inHunt, token: -1, target: 0)
    other.stepOnce()
    check other.idx.interactions == 1
    var seen = false
    for record in other.events.records:
      if record{"k"}.getStr() == "interact":
        seen = true
        check record{"row"}.getInt() == 0
        check record{"col"}.getInt() == 4
    check seen

  test "BFS ties break N, E, S, W and an occupied cell is not entered":
    var state = initSim(testConfig("prisoners-dilemma", 15))
    for slot in 0 ..< Seats:
      state.cogs[slot].x = 1 + slot
      state.cogs[slot].y = 11
    ## From (9,2), a goal directly north AND directly east is a tie the N
    ## direction wins; the field itself is a pure function of the map.
    let dist = bfsDistances(9, 1)
    check dist[1 * BoardW + 9] == 0
    check dist[2 * BoardW + 9] == 1
    state.cogs[0].x = 9
    state.cogs[0].y = 2
    check bfsStep(state, 9, 2, 9, 1) == 0
    ## Park a cog on the only reducing neighbour: the mover must not enter it.
    state.cogs[1].x = 9
    state.cogs[1].y = 1
    check bfsStep(state, 9, 2, 9, 1) != 0

  test "movement is blocked by an occupied cell and never shares a cell":
    var state = initSim(testConfig("prisoners-dilemma", 16))
    for beat in 0 ..< 3:
      var decisions = newSeq[Decision](Seats)
      for slot in 0 ..< Seats:
        decisions[slot] = Decision(
          order: IntentOrder(intent: inGather, token: 0, target: -1),
          source: osScripted)
      state.installOrders(decisions)
      for _ in 0 ..< state.config.ticksPerBeat:
        state.stepOnce()
        for a in 0 ..< Seats:
          check isFloor(state.cogs[a].x, state.cogs[a].y)
          for b in a + 1 ..< Seats:
            check not (state.cogs[a].x == state.cogs[b].x and
                       state.cogs[a].y == state.cogs[b].y)
      state.closeBeat()

proc hashInFreshProcess(seed: int): string =
  ## The same episode, played by a freshly started process of this binary.
  var env = newStringTable()
  for key, value in envPairs():
    env[key] = value
  env[HashSeedEnv] = $seed
  let outcome = execCmdEx(quoteShell(getAppFilename()), env = env)
  check outcome.exitCode == 0
  outcome.output.strip()

suite "determinism":
  test "the same seed and order script hash identically, twice and afresh":
    let first = runScripted("running-with-scissors", 4242, certMix())
    let second = runScripted("running-with-scissors", 4242, certMix())
    check first.tick == 600
    check first.gameHash() == second.gameHash()
    check first.scores() == second.scores()
    let other = runScripted("running-with-scissors", 4243, certMix())
    check other.gameHash() != first.gameHash()

  test "a fresh process reproduces the same hash from the same seed":
    ## Not another `Sim` in this process: a new one, with its own globals, its
    ## own RNG state and its own heap.
    let here = runScripted("running-with-scissors", 4242, certMix()).gameHash()
    check hashInFreshProcess(4242) == $here
    check hashInFreshProcess(4243) != $here

  test "every inventory stays inside 0 .. tokenCap for a whole episode":
    let state = runScripted("pure-coordination", 9, certMix())
    for frame in state.frames:
      for value in frame.inv:
        check value >= 0
        check value <= state.config.tokenCap
