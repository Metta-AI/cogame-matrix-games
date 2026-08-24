## The chrome frame and the appended game block.
##
## Two failures this file exists to stop:
##  * a state frame that has drifted off `chrome_common.js`'s key set, which
##    makes the clock, the scrubber and the momentum curve silently dead;
##  * a game-block top-level `function markBeat` hoisted over the chrome alias
##    block's `var markBeat = C.markBeat`, which renders the scrubber's beats
##    as unlabeled, unclickable divs and passes every static grep (the tandem
##    bug, 2026-08-23).

import std/[json, os, sets, strutils, unittest]
import support/helpers
import matrix_games/[sim_types, sim_config, matrices, sim_state, sim, indices,
  broadcast, global, replays, map_art]

const ChromeKeys = ["t", "mt", "ph", "pl", "sp", "mx", "st", "lp", "sk", "ff",
  "en", "mm", "bs", "teams", "roster", "events", "lead", "beats", "lulls",
  "over", "hold"]

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc gameBlock(): string =
  ## Everything after the banner comment in client/replay_broadcast.html: the
  ## appended block, and nothing of the inherited chrome.
  let page = readFile(repoRoot() / "client" / "replay_broadcast.html")
  let marker = "MATRIX-GAMES additions to the inherited coworld-ctf chrome"
  let first = page.find(marker)
  check first > 0
  page[first .. ^1]

proc chromeAliasNames(): HashSet[string] =
  ## Every key `window.ChromeCommon(ctx)` returns -- the names a page aliases
  ## locally, and therefore the names a game-block function must not shadow.
  let source = readFile(repoRoot() / "client" / "chrome_common.js")
  let start = source.rfind("return {")
  check start > 0
  let tail = source[start .. ^1]
  let stop = tail.find("};")
  for line in tail[0 ..< stop].splitLines():
    for piece in line.split(','):
      let colon = piece.find(':')
      if colon <= 0:
        continue
      let name = piece[0 ..< colon].strip()
      if name.len > 0 and name.allCharsInSet({'A' .. 'Z', 'a' .. 'z', '0' .. '9',
          '_', '$'}):
        result.incl(name)

suite "the chrome state frame":
  setup:
    var state = runScripted("prisoners-dilemma", 51, certMix(), beats = 3)
    var track: BroadcastTracker
    let frame = buildStateJson(state, track, firstFrame = true)

  test "the key set is exactly paintbot's, plus seats":
    for key in ChromeKeys:
      check frame.hasKey(key)
    check frame.hasKey("seats")
    ## The extras are named, so a drifting emitter has to be a deliberate act.
    let extras = ["seats", "beat", "beats_played", "variant", "indices"]
    for key, _ in frame:
      check (key in ChromeKeys) or (key in extras)

  test "teams are exactly the K token keys chrome_common already knows":
    var keys: seq[string]
    for key, _ in frame{"teams"}:
      keys.add(key)
      check key in TokenChromeKeys
      check frame{"teams"}{key}.hasKey("share")
      check frame{"teams"}{key}.hasKey("tokensLeft")
      check frame{"teams"}{key}.hasKey("cells")
    check keys.len == state.spec.k

  test "lead.pts rows are [t, share...] of length K + 1":
    check frame{"lead"}{"teams"}.len == state.spec.k
    check frame{"lead"}{"pts"}.len == state.tick
    for row in frame{"lead"}{"pts"}:
      check row.len == state.spec.k + 1

  test "seats carries eight entries with policy name, livery and score":
    check frame{"seats"}.len == Seats
    for slot, seat in frame{"seats"}.getElems():
      check seat{"s"}.getInt() == slot
      check seat{"alias"}.getStr() == aliasOf(slot)
      check seat{"name"}.getStr() == state.names[slot]
      check seat{"livery"}.getStr() == liveryOf(slot)
      check seat{"color"}.getStr() == liveryHexOf(slot)
      check seat.hasKey("scoreCp")
      check seat.hasKey("interactions")
      check seat.hasKey("mix")

  test "over is present, and true on the terminal frame":
    check frame.hasKey("over")
    var done = runScripted("chicken", 52, certMix(), beats = 2)
    var terminalTracker: BroadcastTracker
    var terminal = buildStateJson(done, terminalTracker)
    ## `beats = 2` plays fewer ticks than the configured maximum, so the frame
    ## is `over` because the sim is done, which is the terminal condition the
    ## chrome reads.
    check terminal{"over"}.getBool() == done.done

  test "the beat timeline emits four kinds and only four":
    let kinds = ["interact", "bigpay", "leadchange", "over"]
    var seen: HashSet[string]
    for beat in frame{"beats"}:
      let kind = beat{"k"}.getStr()
      check kind in kinds
      seen.incl(kind)
      check beat.hasKey("t")
      check beat.hasKey("seat")
    check "over" in seen
    check "interact" in seen or "bigpay" in seen

  test "lull spans are ordered pairs inside the episode":
    for span in frame{"lulls"}:
      check span.len == 2
      check span[0].getInt() < span[1].getInt()
      check span[1].getInt() - span[0].getInt() >= LullTicks
      check span[1].getInt() <= state.tick

