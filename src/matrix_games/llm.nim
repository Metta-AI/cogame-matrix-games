## Claude-backed decision making: ONE parallel batch per beat.
##
## Forked from `cogame-bullwhip/src/bullwhip/llm.nim`. Matrix Games is a
## simultaneous-decision game, so at every beat boundary all eight seats'
## requests go out together in a single `curly.makeRequests` batch. Seats are
## never queried sequentially -- that is what blows the play budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME / AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself on the first discovery, every
## beat falls back instantly with no network wait, and offline certification
## still completes deterministically. That fallback is load-bearing.
##
## The model ladder is haiku-only, deliberately: the sonnet fallback times out
## on every sidecar call and turns one throttle into a cascade of scripted
## seats (the cogame-raid learning, 2026-08-23).

import std/[json, math, os, strutils, times]
import bitworld/runtime
import curly
import sim_types, sim_config, scripted

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  BatchReply* = object
    text*: string
    error*: string

  LlmClient* = ref object
    curl: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    timeoutSeconds*: int
    minBeatSeconds*: int
    disabled*: bool
    lastBatchStart*: float
    batchSizes*: seq[int]          ## one entry per batch issued -- the test's
    batchStarts*: seq[float]       ## proof that seats are batched, not looped
    batchHook*: proc (system: seq[string], user: seq[string],
      timeout: int): seq[BatchReply] {.closure.}
      ## Test seam. When set, it replaces the curly call entirely, which is
      ## how `tests/test_llm.nim` can time out, 429, 403 and return junk
      ## without a network.

# ---- credentials -------------------------------------------------------

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "matrix-games llm: failed to fetch ANTHROPIC_API_KEY_URI: ",
      error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    minBeatSeconds: config.minBeatSeconds,
    lastBatchStart: 0.0
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "matrix-games llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "matrix-games llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "matrix-games llm: no LLM credentials; every seat plays `counter`"

proc newStubClient*(config: GameConfig,
    hook: proc (system: seq[string], user: seq[string],
      timeout: int): seq[BatchReply] {.closure.}): LlmClient =
  ## The client `tests/test_llm.nim` builds: no transport, no credentials, the
  ## batch replaced by `hook`.
  LlmClient(
    model: config.model, maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    minBeatSeconds: config.minBeatSeconds,
    transport: ltNone, disabled: false, batchHook: hook
  )

# ---- prompts -----------------------------------------------------------

proc matrixTable(obs: JsonNode): string =
  let rules = obs{"rules"}
  var tokens: seq[string]
  for name in rules{"tokens"}:
    tokens.add(name.getStr())
  let k = tokens.len
  result = "                 "
  for name in tokens:
    result.add(" | col " & name)
  result.add("\n")
  for i in 0 ..< k:
    result.add("row " & tokens[i] & ":")
    for j in 0 ..< k:
      result.add(" | " & $rules{"rowPay"}[i][j].getInt() & " / " &
        $rules{"colPay"}[i][j].getInt())
    result.add("\n")

