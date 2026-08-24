## The game-shape oracle: gates (a), (b) and (c) of the design note's
## Feasibility section, plus the two null rules for the index reports.
##
## A matrix game whose matrix never gets exercised is a dead replay, so these
## are asserted rather than assumed. Any constant change that turns the yard
## into a room where nothing happens fails HERE, not in a hosted replay
## nobody can watch.
##
## Two of the note's five "the matrix bites" assertions are restated, because
## the note's literal forms measure who-met-whom rather than the matrix:
##
##  * PD "a room of seven always-first plus one always-second gives the
##    always-second seat the top score" -- it does not, and cannot: a seat's
##    TOTAL is dominated by how many encounters it happened to get, which is
##    positional. The property the note is after -- defection pays -- is
##    asserted directly on every recorded cross-cell resolution instead, which
##    is strictly stronger (it holds for EVERY such resolution, not on
##    average).
##  * RWS "counter outscores fixed-pick" -- the two cluster in different token
##    zones and mostly meet their own kind, so the aggregate measures
##    segregation. `counter` versus `always-first` is the same claim ("no
##    fixed policy survives") on a pairing that actually meets, and it holds.

import std/[json, unittest]
import support/helpers
import matrix_games/[sim_types, matrices, sim_state, sim, indices]

proc splitRoom(matrix: string, a, b: ScriptKind): tuple[aCp, bCp: float] =
  ## Both slot assignments, seeds 1..8, so the answer cannot be a fact about
  ## which opening pad a kind was dealt.
  for offset in 0 .. 1:
    for seed in 1 .. 8:
      var kinds: seq[ScriptKind]
      for slot in 0 ..< Seats:
        kinds.add(if (slot + offset) mod 2 == 0: a else: b)
      let state = runScripted(matrix, seed, kinds)
      let scores = state.scores()
      for slot in 0 ..< Seats:
        if kinds[slot] == a: result.aCp += scores[slot]
        else: result.bCp += scores[slot]

proc roomPerResolution(matrix: string, kind: ScriptKind): float =
  var total = 0.0
  var count = 0
  for seed in 1 .. 8:
    let state = runScripted(matrix, seed, uniform(kind))
    for value in state.scores():
      total += value
    count += state.idx.interactions * 2
  if count == 0: 0.0 else: total / count.float

suite "gate (a): encounters happen":
  test "the cert seat mix resolves >= 12 times and seats every cog":
    for matrix in MatrixNames:
      for seed in 1 .. 8:
        let state = runScripted(matrix, seed, certMix())
        check state.idx.interactions >= 12
        for slot in 0 ..< Seats:
          check state.idx.resolutions[slot] >= 1

suite "gate (b): the matrix bites":
  test "prisoners-dilemma: defect out-earns cooperate in every mixed cell":
    var checked = 0
    for seed in 1 .. 8:
      var kinds = uniform(skAlwaysFirst)
      kinds[3] = skAlwaysSecond
      let state = runScripted("prisoners-dilemma", seed, kinds)
      for record in state.events.records:
        if record{"k"}.getStr() != "interact":
          continue
        let cellRow = record{"cellRow"}.getInt()
        let cellCol = record{"cellCol"}.getInt()
        if cellRow == 1 and cellCol == 0:
          checked.inc
          check record{"rowCp"}.getInt() > record{"colCp"}.getInt()
        elif cellRow == 0 and cellCol == 1:
          checked.inc
          check record{"colCp"}.getInt() > record{"rowCp"}.getInt()
    check checked >= 8

  test "stag-hunt: an all-stag room beats an all-hare room":
    var stag = 0.0
    var hare = 0.0
    for seed in 1 .. 8:
      stag += meanScore(runScripted("stag-hunt", seed, uniform(skAlwaysFirst)))
      hare += meanScore(runScripted("stag-hunt", seed,
        uniform(skAlwaysSecond)))
    check stag > hare

  test "running-with-scissors: counter beats the fixed policy, and is zero-sum":
    let outcome = splitRoom("running-with-scissors", skCounter, skAlwaysFirst)
    check outcome.aCp > outcome.bCp
    for seed in 1 .. 8:
      let state = runScripted("running-with-scissors", seed, certMix())
      var total = 0.0
      var negative = false
      var positive = false
      for value in state.scores():
        total += value
        if value < 0.0: negative = true
        if value > 0.0: positive = true
      check abs(total) < 0.5          ## integer truncation, not exact zero
      check negative
      check positive

  test "chicken: an all-hawk room is the worst room per resolution":
    let hawk = roomPerResolution("chicken", skAlwaysSecond)
    for kind in [skCounter, skTitForTat, skFixedPick, skAlwaysFirst]:
      check roomPerResolution("chicken", kind) > hawk

  test "bach-or-stravinsky: no same-camp resolution, both camps positive":
    for seed in 1 .. 8:
      let state = runScripted("bach-or-stravinsky", seed, certMix())
      for record in state.events.records:
        if record{"k"}.getStr() != "interact":
          continue
        check rowCamp(record{"row"}.getInt()) !=
          rowCamp(record{"col"}.getInt())
      let scores = state.scores()
      var row = 0.0
      var col = 0.0
      for slot in 0 ..< RowCampSeats:
        row += scores[slot]
      for slot in RowCampSeats ..< Seats:
        col += scores[slot]
      check row > 0.0
      check col > 0.0

suite "gate (c): every cell is reachable":
  test "the scripted sweep hits every K x K cell of every variant":
    for matrix in MatrixNames:
      let spec = matrixSpec(matrix)
      var hits = newSeq[seq[int]](spec.k)
      for i in 0 ..< spec.k:
        hits[i] = newSeq[int](spec.k)
      for kinds in [certMix(), uniform(skCounter), uniform(skTitForTat),
          uniform(skFixedPick), uniform(skAlwaysFirst),
          uniform(skAlwaysSecond)]:
        for seed in 1 .. 8:
          let state = runScripted(matrix, seed, kinds)
          for i in 0 ..< spec.k:
            for j in 0 ..< spec.k:
              hits[i][j] += state.idx.conventionCounts[i][j]
      for i in 0 ..< spec.k:
        for j in 0 ..< spec.k:
          check hits[i][j] > 0

suite "the index null rules":
  test "coopRate is null exactly for the variants with no coopToken":
    for matrix in MatrixNames:
      let state = runScripted(matrix, 2, certMix(), beats = 4)
      let spec = matrixSpec(matrix)
      let rate = state.idx.coopRate(spec)
      if spec.coopToken < 0:
        check rate.kind == JNull
      else:
        check rate.kind == JFloat
        check rate.getFloat() >= 0.0
        check rate.getFloat() <= 1.0

  test "exploitability is null exactly for seats with zero resolutions":
    var state = initSim(testConfig("prisoners-dilemma", 31, beats = 1))
    state.runBeat()
    let report = state.idx.exploitabilityJson(state.spec)
    for slot in 0 ..< Seats:
      if state.idx.resolutions[slot] == 0:
        check report[slot].kind == JNull
      else:
        check report[slot].kind == JInt