suite "the wasm viewer packet":
  test "a recorded replay replays into the same chrome frame shape":
    let state = runScripted("running-with-scissors", 53, certMix(), beats = 3)
    let replay = parseReplayBytes(replayBytes(state))
    let view = initViewer(replay)
    check view.tickCount == state.tick
    let first = view.viewerPacket(0, true)
    check first.hasKey("meta")
    for key in ChromeKeys:
      check first{"s"}.hasKey(key)
    check first{"s"}{"seats"}.len == Seats
    check first{"b"}{"c"}.len == Seats * 4
    ## A seek is an array index: the last packet must exist and be terminal.
    let last = view.viewerPacket(view.tickCount - 1, false)
    check last{"s"}{"over"}.getBool()
    check last{"s"}{"beats"}.len == 0     ## shipped whole on frame 1 only
    check first{"meta"}{"beats"}.len > 0
    check first{"meta"}{"policyNames"}.len == Seats
    check first{"meta"}{"spawners"}.len == replay{"spawners"}.len

suite "the appended game block":
  setup:
    let block4 = gameBlock()

  test "a CSS rule exists for every beat kind the frame can emit":
    for kind in ["interact", "bigpay", "leadchange", "over"]:
      check (".beat-marker." & kind) in block4

  test "the scrubber's beats are labelled, clickable buttons":
    check "document.createElement('button')" in block4
    check "aria-label" in block4
    check "mgCore.seek(tick)" in block4

  test "feed rows and banner chips use classes the stylesheet actually styles":
    ## A class name with no rule is invisible styling: the text lands in
    ## #killfeed and #bannerlane with no plate, no pixel font and no colour.
    let page = readFile(repoRoot() / "client" / "replay_broadcast.html")
    check ".feed-row {" in page
    check ".banner-chip {" in page
    check "row.className = 'feed-row';" in block4
    check "chip.className = 'banner-chip';" in block4

  test "the 360 px rules are present":
    check ".plate-name { flex: 1 1 auto; min-width: 3.2em;" in block4
    check "#stage.tiny .plate.mg .plate-enc" in block4
    check "#stage.tiny #mg-matrix td .mg-pay" in block4
    check "#stage.tiny #mg-indices" in block4

  test "no overlay sits in the transport band and the endcard stops above it":
    let page = readFile(repoRoot() / "client" / "replay_broadcast.html")
    check "--band" in page
    check "#endcard" in page
    for id in ["#mg-matrix", "#mg-indices", "#mg-legend"]:
      let at = block4.find(id & " {")
      check at > 0
      let rule = block4[at ..< block4.find("}", at)]
      check ("var(--topband)" in rule) or ("var(--band)" in rule)

  test "no game-block top-level name collides with the chrome alias list":
    ## THE tandem bug: a game-block `function markBeat` is hoisted over the
    ## alias block's `var markBeat = C.markBeat`.
    let aliases = chromeAliasNames()
    check aliases.len > 20
    check "markBeat" in aliases
    var declared: seq[string]
    for line in block4.splitLines():
      let text = line.strip()
      if not text.startsWith("function "):
        continue
      let rest = text["function ".len .. ^1]
      let paren = rest.find('(')
      if paren <= 0:
        continue
      declared.add(rest[0 ..< paren].strip())
    check declared.len >= 5
    for name in declared:
      check name notin aliases
      ## Belt and braces: every one of them is `mg`-prefixed.
      check name.startsWith("mg")

  test "the removed starter elements are gone from the page":
    let page = readFile(repoRoot() / "client" / "replay_broadcast.html")
    for id in ["viewpanel", "minimap-canvas", "zoombar", "zoom-slider",
        "zoom-read", "fpv-canvas", "fpv-hud", "fpv-gear", "fpv-map-canvas",
        "fpv-grip", "povBadge", "mmwarn"]:
      check ("id=\"" & id & "\"") notin page

  test "the kept starter elements are all still there":
    let page = readFile(repoRoot() / "client" / "replay_broadcast.html")
    for id in ["viewport", "stage", "board", "lightpool", "grain",
        "lockerroom", "chrome", "scorebug", "plates-l", "plates-r", "clock",
        "clock-time", "clock-caption", "ffwd-mini", "bannerlane", "killfeed",
        "transport", "ffwd-chip", "win-chip", "tick-clock", "speedchips",
        "scrub", "momentum", "lulls", "scrub-fill", "scrub-win", "scrub-head",
        "endcard", "ec-headline", "ec-wincond", "ec-how", "ec-teams",
        "status", "mg-matrix", "mg-indices", "mg-legend"]:
      check ("id=\"" & id & "\"") in page