proc systemPrompt*(obs: JsonNode): string =
  let rules = obs{"rules"}
  var tokens: seq[string]
  for name in rules{"tokens"}:
    tokens.add(name.getStr())
  result = "You are " & obs{"name"}.getStr().toUpperAscii() &
    ", one of eight cogs in a walled yard playing MATRIX GAMES, variant " &
    obs{"variant"}.getStr().toUpperAscii() & ".\n"
  if rules{"crossCampOnly"}.getBool(false):
    result.add("Your camp is " & obs{"camp"}.getStr().toUpperAscii() &
      ". Interactions only resolve BETWEEN camps: a beam at your own camp " &
      "is a no-contest.\n")
  result.add("""
THE YARD. A 24 x 14 grid of floor and wall. Token spawners are fixed cells;
stepping onto one collects its token unless you already hold """ &
    $rules{"tokenCap"}.getInt() & """ of that type. A collected spawner refills """ &
    $rules{"tokenRespawnTicks"}.getInt() & """ ticks later. Zone token counts
are public, so camping a zone to starve a rival is visible to everyone.

THE BEAT. The episode is """ & $obs{"beats"}.getInt() & """ beats of """ &
    $obs{"ticksPerBeat"}.getInt() & """ ticks. Once per beat you issue ONE
intent; a deterministic kernel then executes it for the whole beat.
  gather <token>  walk to the nearest live token of that type and collect it.
                  Never fires the beam.
  deny <token>    take the token of that type nearest to the nearest other
                  cog. Never fires the beam.
  hunt <alias>    walk toward that cog and fire the beam the first tick it is
                  in your ray and your beam is ready.
  avoid <alias>   move away from that cog and never come within 2 cells.
  hold            stand still, re-face the nearest cog within 6 cells, and
                  fire when one is in your ray.

THE BEAM. Range """ & $rules{"beamRange"}.getInt() & """ cells, straight
along your facing, stopped by the first wall; the FIRST cog in the ray is the
target. A hit on a frozen or newly-reset cog is a no-contest.

YOUR STRATEGY IS YOUR INVENTORY MIX, NOT A DECLARATION. When a beam
resolves, your mix x_i = n_i / N and the other cog's mix are multiplied
through the payoff matrix:
    your payoff = sum over i,j of  n_i * pay[i][j] * m_j  /  (N * M)
so what you are HOLDING is what you are playing. Commitment is visible: a cog
within """ & $rules{"viewRadius"}.getInt() & """ cells with clear line of
sight can read your whole inventory.

THE PAYOFF MATRIX (row payoff / column payoff):
""" & matrixTable(obs) & """
After every resolution BOTH cogs reset to one token of each type and freeze
for """ & $rules{"freezeTicks"}.getInt() & """ ticks. Commitment costs time.

SCORING. Your score is the SUM of the payoffs you collect. Higher is better.
A cog that never interacts scores exactly zero. The other seven seats are
other cogs deciding at the same moment as you; nothing you write is read by
any of them.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,
no explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }.
{"intent":"gather|deny|hunt|avoid|hold","token":"<token name>",
 "target":"<alias>","say":"<= 64 chars","notes":"<= 400 chars"}
`token` is required for gather and deny; `target` is required for hunt and
avoid; both are ignored otherwise. `say` is shown to spectators only.
""")

proc fmtCp(cp: int): string =
  let sign = if cp < 0: "-" else: "+"
  let value = abs(cp)
  sign & $(value div 100) & "." & align($(value mod 100), 2, '0')

