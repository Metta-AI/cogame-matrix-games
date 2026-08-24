## The three per-room indices the design note asks the sim to compute, carry
## in the replay and show in the viewer.
##
## 1. Convention histogram -- `conventionCounts[i][j]`, how many resolutions
##    hit cell (i, j). Drawn as the matrix panel's heat.
## 2. Cooperation rate -- for variants that declare a `coopToken`, the
##    fraction of all inventory mass carried into resolutions that was the
##    coop token. `null` for the four variants that declare none.
## 3. Exploitability, per seat -- `bestPureValue(avgOpp) - realised`, in
##    points. Higher means more money was left on the table. `null` for a
##    seat with zero resolutions.
##
## Everything accumulates in integers; only the final report converts.

import std/[json]
import sim_types, matrices

type
  Indices* = object
    k*: int
    conventionCounts*: seq[seq[int]]
    coopMass*: int
    totalMass*: int
    interactions*: int
    resolutions*: seq[int]        ## per seat
    rowSides*: seq[int]           ## per seat, how often it was the row player
    oppMixSum*: seq[seq[int]]     ## per seat, summed opponent permille
    realisedCpSum*: seq[int]      ## per seat, summed payoff in centipoints

proc initIndices*(k: int): Indices =
  result.k = k
  result.conventionCounts = newSeq[seq[int]](k)
  for i in 0 ..< k:
    result.conventionCounts[i] = newSeq[int](k)
  result.resolutions = newSeq[int](Seats)
  result.rowSides = newSeq[int](Seats)
  result.realisedCpSum = newSeq[int](Seats)
  result.oppMixSum = newSeq[seq[int]](Seats)
  for slot in 0 ..< Seats:
    result.oppMixSum[slot] = newSeq[int](k)

proc noteResolution*(idx: var Indices, spec: MatrixSpec, rowSeat, colSeat: int,
    rowInv, colInv, rowMix, colMix: seq[int], cellRow, cellCol: int,
    rowCp, colCp: int) =
  idx.interactions.inc
  idx.conventionCounts[cellRow][cellCol].inc
  if spec.coopToken >= 0:
    idx.coopMass += rowInv[spec.coopToken] + colInv[spec.coopToken]
  for i in 0 ..< idx.k:
    idx.totalMass += rowInv[i] + colInv[i]
  idx.resolutions[rowSeat].inc
  idx.rowSides[rowSeat].inc
  idx.realisedCpSum[rowSeat] += rowCp
  idx.resolutions[colSeat].inc
  idx.realisedCpSum[colSeat] += colCp
  for i in 0 ..< idx.k:
    idx.oppMixSum[rowSeat][i] += colMix[i]
    idx.oppMixSum[colSeat][i] += rowMix[i]

proc coopRate*(idx: Indices, spec: MatrixSpec): JsonNode =
  if spec.coopToken < 0 or idx.totalMass <= 0:
    return newJNull()
  %(idx.coopMass.float / idx.totalMass.float)

proc exploitabilityCp*(idx: Indices, spec: MatrixSpec, slot: int): int =
  ## Centipoints left on the table. Callers must check `resolutions[slot] > 0`
  ## first; a seat with none reports `null`, not zero.
  let count = idx.resolutions[slot]
  if count <= 0:
    return 0
  var avgOpp = newSeq[int](idx.k)
  for i in 0 ..< idx.k:
    avgOpp[i] = idx.oppMixSum[slot][i] div count
  let asRow = idx.rowSides[slot] * 2 >= count
  let best = pureValueAgainst(spec, avgOpp, asRow)
  best - (idx.realisedCpSum[slot] div count)

proc exploitabilityJson*(idx: Indices, spec: MatrixSpec): JsonNode =
  result = newJArray()
  for slot in 0 ..< Seats:
    if idx.resolutions[slot] <= 0:
      result.add(newJNull())
    else:
      result.add(%exploitabilityCp(idx, spec, slot))

proc exploitabilityPoints*(idx: Indices, spec: MatrixSpec): JsonNode =
  result = newJArray()
  for slot in 0 ..< Seats:
    if idx.resolutions[slot] <= 0:
      result.add(newJNull())
    else:
      result.add(%(exploitabilityCp(idx, spec, slot).float / 100.0))

proc conventionJson*(idx: Indices): JsonNode =
  result = newJArray()
  for row in idx.conventionCounts:
    result.add(%row)

proc topCell*(idx: Indices): tuple[i, j, count: int] =
  ## The most-hit cell, ties to the lowest (i, j). Drives `#mg-indices`.
  result = (0, 0, 0)
  for i in 0 ..< idx.k:
    for j in 0 ..< idx.k:
      if idx.conventionCounts[i][j] > result.count:
        result = (i, j, idx.conventionCounts[i][j])
