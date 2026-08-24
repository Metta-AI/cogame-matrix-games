## Matrix Games core types, constants and the two text-safety helpers.
##
## Forked from paintbot's `src/ctf/sim_types.nim`: the same split between the
## wire types, the entity records and the tuning constants, and the same rule
## that FIELD ORDER IS SACRED -- the replay's flat integer blocks are written
## and read positionally, so reordering a field silently reinterprets every
## recorded frame.
##
## Every quantity the step touches is an INTEGER: cell coordinates, facings,
## inventory counts and payoffs in centipoints. No float enters sim state, so
## one seed reproduces one replay bit-exactly on any host, which is what
## `tests/test_sim.nim`'s determinism gate depends on.

import std/[strutils, unicode]

const
  GameVersion* = "1"
    ## Bump whenever a recorded frame would replay as a different episode.

  ReplayProtocol* = "matrix.replay.v1"
  PlayerProtocol* = "matrix.player.v1"
  GlobalProtocol* = "matrix.global.v1"

  BoardW* = 24
  BoardH* = 14
  CellPx* = 40                 ## 24 x 14 cells at 40 px = a 960 x 560 board
  TargetFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  Seats* = 8
  Aliases* = ["Ash", "Birch", "Cedar", "Dune", "Elm", "Fern", "Gorse",
    "Holly"]
  LiveryKeys* = ["cobalt", "sky", "moss", "lime", "rust", "ember", "brass",
    "plum"]
  LiveryHex* = ["#3f7cc4", "#6fb3e8", "#45a85e", "#8fd26a", "#e0523a",
    "#f08a4b", "#ddc531", "#b06fd0"]
  ## Slots 0..3 are the row (blue) camp, 4..7 the column (orange) camp. The
  ## camp only has mechanical meaning in `bach-or-stravinsky`; every other
  ## variant reports "none" and every cog is eligible against every other.
  RowCampSeats* = 4
  TokenChromeKeys* = ["red", "blue", "green"]

  ## Rule constants (design note, "The game").
  TokenCapDefault* = 8
  TokenRespawnDefault* = 45
  BeamRangeDefault* = 4
  FreezeTicksDefault* = 12
  StepCooldownDefault* = 3
  BeamResetCooldownDefault* = 25
  BeamMissCooldownDefault* = 6
  ViewRadiusDefault* = 7
  BeatsDefault* = 12
  TicksPerBeatDefault* = 50
  ImmuneTicks* = 12
  BeamDrawTicks* = 4
  CellFlashTicks* = 12
  LullTicks* = 60
  BigPayCp* = 400
  CommitTarget* = 5

  ## Zone rectangles, in cells. Zone C only exists when K == 3; the mixed
  ## scatter is the centre band and carries `n mod K`.
  ZoneAx0* = 1
  ZoneAy0* = 1
  ZoneAx1* = 7
  ZoneAy1* = 5
  ZoneBx0* = 16
  ZoneBy0* = 1
  ZoneBx1* = 22
  ZoneBy1* = 5
  ZoneCx0* = 8
  ZoneCy0* = 8
  ZoneCx1* = 15
  ZoneCy1* = 12
  MixedY0* = 6
  MixedY1* = 7
  ZoneSpawners* = 16
  MixedSpawners* = 12

  ## Caps, in RUNES. A byte cut once put invalid UTF-8 into a replay and only
  ## a strict parser found it, so every recorded string goes through
  ## `cleanText` below.
  MaxSayRunes* = 64
  MaxNotesRunes* = 400
  MaxPromptRunes* = 4000
  MaxDetailRunes* = 200
  MaxPolicyLabelRunes* = 48

  LegalReasons* = ["complete", "deadline", "forfeit"]

  RegistrationGraceSeconds* = 3
    ## After the connect wait, a connected-but-silent seat gets this long to
    ## send its `prompt` frame. It is part of the wall clock the play deadline
    ## is measured against, so `validate()` counts it.

type
  MatrixGamesError* = object of CatchableError

  Intent* = enum
    inGather = "gather"
    inDeny = "deny"
    inHunt = "hunt"
    inAvoid = "avoid"
    inHold = "hold"

  OrderSource* = enum
    osLlm = "llm"
    osRetry = "retry"
    osFallback = "fallback"
    osScripted = "scripted"

  ScriptKind* = enum
    skNone = "none"
    skCounter = "counter"
    skTitForTat = "tit-for-tat"
    skFixedPick = "fixed-pick"
    skAlwaysFirst = "always-first"
    skAlwaysSecond = "always-second"

  MicroKind* = enum
    ## What the deterministic kernel does with one cog on one tick.
    mkWait = "wait"
    mkStep = "step"
    mkTurn = "turn"
    mkFire = "fire"

  Micro* = object
    kind*: MicroKind
    dir*: int                ## 0 = N, 1 = E, 2 = S, 3 = W

  IntentOrder* = object
    ## One seat's decision for one beat. `token` and `target` are -1 when the
    ## intent does not take that argument.
    intent*: Intent
    token*: int
    target*: int
    say*: string
    notes*: string

  Cog* = object
    slot*: int
    x*, y*: int
    facing*: int
    inv*: seq[int]           ## length K
    scoreCp*: int
    freeze*: int
    stepCd*: int
    beamCd*: int
    immune*: int
    interactions*: int
    fixedType*: int          ## the `fixed-pick` baseline's drawn type

  Spawner* = object
    x*, y*: int
    token*: int
    hasToken*: bool
    refillAt*: int

  Zone* = object
    token*: int              ## -1 for the mixed scatter
    x0*, y0*, x1*, y1*: int
    cx*, cy*: int

  Decision* = object
    order*: IntentOrder
    source*: OrderSource
    latencyMs*: int

  Pcg32* = object
    state*: uint64
    stream*: uint64

