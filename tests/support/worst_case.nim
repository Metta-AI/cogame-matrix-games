## The worst-case model-text fixture: one real episode whose every order event
## carries a FULL-CAP `say` and a FULL-CAP `notes`.
##
## Why it exists (acceptance checklist item 15, cogchemists 2026-08-24):
## `tools/ci/docker_smoke.sh` runs without an `ANTHROPIC_API_KEY`, so every
## seat in every CI episode falls back to a scripted baseline and a scripted
## baseline emits a short canned remark. The whole class of chrome that exists
## to show what a MODEL said -- the feed row that carries `say` -- is therefore
## untested by every other gate. This fixture is the replay CI cannot otherwise
## produce: eight seats, every beat, each with a 64-rune remark and a 400-rune
## notes block, played through the same sim and written by the same
## `replayBytes` as a hosted episode, so the static bundle loads it exactly as
## it loads a real one.
##
## The strings are built to HURT, not to look nice: each is padded to the cap
## with an unbroken alphabetic run, which no soft wrap on spaces can break, and
## each carries multi-byte runes so the cap is a rune cap and not a byte cap.
##
## `tools/gen_worst_case_replay.nim` writes the bytes to
## `tests/fixtures/worst_case_text.replay`; `tests/test_worst_case_text.nim`
## asserts the committed file still carries them at full length. The episode is
## `prisoners-dilemma` at seed 10 with a mixed baseline table, which is a seat
## mix that produces all four beat-marker kinds -- interact, bigpay,
## leadchange and over -- so every scrubber label the page can build is built.

import std/[unicode]
import matrix_games/[sim_types, sim_state, sim, scripted, replays]
import helpers

const
  WorstCaseMatrix* = "prisoners-dilemma"
  WorstCaseSeed* = 10
  WorstCaseBeats* = 6
  FixtureRelPath* = "tests/fixtures/worst_case_text.replay"
  Filler = "-no-quarter-hold-the-line-and-count-every-token-again"
    ## An unbroken run: no space in it, so a row that only wraps on
    ## whitespace cannot break it and has to bound the text some other way.

proc worstCaseKinds*(): seq[ScriptKind] =
  ## A mix, not one baseline: the always-first/always-second pairing is what
  ## puts a >= 400 cp resolution (a `bigpay` marker) in the episode.
  @[skAlwaysFirst, skAlwaysSecond, skCounter, skTitForTat, skAlwaysSecond,
    skAlwaysFirst, skFixedPick, skCounter]

proc padToRunes(head: string, runes: int): string =
  ## Exactly `runes` runes, never fewer: `head` then the filler, cut on a rune
  ## boundary. No leading or trailing space, because `cleanText` strips before
  ## it measures and a stripped string would land one rune short of the cap.
  result = head
  while result.runeLen < runes:
    result.add(Filler)
  result = result.runeSubStr(0, runes)
  while result.len > 0 and result[^1] == ' ':
    result[^1] = '!'

proc worstCaseSay*(slot: int): string =
  ## 64 runes -- `MaxSayRunes`, the cap `installOrders` enforces.
  padToRunes(aliasOf(slot) & " \u2014 \u00fcber-commit: I hold red", MaxSayRunes)

proc worstCaseNotes*(slot: int): string =
  ## 400 runes -- `MaxNotesRunes`. Not drawn by this viewer today, but it is
  ## the other string the seat can author and it rides the same replay.
  padToRunes(aliasOf(slot) & " \u2014 notes for the next beat: they reset on " &
    "contact, so the cap is worth more than the mix", MaxNotesRunes)

proc worstCaseSim*(): Sim =
  ## The episode, played with the scripted intents but with every seat's
  ## `say` and `notes` replaced by the full-cap strings a model could send.
  var state = initSim(testConfig(WorstCaseMatrix, WorstCaseSeed,
    WorstCaseBeats))
  let kinds = worstCaseKinds()
  for slot in 0 ..< Seats:
    state.names[slot] = "worst-case-" & $kinds[slot]
    state.policyKinds[slot] = "llm"
  for beat in 0 ..< state.config.beats:
    var decisions = newSeq[Decision](Seats)
    for slot in 0 ..< Seats:
      var order = scriptedOrder(buildObservation(state, slot), kinds[slot])
      order.say = worstCaseSay(slot)
      order.notes = worstCaseNotes(slot)
      ## `osLlm`: these are model-authored strings, and the feed's `[auto]`
      ## tag is only for fallbacks.
      decisions[slot] = Decision(order: order, source: osLlm, latencyMs: 1234)
    state.installOrders(decisions)
    state.runBeat()
  state.settleComplete()
  state

proc worstCaseReplayBytes*(): string =
  replayBytes(worstCaseSim())
