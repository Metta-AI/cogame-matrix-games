## The seven payoff matrices, as compile-time constants.
##
## Each variant names two integer K x K matrices, `rowPay` and `colPay`. For
## every symmetric variant `colPay = transpose(rowPay)`; only
## `bach-or-stravinsky` differs. The two best-response tables are DERIVED here
## once per variant and shipped in the observation, so a seat never has to
## work out the counter itself and the scripted `counter` baseline and the
## prompt agree by construction.

import std/[strutils]
import sim_types

type
  MatrixSpec* = object
    name*: string
    k*: int
    tokens*: seq[string]
    rowPay*: seq[seq[int]]
    colPay*: seq[seq[int]]
    coopToken*: int          ## -1 when the variant declares none
    crossCampOnly*: bool
    description*: string

const
  DefaultMatrix* = "running-with-scissors"
  MatrixNames* = [
    "running-with-scissors",
    "prisoners-dilemma",
    "chicken",
    "stag-hunt",
    "bach-or-stravinsky",
    "pure-coordination",
    "rationalizable-coordination"
  ]

proc transpose(m: seq[seq[int]]): seq[seq[int]] =
  result = newSeq[seq[int]](m[0].len)
  for j in 0 ..< m[0].len:
    result[j] = newSeq[int](m.len)
    for i in 0 ..< m.len:
      result[j][i] = m[i][j]

proc sym(name: string, tokens: seq[string], rowPay: seq[seq[int]],
    coopToken: int, description: string): MatrixSpec =
  MatrixSpec(name: name, k: tokens.len, tokens: tokens, rowPay: rowPay,
    colPay: transpose(rowPay), coopToken: coopToken, crossCampOnly: false,
    description: description)

proc matrixSpec*(name: string): MatrixSpec =
  ## The pinned table. Any name outside the seven is a hard error: `matrix` is
  ## an enum in the manifest, and a silent default would make a mistyped
  ## variant look like a working episode of a different game.
  case name.strip().toLowerAscii()
  of "running-with-scissors":
    sym("running-with-scissors", @["rock", "paper", "scissors"],
      @[@[0, -3, 3], @[3, 0, -3], @[-3, 3, 0]], -1,
      "Cyclic zero-sum: no fixed policy survives.")
  of "prisoners-dilemma":
    sym("prisoners-dilemma", @["cooperate", "defect"],
      @[@[3, 0], @[5, 1]], 0,
      "Conditional cooperation with strangers.")
  of "chicken":
    sym("chicken", @["dove", "hawk"],
      @[@[3, 1], @[4, 0]], 0,
      "Anti-coordination: who yields, with no words.")
  of "stag-hunt":
    sym("stag-hunt", @["stag", "hare"],
      @[@[4, 0], @[2, 2]], 0,
      "Assurance: risk- versus payoff-dominant equilibria.")
  of "bach-or-stravinsky":
    MatrixSpec(name: "bach-or-stravinsky", k: 2,
      tokens: @["bach", "stravinsky"],
      rowPay: @[@[3, 0], @[0, 2]],
      colPay: @[@[2, 0], @[0, 3]],
      coopToken: -1, crossCampOnly: true,
      description: "Asymmetric camps; interactions only cross-camp.")
  of "pure-coordination":
    sym("pure-coordination", @["red", "green", "blue"],
      @[@[1, 0, 0], @[0, 1, 0], @[0, 0, 1]], -1,
      "Three matches, all paying 1.")
  of "rationalizable-coordination":
    sym("rationalizable-coordination", @["bronze", "silver", "gold"],
      @[@[1, 0, 0], @[0, 2, 0], @[0, 0, 3]], -1,
      "Three matches, paying 1 / 2 / 3.")
  else:
    raise newException(MatrixGamesError, "unknown matrix: " & name)

proc bestResponseRow*(spec: MatrixSpec): seq[int] =
  ## `bestResponseRow[j] = argmax_i rowPay[i][j]`, ties to the lowest index.
  result = newSeq[int](spec.k)
  for j in 0 ..< spec.k:
    var column = newSeq[int](spec.k)
    for i in 0 ..< spec.k:
      column[i] = spec.rowPay[i][j]
    result[j] = argmaxLowest(column)

proc bestResponseCol*(spec: MatrixSpec): seq[int] =
  ## `bestResponseCol[i] = argmax_j colPay[i][j]`, ties to the lowest index.
  result = newSeq[int](spec.k)
  for i in 0 ..< spec.k:
    result[i] = argmaxLowest(spec.colPay[i])

proc tokenIndex*(spec: MatrixSpec, text: string): int =
  ## Case-insensitive token lookup; a bare integer index is also accepted,
  ## because a model that answers `"token": 1` is answering correctly.
  let wanted = text.strip().toLowerAscii()
  if wanted.len == 0:
    return -1
  for index, name in spec.tokens:
    if name == wanted:
      return index
  try:
    let asInt = parseInt(wanted)
    if asInt >= 0 and asInt < spec.k:
      return asInt
  except ValueError:
    discard
  -1

proc payoffCp*(spec: MatrixSpec, rowInv, colInv: seq[int]):
    tuple[rowCp, colCp: int] =
  ## The mixed payoff, in CENTIPOINTS:
  ##   rowPayCp = ( sum_i sum_j n_i * rowPay[i][j] * m_j * 100 ) div (N * M)
  ## `div` is Nim's integer division, truncating toward zero. That direction
  ## is pinned here because running-with-scissors has negative entries and a
  ## floor-vs-truncate difference would break determinism across hosts.
  var n = 0
  var m = 0
  for value in rowInv:
    n += value
  for value in colInv:
    m += value
  if n <= 0 or m <= 0:
    return (0, 0)
  var rowSum = 0
  var colSum = 0
  for i in 0 ..< spec.k:
    for j in 0 ..< spec.k:
      let weight = rowInv[i] * colInv[j]
      rowSum += weight * spec.rowPay[i][j]
      colSum += weight * spec.colPay[i][j]
  ((rowSum * 100) div (n * m), (colSum * 100) div (n * m))

proc pureValueAgainst*(spec: MatrixSpec, avgOppPermille: seq[int],
    asRow: bool): int =
  ## The value, in centipoints, of the best PURE strategy against a mixed
  ## opponent given as permille shares. Used by the exploitability index.
  var best = low(int)
  for own in 0 ..< spec.k:
    var total = 0
    for opp in 0 ..< spec.k:
      let pay = if asRow: spec.rowPay[own][opp] else: spec.colPay[opp][own]
      total += pay * avgOppPermille[opp]
    let cp = (total * 100) div 1000
    if cp > best:
      best = cp
  if best == low(int): 0 else: best