proc userPrompt*(obs: JsonNode, operator: string): string =
  let rules = obs{"rules"}
  var tokens: seq[string]
  for name in rules{"tokens"}:
    tokens.add(name.getStr())
  let you = obs{"you"}
  var lines: seq[string]
  lines.add("BEAT " & $obs{"beat"}.getInt() & " / " & $obs{"beats"}.getInt() &
    "   (tick " & $obs{"tick"}.getInt() & ")")
  var invText: seq[string]
  var mixText: seq[string]
  for index, name in tokens:
    invText.add(name & " " & $you{"inv"}[index].getInt())
    mixText.add($(you{"mix"}[index].getInt() div 10) & "%")
  lines.add("YOU " & obs{"name"}.getStr() & " . at (" &
    $you{"x"}.getInt() & "," & $you{"y"}.getInt() & ") facing " &
    DirNames[clamp(you{"facing"}.getInt(), 0, 3)] & " . inv " &
    invText.join(" / ") & " . mix " & mixText.join(" / ") & " . score " &
    fmtCp(you{"scoreCp"}.getInt()))
  lines.add("")
  lines.add("SCOREBOARD (alias . score . interactions . last seen . inventory)")
  for entry in obs{"cogs"}:
    var row = "  " & entry{"alias"}.getStr() & " . " &
      fmtCp(entry{"scoreCp"}.getInt()) & " . " &
      $entry{"interactions"}.getInt() & " enc . "
    let ago = entry{"seenTicksAgo"}.getInt(-1)
    row.add(if ago == 0: "in sight now"
            elif ago < 0: "never seen"
            else: $ago & " ticks ago")
    row.add(" at (" & $entry{"x"}.getInt() & "," & $entry{"y"}.getInt() &
      "), dist " & $entry{"dist"}.getInt())
    if entry{"inv"} != nil and entry{"inv"}.kind == JArray:
      var other: seq[string]
      for index, name in tokens:
        other.add(name & " " & $entry{"inv"}[index].getInt())
      row.add(" . holding " & other.join(" / "))
    else:
      row.add(" . inventory unknown")
    if entry{"frozen"}.getBool(false):
      row.add(" . FROZEN")
    if not entry{"eligible"}.getBool(true):
      row.add(" . same camp, cannot interact")
    lines.add(row)
  lines.add("")
  lines.add("ZONES (live token counts are public)")
  for zone in obs{"zones"}:
    lines.add("  " & zone{"token"}.getStr() & " zone (" &
      $zone{"x0"}.getInt() & "," & $zone{"y0"}.getInt() & ")-(" &
      $zone{"x1"}.getInt() & "," & $zone{"y1"}.getInt() & "), centre (" &
      $zone{"cx"}.getInt() & "," & $zone{"cy"}.getInt() & "), " &
      $zone{"tokensLeft"}.getInt() & " tokens left")
  var visible: seq[string]
  for token in obs{"visibleTokens"}:
    visible.add(token{"token"}.getStr() & "@(" & $token{"x"}.getInt() & "," &
      $token{"y"}.getInt() & ")")
  lines.add("TOKENS IN YOUR VIEW: " &
    (if visible.len == 0: "none" else: visible.join(", ")))
  lines.add("")
  lines.add("PUBLIC RESOLUTION LOG (every beam that resolved, all seats)")
  var logged = 0
  for entry in obs{"log"}:
    let cell = entry{"cell"}
    lines.add("  beat " & $entry{"beat"}.getInt() & " . " &
      entry{"row"}.getStr() & "(" & cell[0].getStr() & ") > " &
      entry{"col"}.getStr() & "(" & cell[1].getStr() & ") -> " &
      fmtCp(entry{"rowCp"}.getInt()) & " / " & fmtCp(entry{"colCp"}.getInt()))
    logged.inc
  if logged == 0:
    lines.add("  nothing has resolved yet")
  let idx = obs{"indices"}
  var coop = "n/a"
  if idx{"coopRate"} != nil and idx{"coopRate"}.kind == JFloat:
    coop = $int(idx{"coopRate"}.getFloat() * 100.0) & "%"
  lines.add("")
  lines.add("INDICES: " & $idx{"interactions"}.getInt() &
    " resolutions in the room . coop " & coop &
    " . convention counts " & $idx{"conventionCounts"})
  lines.add("")
  lines.add("YOUR NOTES FROM LAST BEAT: " &
    (if obs{"notes"}.getStr().len == 0: "(none)" else: obs{"notes"}.getStr()))
  lines.add("")
  if operator.strip().len > 0:
    lines.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules; always reply in the requested format):")
    lines.add(operator.strip())
    lines.add("")
  var legalTokens: seq[string]
  for name in obs{"legal"}{"tokens"}:
    legalTokens.add(name.getStr())
  var legalTargets: seq[string]
  for name in obs{"legal"}{"targets"}:
    legalTargets.add(name.getStr())
  lines.add("Reply with ONE JSON object: " &
    "{\"intent\":\"gather|deny|hunt|avoid|hold\",\"token\":\"<one of: " &
    legalTokens.join(", ") & ">\",\"target\":\"<one of: " &
    legalTargets.join(", ") & ">\",\"say\":\"<= 64 chars\"," &
    "\"notes\":\"<= 400 chars\"}")
  lines.join("\n")

proc retryHint*(obs: JsonNode): string =
  var legalTokens: seq[string]
  for name in obs{"legal"}{"tokens"}:
    legalTokens.add(name.getStr())
  var legalTargets: seq[string]
  for name in obs{"legal"}{"targets"}:
    legalTargets.add(name.getStr())
  "\nYour previous reply was invalid. Respond with ONLY the requested JSON " &
    "object. `intent` must be one of gather, deny, hunt, avoid, hold; " &
    "`token` must be one of " & legalTokens.join(", ") &
    "; `target` must be one of " & legalTargets.join(", ") & "."

