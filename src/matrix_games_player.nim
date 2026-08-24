## Matrix Games player: a policy is just a prompt.
##
## Fork of `cogame-bullwhip/src/bullwhip_player.nim`. The player container is
## deliberately thin: it connects, sends ONE frame carrying its prompt (or its
## baseline name), and thereafter only listens. Every decision is made inside
## the GAME container, which is what makes one parallel batch per beat
## possible and why the coworld secret is declared on the game runnable.
##
##   PLAYER_PROMPT="<strategy text>"        an LLM policy
##   PLAYER_SCRIPTED=counter|tit-for-tat|fixed-pick|always-first|always-second
##                                          a scripted baseline
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy cogame-matrix-games:latest --name my-matrix \
##     --run /bin/matrix-games-player \
##     --secret-env PLAYER_PROMPT="<your strategy>" \
##     --secret-env USE_BEDROCK=true

import std/[json, options, os, strutils]
import whisky

const
  ConnectAttempts = 5
  ConnectBackoffMs = 250
  DefaultPrompt = """
Your score is the sum of the payoffs you collect, so you must interact - but
never interact holding a uniform inventory, because a uniform mix donates.
Every beat: read the public resolution log first and note what each cog
carried into its last interaction. Spend a beat or two on `gather` for the
token that beats what your intended target is visibly holding, then `hunt`
that cog. If a cog with a strong mix is close and loaded against you, `avoid`
it for one beat rather than feed it. If two beats pass with no interaction,
take the closest encounter you can get; zero is the worst score in this game.
Keep notes naming each cog and the mix it last showed you.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  if prompt.strip().len == 0 and scripted.len == 0:
    ## The manifest ships this binary with no env as `matrix-games-player`,
    ## "the reference matrix-games policy", so a bare container registers with
    ## the reference PROMPT rather than as a scripted seat. The server's own
    ## default (a seat that registers with neither field, or never registers,
    ## plays `counter`) still stands and is the path for a real no-show.
    prompt = DefaultPrompt
  let policy = getEnv("PLAYER_POLICY_LABEL")

  proc promptFrame(): string =
    $ %*{
      "type": "prompt",
      "prompt": prompt,
      "scripted": scripted,
      "policy": policy
    }

  var socket: WebSocket = nil
  for attempt in 1 .. ConnectAttempts:
    try:
      socket = newWebSocket(url)
      break
    except CatchableError as error:
      echo "matrix-games player: connect attempt ", attempt, " failed: ",
        error.msg
      if attempt == ConnectAttempts:
        ## A bounded retry, then leave quietly: the game declares the no-show
        ## itself and plays the seat on the `counter` baseline.
        echo "matrix-games player: giving up on ", url
        quit(0)
      sleep(ConnectBackoffMs * attempt)

  socket.send(promptFrame())
  echo "matrix-games player: registered (", prompt.len, " prompt chars",
    (if scripted.len > 0: ", scripted " & scripted else: ", llm"), ")"

  while true:
    ## whisky RAISES rather than returning none on both a close frame and a
    ## half-read one, and mummy's `send` only queues: the game writes its
    ## artifacts and exits, so a seat can lose the socket before its `final`
    ## frame is flushed. The episode is over either way -- a player that dies
    ## here exits 1 and fails certification with `player_error` (the
    ## cogame-raid learning, 2026-08-23).
    var received: Option[Message]
    try:
      received = socket.receiveMessage()
    except CatchableError as error:
      echo "matrix-games player: connection ended (", error.msg, "), exiting"
      break
    if received.isNone:
      echo "matrix-games player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      if payload{"done"}.getBool():
        echo "matrix-games player: final scores ", payload{"scores"}
        break
      case payload{"type"}.getStr()
      of "welcome":
        echo "matrix-games player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
          " in ", payload{"variant"}.getStr()
        ## Re-deliver the prompt in case the first send raced the server's
        ## slot bookkeeping.
        socket.send(promptFrame())
      of "state":
        discard
      else:
        discard
    except CatchableError as error:
      echo "matrix-games player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
