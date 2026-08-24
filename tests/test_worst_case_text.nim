## The worst-case model-text fixture, checked from the committed bytes.
##
## `.github/workflows/ci.yml` loads `tests/fixtures/worst_case_text.replay`
## through the real static bundle in headless chromium
## (`viewer_smoke.mjs --strict-text-bounds`). That step only means something if
## the fixture still carries the strings it was built to carry: one quietly
## shortened remark would leave it green while testing nothing. This file is
## that guarantee, and it reads the COMMITTED FILE -- not the generator's
## output -- for every length assertion.

import std/[json, os, strutils, tables, unicode, unittest]
import support/worst_case
import matrix_games/[sim_types, sim_config, replays, global]

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc fixturePath(): string =
  repoRoot() / FixtureRelPath.replace("/", DirSep & "")

suite "the worst-case model-text fixture":
  setup:
    let bytes = readFile(fixturePath())
    let replay = parseReplayBytes(bytes)

  test "every seat's every order event carries a FULL-CAP say and notes":
    ## The load-bearing assertion of the whole fixture.
    var perSeat = newSeq[int](Seats)
    var orders = 0
    for record in replay{"events"}:
      if record{"k"}.getStr() != "order":
        continue
      orders.inc
      let seat = record{"seat"}.getInt(-1)
      check seat >= 0
      check seat < Seats
      perSeat[seat].inc
      let say = record{"say"}.getStr()
      let notes = record{"notes"}.getStr()
      ## Exactly at the cap, in RUNES, and unshortened: `cleanText` would have
      ## cut a longer string to `cap - 1` runes and appended an ellipsis.
      check say.runeLen == MaxSayRunes
      check notes.runeLen == MaxNotesRunes
      check "\u2026" notin say
      check "\u2026" notin notes
      ## Multi-byte, so the cap being a RUNE cap is part of what is fixed.
      check say.len > say.runeLen
      check record{"source"}.getStr() == "llm"
    check orders == Seats * WorstCaseBeats
    for seat in 0 ..< Seats:
      check perSeat[seat] == WorstCaseBeats

  test "the fixture is a legal, current-format replay of a full episode":
    check replay{"protocol"}.getStr() == ReplayProtocol
    check replay{"gameVersion"}.getStr() == GameVersion
    check replay{"variant"}.getStr() == WorstCaseMatrix
    check replay{"results"}{"reason"}.getStr() == "complete"
    let view = initViewer(replay)
    check view.tickCount ==
      WorstCaseBeats * defaultGameConfig().ticksPerBeat
    ## Long enough for the ten-second soak the CI step runs (24 fps).
    check view.tickCount > 10 * TargetFps
    ## The first packet is what the wasm entry hands the page.
    let first = view.viewerPacket(0, true)
    check first.hasKey("meta")
    check first{"s"}{"seats"}.len == Seats
    for seat in first{"s"}{"seats"}:
      check seat{"say"}.getStr().runeLen == MaxSayRunes

  test "every beat-marker kind the page has a rule for is in the fixture":
    ## The scrubber builds a labelled button per marker, so this is also the
    ## worst case for the label strings.
    let view = initViewer(replay)
    var kinds = initCountTable[string]()
    for beat in view.beats:
      kinds.inc(beat{"k"}.getStr())
    for kind in ["interact", "bigpay", "leadchange", "over"]:
      check kinds[kind] > 0

  test "the committed fixture is what the generator produces":
    ## tools/gen_worst_case_replay.nim is the only way this file is written;
    ## if the two disagree the fixture has been hand-edited or has gone stale.
    check parseJson(worstCaseReplayBytes()) == parseJson(bytes)

suite "the feed bounds a full-cap remark":
  test "the page wraps the feed row and ellipsizes only the labels":
    ## Checklist item 15: a remark WRAPS (a sentence cut with an ellipsis is a
    ## box that is too small), a label ellipsizes. The feed row is the one
    ## piece of chrome that renders the model's `say`.
    let page = readFile(repoRoot() / "client" / "replay_broadcast.html")
    let at = page.find("#killfeed .feed-row {")
    check at > 0
    let rule = page[at ..< page.find("}", at)]
    check "white-space: normal" in rule
    check "overflow-wrap: anywhere" in rule
    check "text-overflow" notin rule          ## a remark never ellipsizes
    check "max-width: 100%" in rule
    ## The banner chip carries labels only, so it is the one that may cut.
    let chipAt = page.find("#bannerlane .banner-chip {")
    check chipAt > 0
    let chipRule = page[chipAt ..< page.find("}", chipAt)]
    check "text-overflow: ellipsis" in chipRule

  test "the feed the smoke harness counts is the feed the page fills":
    ## viewer_smoke.mjs reads `#feed, .feed, #log`; this page's remark feed is
    ## the inherited `#killfeed`, so without the class every CI run reports
    ## feed_lines: 0 and no artifact says whether the feed drew anything.
    let page = readFile(repoRoot() / "client" / "replay_broadcast.html")
    check "id=\"killfeed\" class=\"feed\"" in page
    check "mgId('killfeed')" in page