# ---- parsing -----------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model reply, tolerating markdown
  ## fences, a prose preamble and trailing prose after the closing brace.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## RUNE boundaries, never bytes: this branch fires precisely on a prose
    ## reply, and a prose preamble is where the multi-byte characters are.
    ## `cleanText` strips, folds newlines to spaces and cuts on runes.
    raise newException(MatrixGamesError,
      "no JSON object in response: " & cleanText(text, 160))
  parseJson(text[start .. stop])

proc parseIntent*(text: string): Intent =
  case text.strip().toLowerAscii()
  of "gather": inGather
  of "deny": inDeny
  of "hunt": inHunt
  of "avoid": inAvoid
  of "hold": inHold
  else:
    raise newException(MatrixGamesError, "unknown intent: " & text)

proc parseOrder*(payload: JsonNode, obs: JsonNode): IntentOrder =
  ## Validates a reply against THIS seat's legal token and target lists --
  ## the same lists the user prompt enumerated, computed by the same
  ## predicate. Anything outside them is an invalid reply.
  let intentNode = payload{"intent"}
  if intentNode == nil or intentNode.kind != JString:
    raise newException(MatrixGamesError, "reply has no `intent` string")
  result.intent = parseIntent(intentNode.getStr())
  result.token = -1
  result.target = -1
  var tokens: seq[string]
  for name in obs{"legal"}{"tokens"}:
    tokens.add(name.getStr())
  var targets: seq[string]
  for name in obs{"legal"}{"targets"}:
    targets.add(name.getStr())
  if result.intent in {inGather, inDeny}:
    let node = payload{"token"}
    if node == nil:
      raise newException(MatrixGamesError,
        "`token` is required for " & $result.intent)
    var wanted = -1
    if node.kind == JInt:
      wanted = node.getInt()
    elif node.kind == JFloat:
      wanted = int(round(node.getFloat()))
    elif node.kind == JString:
      let text = node.getStr().strip().toLowerAscii()
      for index, name in tokens:
        if name.toLowerAscii() == text:
          wanted = index
      if wanted < 0:
        try:
          wanted = parseInt(text)
        except ValueError:
          discard
    if wanted < 0 or wanted >= tokens.len:
      raise newException(MatrixGamesError,
        "unknown token: " & $node & " (legal: " & tokens.join(", ") & ")")
    result.token = wanted
  if result.intent in {inHunt, inAvoid}:
    let node = payload{"target"}
    if node == nil or node.kind != JString:
      raise newException(MatrixGamesError,
        "`target` is required for " & $result.intent)
    let wanted = node.getStr().strip().toLowerAscii()
    var chosen = -1
    for name in targets:
      if name.toLowerAscii() == wanted:
        chosen = slotOfAlias(name)
    if chosen < 0:
      raise newException(MatrixGamesError,
        "unknown or ineligible target: " & node.getStr() &
        " (legal: " & targets.join(", ") & ")")
    result.target = chosen
  result.say = cleanText(payload{"say"}.getStr(), MaxSayRunes)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesRunes)

