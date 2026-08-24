## The Matrix Games game server: the Coworld game contract over mummy.
##
## Fork of paintbot's `src/ctf/server.nim` route/artifact/shutdown skeleton,
## with bullwhip's JSON player protocol. Hosted certification probes these
## exact routes BEFORE the player pods start (the cogame-lantern learning), so
## both `/client/` routes serve real pages, neither opens the player socket,
## and both are registered before any catch-all asset route.
##
##   GET /healthz                    200 from process start until
##                                   `shutdownGraceSeconds` after the
##                                   artifacts are written
##   GET /client/player?slot&token   the seat's HTML shell (view-only)
##   GET /client/global              the broadcast client
##   GET /client/<asset>             chrome_common.js, broadcast_core.js, art
##   WS  /player?slot=N&token=T      the seat socket; a bad token is refused
##                                   with a close frame, never a hang
##   WS  /global                     live spectator
##
## Decisions are made HERE, not in the player container: the Bedrock sidecar
## credentials and the `anthropic_api_key` secret are injected into the GAME
## pod, and "one parallel batch per beat" is a game-server property.

import std/[json, locks, os, sets, strutils, tables, times, unicode]
import bitworld/runtime
import curly
import mummy
import mummy/routers
import sim_types, sim_config, matrices, sim_state, indices, sim,
  llm, broadcast, replays

type
  ServerState = object
    prompts: seq[string]
    scripted: seq[ScriptKind]
    policies: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    snapshot: string
    seats: int
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: Sim
  tracker: BroadcastTracker
  gameServer: Server
  replayPayload: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc refreshSnapshotLocked() =
  for slot in 0 ..< shared.seats:
    gameSim.connected[slot] = shared.playerSockets.hasKey(slot)
  shared.snapshot = $globalSnapshot(gameSim, tracker)
  for socket in shared.globalSockets:
    try:
      socket.send(shared.snapshot)
    except CatchableError:
      discard

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform polls COGAME_PLAYER_FAILURE_URI so a lobby no-show is
  ## charged to the seat that caused it. Best effort, a no-op off-platform.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "matrix-games: player-failure declaration failed: ", error.msg

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc pushStateFrames() =
  ## The seat is not required to answer: decisions are server-side. The frame
  ## is the seat's observation, exactly as the LLM sees it.
  for slot, socket in shared.playerSockets:
    if slot < 0 or slot >= gameSim.cogs.len:
      continue
    try:
      socket.send($buildObservation(gameSim, slot))
    except CatchableError:
      discard

