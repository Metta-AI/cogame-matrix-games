## End-to-end: a full scripted episode writes `results.json` and a replay,
## then the replay BYTES are re-read and validated strictly.
##
## The rune-truncation case at the bottom is the bullwhip byte-truncation bug:
## a seat is fed a `say` and a `notes` of multi-byte runes exactly at the 64 /
## 400 caps, and the recorded strings must still be valid UTF-8 and within the
## cap. A byte cut renders fine in a browser and only fails later, in a strict
## parser, on a hosted replay nobody can open.

import std/[json, os, strutils, tables, unicode, unittest]
import support/helpers
import matrix_games/[sim_types, sim_config, matrices, sim_state, events, sim,
  indices, replays, llm, scripted]

suite "the replay file":
  setup:
    var state = runScripted("prisoners-dilemma", 21, certMix())
    let bytes = replayBytes(state)

  test "the bytes are strict UTF-8 and parse as matrix.replay.v1":
    check validateUtf8(bytes) == -1
    let replay = parseReplayBytes(bytes)
    check replay{"protocol"}.getStr() == ReplayProtocol
    check replay{"game"}.getStr() == "matrix-games"
    check replay{"gameVersion"}.getStr() == GameVersion

  test "frames and both series are one row per tick played":
    let replay = parseReplayBytes(bytes)
    check state.tick == state.config.beats * state.config.ticksPerBeat
    check replay{"frames"}.len == state.tick
    check replay{"series"}{"share"}.len == state.tick
    check replay{"series"}{"score"}.len == state.tick
    for row in replay{"series"}{"share"}:
      check row.len == state.spec.k + 1
    for row in replay{"series"}{"score"}:
      check row.len == Seats + 1
    for frame in replay{"frames"}:
      check frame{"c"}.len == Seats * 4
      check frame{"inv"}.len == Seats * state.spec.k
      check frame{"tok"}.len == replay{"spawners"}.len
      check frame{"sc"}.len == Seats

  test "the event stream is complete and in range":
    let replay = parseReplayBytes(bytes)
    var counts = {"pickup": 0, "beam": 0, "interact": 0, "reset": 0,
      "beatclose": 0, "end": 0, "order": 0}.newOrderedTable()
    for record in replay{"events"}:
      let t = record{"t"}.getInt(-1)
      check t >= 0
      check t <= state.tick
      let kind = record{"k"}.getStr()
      check kind in EventKinds
      if counts.hasKey(kind):
        counts[kind] = counts[kind] + 1
    check counts["pickup"] >= 1
    check counts["beam"] >= 1
    check counts["interact"] >= 1
    check counts["reset"] == counts["interact"] * 2
    check counts["beatclose"] == state.config.beats
    check counts["end"] == 1
    check counts["order"] == state.config.beats * Seats

  test "names, policy names, the matrix and the results all ride along":
    let replay = parseReplayBytes(bytes)
    check replay{"names"}.len == Seats
    check replay{"policyNames"}.len == Seats
    check replay{"liveries"}.len == Seats
    check replay{"camps"}.len == Seats
    check replay{"config"}{"rowPay"}.len == state.spec.k
    check replay{"config"}{"colPay"}.len == state.spec.k
    check replay{"results"}{"scores"}.len == Seats
    check replay{"results"}{"reason"}.getStr() in LegalReasons
    check replay{"results"}{"names"}.len == Seats
    ## Two name spaces: the aliases go into `names`, the policies into
    ## `policyNames` and `results.names`.
    for slot in 0 ..< Seats:
      check replay{"names"}[slot].getStr() == aliasOf(slot)

  test "the file stays well under 8 MiB":
    check bytes.len < 8 * 1024 * 1024

  test "results.json is complete and internally consistent":
    let results = resultsJson(state)
    check results{"scores"}.len == Seats
    check results{"win"}.len == Seats
    check results{"aliases"}.len == Seats
    check results{"perSeatInteractions"}.len == Seats
    check results{"meanPayoff"}.len == Seats
    check results{"exploitability"}.len == Seats
    check results{"variant"}.getStr() == "prisoners-dilemma"
    check results{"ticks"}.getInt() == state.tick
    var winners = 0
    for value in results{"win"}:
      if value.getBool(): winners.inc
    check winners >= 1

suite "rune-boundary truncation":
  test "a say and a notes at exactly the cap stay valid UTF-8":
    ## Multi-byte runes: each of these is three bytes in UTF-8.
    let sayText = repeat("\u4e2d", MaxSayRunes)
    let notesText = repeat("\u00e9\u4e2d", MaxNotesRunes)
    check sayText.runeLen == MaxSayRunes
    var state = initSim(testConfig("chicken", 22, beats = 2))
    var decisions = newSeq[Decision](Seats)
    for slot in 0 ..< Seats:
      decisions[slot] = scriptedDecision(buildObservation(state, slot),
        skCounter, osScripted)
    decisions[2].order.say = sayText
    decisions[2].order.notes = notesText
    state.installOrders(decisions)
    state.runBeat()
    state.finish("complete", "full_match")
    let bytes = replayBytes(state)
    check validateUtf8(bytes) == -1
    let replay = parseReplayBytes(bytes)
    var seen = false
    for record in replay{"events"}:
      if record{"k"}.getStr() != "order" or record{"seat"}.getInt() != 2:
        continue
      seen = true
      let say = record{"say"}.getStr()
      let notes = record{"notes"}.getStr()
      check validateUtf8(say) == -1
      check validateUtf8(notes) == -1
      check say.runeLen <= MaxSayRunes
      check notes.runeLen <= MaxNotesRunes
    check seen

  test "cleanText never cuts a rune in half, at any length":
    for limit in 1 .. 40:
      let text = repeat("\u4e2d", 60)
      let cut = cleanText(text, limit)
      check validateUtf8(cut) == -1
      check cut.runeLen <= limit
    check cleanText("  spaced  ", 40) == "spaced"
    check cleanText("two\nlines", 40) == "two lines"

suite "artifacts on disk":
  test "the episode writes a replay and results that re-read cleanly":
    let dir = getTempDir() / "matrix-games-test-artifacts"
    createDir(dir)
    defer: removeDir(dir)
    let state = runScripted("stag-hunt", 23, certMix(), beats = 3)
    writeFile(dir / "replay.json", replayBytes(state))
    writeFile(dir / "results.json", $resultsJson(state))
    let replay = parseReplayBytes(readFile(dir / "replay.json"))
    check replay{"frames"}.len == 3 * state.config.ticksPerBeat
    let results = parseJson(readFile(dir / "results.json"))
    check results{"names"}.len == Seats