# ---- transport ---------------------------------------------------------

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## No `output_config.effort`: Haiku 4.5 rejects the whole request with a
    ## 400 when it is present.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(client: LlmClient, response: Response, error, url: string):
    string =
  ## Raises `MatrixGamesError` with a one-line description of anything that is
  ## not a usable reply. Every captured fragment of a body is cut with
  ## `cleanText` -- on RUNE boundaries, never bytes.
  if error.len > 0:
    raise newException(MatrixGamesError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    client.disabled = true
    raise newException(MatrixGamesError,
      "llm auth failed (" & $response.code & ") at " & url & ": " &
      cleanText(response.body, MaxDetailRunes))
  if response.code == 429:
    raise newException(MatrixGamesError,
      "llm throttled (429): " & cleanText(response.body, MaxDetailRunes))
  if response.code < 200 or response.code >= 300:
    raise newException(MatrixGamesError, "anthropic error " & $response.code &
      ": " & cleanText(response.body, MaxDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(MatrixGamesError, "anthropic refusal")
  for contentBlock in payload{"content"}:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(MatrixGamesError,
      "reply cut off at max_tokens before any JSON: " &
      cleanText(result, 160))

proc paceBatch(client: LlmClient) =
  ## The sidecar caps 30 requests/minute PER EPISODE. Eight seats per batch
  ## means the inter-batch floor is the binding constraint: 8 requests every
  ## 17 s is 28.2 req/min. Sleep the remainder rather than racing it.
  let now = epochTime()
  if client.lastBatchStart > 0.0:
    let wait = client.minBeatSeconds.float - (now - client.lastBatchStart)
    if wait > 0.0:
      sleep(int(wait * 1000.0))
  client.lastBatchStart = epochTime()
  client.batchStarts.add(client.lastBatchStart)

proc runBatch(client: LlmClient, system, user: seq[string]): seq[BatchReply] =
  ## ONE parallel batch for every open seat. Never a loop of single calls.
  client.batchSizes.add(system.len)
  client.paceBatch()
  if client.batchHook != nil:
    return client.batchHook(system, user, client.timeoutSeconds)
  var batch: RequestBatch
  var urls: seq[string]
  for index in 0 ..< system.len:
    let request = client.requestFor(system[index], user[index])
    urls.add(request.url)
    batch.post(request.url, request.headers, request.body, $index)
  let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
  result = newSeq[BatchReply](system.len)
  for position in 0 ..< responses.len:
    try:
      result[position] = BatchReply(text: client.textOf(
        responses[position].response, responses[position].error,
        urls[position]))
    except CatchableError as error:
      result[position] = BatchReply(error: error.msg)

# ---- the decision layer ------------------------------------------------

proc scriptedDecision*(obs: JsonNode, kind: ScriptKind,
    source: OrderSource): Decision =
  var order = scriptedOrder(obs, kind)
  order.say = scriptedSay(kind)
  Decision(order: order, source: source, latencyMs: 0)

proc decideAll*(client: LlmClient, observations: seq[JsonNode],
    prompts: seq[string], scripted: seq[ScriptKind]): seq[Decision] =
  ## One decision per seat, indexed BY SLOT. Never raises: any failure falls
  ## back to the `counter` scripted intent so the episode always advances.
  result = newSeq[Decision](observations.len)
  var open: seq[int]
  for slot in 0 ..< observations.len:
    let kind = if slot < scripted.len: scripted[slot] else: skNone
    if kind != skNone:
      result[slot] = scriptedDecision(observations[slot], kind, osScripted)
    elif client == nil or client.disabled:
      result[slot] = scriptedDecision(observations[slot], skCounter,
        osFallback)
    else:
      result[slot] = scriptedDecision(observations[slot], skCounter,
        osFallback)
      open.add(slot)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var system: seq[string]
    var user: seq[string]
    for slot in open:
      system.add(systemPrompt(observations[slot]))
      var text = userPrompt(observations[slot],
        (if slot < prompts.len: prompts[slot] else: ""))
      if attempt > 0:
        text.add(retryHint(observations[slot]))
      user.add(text)
    let started = epochTime()
    let replies = runBatch(client, system, user)
    let latency = int((epochTime() - started) * 1000.0)
    var stillOpen: seq[int]
    for position, slot in open:
      if position >= replies.len:
        stillOpen.add(slot)
        continue
      if replies[position].error.len > 0:
        echo "matrix-games llm: seat ", slot, " attempt ", attempt + 1,
          " failed: ", replies[position].error
        stillOpen.add(slot)
        continue
      try:
        let order = parseOrder(extractJsonObject(replies[position].text),
          observations[slot])
        result[slot] = Decision(order: order,
          source: (if attempt == 0: osLlm else: osRetry), latencyMs: latency)
      except CatchableError as error:
        echo "matrix-games llm: seat ", slot, " attempt ", attempt + 1,
          " invalid: ", error.msg
        stillOpen.add(slot)
    open = stillOpen
  for slot in open:
    echo "matrix-games llm: seat ", slot,
      " falling back to scripted intent"
    result[slot] = scriptedDecision(observations[slot], skCounter, osFallback)