suite "the viewer bundle's matched pair":
  test "the link flags are non-modularized and the worker matches them":
    ## The emscripten link flags and the JS bootstrap that starts the module
    ## are a MATCHED PAIR: a mixture throws nothing, logs nothing and hangs on
    ## "Loading replay..." forever (cogame-lantern, 2026-08-23).
    let config = readFile(repoRoot() / "replay-viewer" / "config.nims")
    check "MODULARIZE" notin config
    check "EXPORT_NAME" notin config
    check "-s ALLOW_MEMORY_GROWTH" in config
    check "-s ABORTING_MALLOC=1" in config
    check "-s FILESYSTEM=1" in config
    check "-s ENVIRONMENT=web,worker,node" in config
    check "-s EXPORTED_RUNTIME_METHODS=HEAPU8" in config
    check "--define:useMalloc" in config
    check "--preload-file" in config
    let worker = readFile(repoRoot() / "replay-viewer" /
      "static_replay_worker.js")
    check "Module.onRuntimeInitialized" in worker
    check "var Module = {}" in worker
    check "matrix-games-static-replay" in
      readFile(repoRoot() / "replay-viewer" / "static_replay.js")

  test "every export the worker calls is in the EXPORTED_FUNCTIONS list":
    let config = readFile(repoRoot() / "replay-viewer" / "config.nims")
    let worker = readFile(repoRoot() / "replay-viewer" /
      "static_replay_worker.js")
    for name in ["mg_load_replay", "mg_frame", "mg_packet_ptr",
        "mg_packet_len", "mg_error_ptr", "mg_error_len", "mg_stage_ptr",
        "mg_stage_len"]:
      check ("_" & name) in config
      check ("Module._" & name) in worker
    ## Dropped on purpose: matrix games records state, so there is nothing to
    ## mismatch.
    check "mismatch_tick" notin config
    check "_mg_mismatch_tick" notin worker

  test "the shell reports both readiness attributes":
    let shell = readFile(repoRoot() / "replay-viewer" / "static_replay.js")
    check "setAttribute('data-replay-loaded', 'true')" in shell
    check "setAttribute('data-replay-error', message)" in shell
    ## The bridge `ready` is posted AFTER data-replay-loaded is set, not on
    ## rAF timing at the firstFrame call site (the chorus fix).
    let loadedAt = shell.find("data-replay-loaded")
    let readyAt = shell.find("tell('ready')")
    check loadedAt > 0
    check readyAt > loadedAt

suite "board art":
  test "every asset the manifest names is committed":
    let root = repoRoot()
    for name in MatrixNames:
      let manifest = artManifest(name)
      for key in ["floor", "wallH", "wallV", "burst", "spark"]:
        check fileExists(root / "client" / manifest{key}.getStr())
      for token in manifest{"tokens"}:
        check fileExists(root / "client" / token.getStr())
      for livery, poses in manifest{"rigs"}:
        for pose, path in poses:
          check fileExists(root / "client" / path.getStr())
        check fileExists(root / "client" / manifest{"beams"}{livery}.getStr())

  test "the loading-screen art the lockerroom markup expects is present":
    let root = repoRoot()
    check fileExists(root / "client" / "art" / "lockerroom" / "bg.jpg")
    for colour in ["blue", "red", "green", "yellow"]:
      check fileExists(root / "client" / "art" / "lockerroom" /
        (colour & "_1.webp"))