proc broadcastFinal(results: JsonNode) =
  ## Bounded: each seat adds one second of allowance and a seat whose turn
  ## comes up after the allowance is spent is skipped, so a slow reader can
  ## never hold the artifact writes.
  var scoreList = newJArray()
  for value in gameSim.scores():
    scoreList.add(%value)
  var aliases = newJArray()
  for slot in 0 ..< gameSim.cogs.len:
    aliases.add(%aliasOf(slot))
  var allowance = epochTime()
  for slot, socket in shared.playerSockets:
    allowance += 1.0
    if epochTime() > allowance:
      echo "matrix-games: final frame budget spent; skipping slot ", slot
      continue
    try:
      socket.send($ %*{
        "type": "final", "done": true, "slot": slot,
        "scores": scoreList, "names": aliases,
        "beats": gameSim.beat, "reason": gameSim.reason,
        "ending": gameSim.ending, "result": results})
    except CatchableError as error:
      echo "matrix-games: final frame to slot ", slot, " failed: ", error.msg

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    results = resultsJson(gameSim)
    replayData = replayBytes(gameSim)
    ## Final frames to the players BEFORE the artifacts: the hosted worker
    ## tears player pods down as soon as results.json exists.
    broadcastFinal(results)
    refreshSnapshotLocked()
  sleep(500)
  echo "matrix-games: writing replay (", replayData.len, " bytes) and results"
  ## The REPLAY first, then the results. The design note lists results first;
  ## paintbot (`src/ctf/server.nim`) and cogame-raid both write the replay
  ## first because the hosted worker treats `results.json` as the end of the
  ## episode and tears the pods down when it appears, so a replay written
  ## after it can be lost. Deliberate deviation, same artifacts either way.
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  echo gameSim.summaryLine()

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    ## Stamped BEFORE the connect wait on purpose: the 720 s play deadline
    ## bounds the WHOLE episode, connect time included, so the container
    ## always settles inside 60 % of episodeTimeoutSeconds. `validate()`
    ## enforces the floor that makes that possible --
    ## playerConnectTimeoutSeconds (180) + registration grace (3) +
    ## one beat's 2 x llmTimeoutSeconds (40) = 223 s <= 720 s -- and the beat
    ## loop below refuses to open a beat whose worst case would run past the
    ## deadline, so at the shipped 12 beats (663 s) every beat is played and
    ## at a longer `beats` the episode truncates instead of overrunning.
    let gameStart = epochTime()
    let connectDeadline =
      gameStart + config.playerConnectTimeoutSeconds.float
    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = shared.playerSockets.len >= shared.seats
      if allConnected:
        break
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its prompt frame.
    let registerDeadline = min(epochTime() + RegistrationGraceSeconds.float,
      connectDeadline + RegistrationGraceSeconds.float)
    while epochTime() < registerDeadline:
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var noShow = -1
    var connectedCount = 0
    withLock stateLock:
      connectedCount = shared.playerSockets.len
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
          ## A seat that never connects does not end the episode: it plays
          ## `counter` for every beat.
          shared.scripted[slot] = skCounter
        gameSim.policyKinds[slot] =
          if shared.scripted[slot] != skNone: "scripted" else: "llm"
        if shared.policies[slot].len > 0:
          gameSim.names[slot] = shared.policies[slot]
      echo "matrix-games: starting with ", connectedCount, "/", shared.seats,
        " players connected"
      refreshSnapshotLocked()
    if noShow >= 0:
      declarePlayerFailure(noShow,
        "player slot " & $noShow & " never registered; the seat played the " &
        "counter baseline")

    if connectedCount == 0:
      ## No seat socket connected inside playerConnectTimeoutSeconds. The
      ## episode still writes results.json and a replay -- all zeroes -- so
      ## the platform sees a completed, forfeited episode rather than a hang.
      gameSim.captureFrame()
      gameSim.captureSeries()
      gameSim.finish("forfeit", "forfeit")
      finishEpisode(runtimeConfig)
      sleep(config.shutdownGraceSeconds * 1000)
      quit(0)

    let client = newLlmClient(config)
    let deadline = config.playDeadlineSeconds()
    let beatBudget = config.beatBudgetSeconds().float
    ## The beat loop runs on its own thread while `gameServer.serve` keeps
    ## answering /healthz. An unguarded raise here would kill the thread and
    ## leave a healthy-looking container with no artifacts and no `quit` --
    ## a hang, not a failure. Settle with what was played instead.
    try:
      for beat in 0 ..< config.beats:
        if epochTime() - gameStart + beatBudget > deadline:
          ## Checked BETWEEN BEATS only, and against the budget the beat
          ## ABOUT TO START can spend (one batch plus its retry), so the
          ## episode settles INSIDE the deadline rather than one beat past
          ## it. Crossing it settles with reason "deadline": the beats played
          ## are scored and nothing is imputed for the rest. This is what
          ## lets `validate()` accept every `beats` the config schema
          ## publishes -- a long episode is truncated, never a startup error
          ## and never an overrun.
          echo "matrix-games: play deadline reached at beat ", beat,
            " (", int(epochTime() - gameStart), "s of ", int(deadline), "s)"
          gameSim.finish("deadline", "deadline")
          break
        var observations = newSeq[JsonNode](shared.seats)
        var prompts: seq[string]
        var kinds: seq[ScriptKind]
        withLock stateLock:
          prompts = shared.prompts
          kinds = shared.scripted
          for slot in 0 ..< shared.seats:
            observations[slot] = buildObservation(gameSim, slot)
            if not shared.playerSockets.hasKey(slot):
              ## A seat that dropped mid-episode plays `counter` for every
              ## remaining beat. The episode never waits on it.
              kinds[slot] = skCounter
          pushStateFrames()
        let decisions = client.decideAll(observations, prompts, kinds)
        gameSim.installOrders(decisions)
        withLock stateLock:
          refreshSnapshotLocked()
        gameSim.runBeat()
        withLock stateLock:
          refreshSnapshotLocked()
        echo "matrix-games: beat ", beat, " done, tick ", gameSim.tick,
          ", ", gameSim.idx.interactions, " resolutions, ",
          int(epochTime() - gameStart), "s elapsed"
    except Exception as error:
      ## `Exception`, not `CatchableError`: in Nim 2.2.4 a Defect (IndexDefect,
      ## RangeDefect, NilAccessDefect) derives from Exception and NOT from
      ## CatchableError, and the image builds with `-d:release` and without
      ## `--panics:on` (Dockerfile:43, :46) -- so a defect on this thread is
      ## raisable, catchable, and would otherwise take the whole process down
      ## with no artifacts. The note's pin is that a raise settles as
      ## `deadline`; that has to mean EVERY raise.
      echo "matrix-games: beat loop failed (", error.name,
        "), settling early: ", error.msg
      gameSim.finish("deadline", "deadline")
    gameSim.settleComplete()
    withLock stateLock:
      ## One last observation to every seat, so a policy sees the state it
      ## finished in before the `final` frame arrives.
      pushStateFrames()
    finishEpisode(runtimeConfig)
    ## `/healthz` and `/global` keep answering for the grace window, because
    ## hosted certification pings the global websocket AFTER the player pods
    ## start (the cogame-lantern learning).
    echo "matrix-games: holding /healthz and /global for ",
      config.shutdownGraceSeconds, "s"
    sleep(config.shutdownGraceSeconds * 1000)
    quit(0)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "player.html",
      "text/html; charset=utf-8")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "global.html",
      "text/html; charset=utf-8")

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".js"): "application/javascript; charset=utf-8"
      elif name.endsWith(".css"): "text/css; charset=utf-8"
      elif name.endsWith(".html"): "text/html; charset=utf-8"
      elif name.endsWith(".png"): "image/png"
      elif name.endsWith(".jpg"): "image/jpeg"
      elif name.endsWith(".webp"): "image/webp"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, clientDir() / name, contentType)

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayload.len == 0:
      request.respond(404)
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    request.respond(200, headers, replayPayload)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      echo "matrix-games: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      websocket.send($ %*{
        "type": "welcome", "protocol": PlayerProtocol, "slot": slot,
        "name": aliasOf(slot),
        "camp": campOf(slot, gameSim.spec.crossCampOnly),
        "variant": gameSim.spec.name,
        "beats": gameSim.config.beats,
        "ticksPerBeat": gameSim.config.ticksPerBeat})

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      if shared.snapshot.len > 0:
        websocket.send(shared.snapshot)

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() != "prompt":
          echo "matrix-games: ignoring frame of type ",
            payload{"type"}.getStr()
          return
        var prompt = payload{"prompt"}.getStr()
        if prompt.runeLen > MaxPromptRunes:
          prompt = prompt.runeSubStr(0, MaxPromptRunes)
        let node = payload{"scripted"}
        var kind =
          if node == nil or node.kind == JNull: skNone
          elif node.kind == JBool: (if node.getBool(): skCounter else: skNone)
          else: parseScriptKind(node.getStr())
        if node != nil and node.kind == JString and
            node.getStr().strip().len == 0:
          kind = skNone
        if prompt.strip().len == 0 and kind == skNone:
          kind = skCounter
        let policy = cleanText(payload{"policy"}.getStr(),
          MaxPolicyLabelRunes)
        withLock stateLock:
          shared.prompts[slot] = prompt
          shared.scripted[slot] = kind
          shared.policies[slot] = policy
          shared.registered[slot] = true
          shared.everRegistered[slot] = true
        echo "matrix-games: slot ", slot, " registered (", prompt.len,
          " prompt chars", (if kind != skNone: ", scripted " & $kind
                            else: ", llm"), ")"
      except CatchableError as error:
        echo "matrix-games: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let slot = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(slot) == websocket:
            shared.playerSockets.del(slot)
        shared.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  ## The two `/client/` routes are registered BEFORE the catch-all asset
  ## route, which is what stops `/client/player` resolving to an asset 404.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  replayPayload = runtimeConfig.replay
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "matrix-games: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc stopServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(MatrixGamesError,
      "tokens must name exactly num_agents seats")
  gameSim = initSim(config)
  shared.seats = config.numAgents
  shared.prompts = newSeq[string](shared.seats)
  shared.scripted = newSeq[ScriptKind](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  for slot in 0 ..< shared.seats:
    if slot < config.players.len and config.players[slot].name.len > 0:
      gameSim.names[slot] = config.players[slot].name
  shared.snapshot = $globalSnapshot(gameSim, tracker)

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, runtimeConfig)
  echo "matrix-games: serving on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