# ---- seat identity -----------------------------------------------------

proc aliasOf*(slot: int): string =
  if slot < 0 or slot >= Aliases.len: "?" else: Aliases[slot]

proc liveryOf*(slot: int): string =
  if slot < 0 or slot >= LiveryKeys.len: "cobalt" else: LiveryKeys[slot]

proc liveryHexOf*(slot: int): string =
  if slot < 0 or slot >= LiveryHex.len: "#3f7cc4" else: LiveryHex[slot]

proc rowCamp*(slot: int): bool =
  slot >= 0 and slot < RowCampSeats

proc campOf*(slot: int, crossCampOnly: bool): string =
  if not crossCampOnly: "none"
  elif rowCamp(slot): "row"
  else: "column"

proc slotOfAlias*(name: string): int =
  let wanted = name.strip().toLowerAscii()
  for slot, alias in Aliases:
    if alias.toLowerAscii() == wanted:
      return slot
  -1

proc parseScriptKind*(text: string): ScriptKind =
  case text.strip().toLowerAscii()
  of "", "none", "0", "false": skNone
  of "counter": skCounter
  of "tit-for-tat", "tit_for_tat", "titfortat": skTitForTat
  of "fixed-pick", "fixed_pick", "fixedpick": skFixedPick
  of "always-first", "always_first", "alwaysfirst": skAlwaysFirst
  of "always-second", "always_second", "alwayssecond": skAlwaysSecond
  else: skCounter

# ---- text safety -------------------------------------------------------

proc utf8Only*(text: string): string =
  ## Drops every byte that is not part of a well-formed UTF-8 sequence. Text
  ## that reaches here is not always ours -- an HTTP error body captured from
  ## the model API can be a byte-truncated proxy page -- and one stray
  ## continuation byte makes the whole replay fail a strict JSON parser.
  if validateUtf8(text) < 0:
    return text
  result = newStringOfCap(text.len)
  var rest = text
  while rest.len > 0:
    let bad = validateUtf8(rest)
    if bad < 0:
      result.add(rest)
      break
    result.add(rest[0 ..< bad])
    rest = rest[bad + 1 .. ^1]

proc cleanText*(text: string, limit: int): string =
  ## `strip`, then -- if the result is longer than `limit` RUNES -- cut to
  ## `limit - 1` runes and append an ellipsis. Newlines become spaces so one
  ## `say` cannot break a feed row or a log line. Bullwhip's `cleanText`:
  ## truncation is on rune boundaries, never bytes.
  var cleaned = utf8Only(text.replace("\r", " ").replace("\n", " ")).strip()
  if limit <= 0:
    return ""
  if cleaned.runeLen <= limit:
    return cleaned
  cleaned.runeSubStr(0, limit - 1) & "\u2026"

# ---- deterministic RNG -------------------------------------------------

proc initPcg32*(seed: int): Pcg32 =
  let raw = cast[uint64](seed)
  result.state = 0'u64
  result.stream = (raw shl 1'u64) or 1'u64
  result.state = result.state * 6364136223846793005'u64 + result.stream
  result.state = result.state + raw
  result.state = result.state * 6364136223846793005'u64 + result.stream

proc nextU32*(rng: var Pcg32): uint32 =
  let old = rng.state
  rng.state = old * 6364136223846793005'u64 + rng.stream
  let xorshifted = uint32(((old shr 18'u64) xor old) shr 27'u64)
  let rot = uint32(old shr 59'u64)
  (xorshifted shr rot) or (xorshifted shl ((32'u32 - rot) and 31'u32))

proc below*(rng: var Pcg32, bound: int): int =
  if bound <= 1: 0 else: int(rng.nextU32() mod uint32(bound))

# ---- grid helpers ------------------------------------------------------

const
  DirDx* = [0, 1, 0, -1]     ## N, E, S, W -- the tie-break order everywhere
  DirDy* = [-1, 0, 1, 0]
  DirNames* = ["N", "E", "S", "W"]

proc chebyshev*(ax, ay, bx, by: int): int {.inline.} =
  max(abs(ax - bx), abs(ay - by))

proc argmaxLowest*(values: openArray[int]): int =
  ## Index of the largest value; ties go to the LOWEST index. Pinned because
  ## the argmax cell the viewer pops must not depend on iteration order.
  result = 0
  for i in 1 ..< values.len:
    if values[i] > values[result]:
      result = i
