## GameConfig lifecycle: defaults, the runtime JSON overlay, validation and
## the fully resolved config document pinned verbatim into every replay.
##
## Fork of paintbot's `src/ctf/sim_config.nim`. The field list IS the
## `game.config_schema` in `coworld_manifest_template.json`;
## `tests/test_manifest.nim` keeps the two in step.

import std/[json, strutils]
import sim_types, matrices

type
  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]              ## one connection token per seat
    players*: seq[PlayerConfig]
    seed*: int
    numAgents*: int
    matrix*: string
    beats*: int
    ticksPerBeat*: int
    tokenCap*: int
    tokenRespawnTicks*: int
    beamRange*: int
    freezeTicks*: int
    stepCooldownTicks*: int
    beamResetCooldown*: int
    beamMissCooldown*: int
    viewRadius*: int
    llmTimeoutSeconds*: int
    minBeatSeconds*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: Seats,
    matrix: DefaultMatrix,
    beats: BeatsDefault,
    ticksPerBeat: TicksPerBeatDefault,
    tokenCap: TokenCapDefault,
    tokenRespawnTicks: TokenRespawnDefault,
    beamRange: BeamRangeDefault,
    freezeTicks: FreezeTicksDefault,
    stepCooldownTicks: StepCooldownDefault,
    beamResetCooldown: BeamResetCooldownDefault,
    beamMissCooldown: BeamMissCooldownDefault,
    viewRadius: ViewRadiusDefault,
    llmTimeoutSeconds: 20,
    minBeatSeconds: 17,
    maxOutputTokens: 900,
    model: "claude-haiku-4-5",
    episodeTimeoutSeconds: 1200,
    playerConnectTimeoutSeconds: 180,
    shutdownGraceSeconds: 20
  )

proc maxTicks*(config: GameConfig): int =
  config.beats * config.ticksPerBeat

proc playDeadlineSeconds*(config: GameConfig): float =
  ## The game container is NOT given COWORLD_TIMEOUT_SECONDS -- only the
  ## worker sidecar is -- so 1200 is assumed unless the config supplies it,
  ## and play must settle inside 60 % of it.
  0.6 * config.episodeTimeoutSeconds.float

proc beatBudgetSeconds*(config: GameConfig): int =
  ## The worst case for ONE beat: the decision batch plus its single retry.
  ## The design note's arithmetic, per beat (design.md, "the play budget").
  2 * config.llmTimeoutSeconds

proc startupBudgetSeconds*(config: GameConfig): int =
  ## Everything spent before the first beat can start. The play deadline is
  ## measured from PROCESS START, so the connect wait and the registration
  ## grace come out of the same budget.
  config.playerConnectTimeoutSeconds + RegistrationGraceSeconds

proc validate*(config: GameConfig) =
  if config.numAgents != Seats:
    raise newException(MatrixGamesError,
      "num_agents must be " & $Seats & ", got " & $config.numAgents)
  discard matrixSpec(config.matrix)
  if config.beats < 1 or config.beats > 24:
    raise newException(MatrixGamesError, "beats must be in 1..24")
  if config.ticksPerBeat < 10 or config.ticksPerBeat > 120:
    raise newException(MatrixGamesError, "ticksPerBeat must be in 10..120")
  if config.tokenCap < 2 or config.tokenCap > 16:
    raise newException(MatrixGamesError, "tokenCap must be in 2..16")
  if config.beamRange < 1 or config.beamRange > 8:
    raise newException(MatrixGamesError, "beamRange must be in 1..8")
  if config.stepCooldownTicks < 1 or config.stepCooldownTicks > 10:
    raise newException(MatrixGamesError, "stepCooldownTicks must be in 1..10")
  if config.viewRadius < 1 or config.viewRadius > 24:
    raise newException(MatrixGamesError, "viewRadius must be in 1..24")
  if config.llmTimeoutSeconds < 1:
    raise newException(MatrixGamesError, "llmTimeoutSeconds must be positive")
  ## The whole point of the arithmetic in the design note: worst case is
  ## beats x (attempt + retry), and it has to fit inside 60 % of the episode
  ## timeout with room to spare. The play deadline is measured from PROCESS
  ## START, so the connect wait and the registration grace are spent out of
  ## the same budget and are counted here -- otherwise the note's headroom is
  ## imaginary and a config that cannot finish in time starts anyway.
  ##
  ## What is REQUIRED is that the startup wait plus ONE beat fit, not that all
  ## `beats` of them do. `game.config_schema` publishes `beats` up to 24, and
  ## a cross-field budget like this one cannot be expressed in JSON Schema, so
  ## demanding the full worst case here made schema-legal configs (beats 14..24
  ## at the shipped timeouts) exit 2 before the server started. They now start
  ## and DEGRADE as designed: `server.runGame` refuses to open a beat that
  ## cannot finish before the deadline and settles with reason "deadline",
  ## which keeps the episode inside 60 % of `episodeTimeoutSeconds` either way.
  ## A config with no room for even one beat is still a hard error: there is
  ## nothing to degrade to.
  let worst = config.startupBudgetSeconds() + config.beatBudgetSeconds()
  if worst.float > config.playDeadlineSeconds():
    raise newException(MatrixGamesError,
      "playerConnectTimeoutSeconds + " & $RegistrationGraceSeconds &
      " + 2 x llmTimeoutSeconds (" & $worst &
      " s) must fit inside 60% of episodeTimeoutSeconds (" &
      $int(config.playDeadlineSeconds()) & " s)")

proc update*(config: var GameConfig, configJson: string) =
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(MatrixGamesError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("num_agents"):
    config.numAgents = node["num_agents"].getInt()
  if node.hasKey("matrix"):
    config.matrix = node["matrix"].getStr()
  if node.hasKey("beats"):
    config.beats = node["beats"].getInt()
  if node.hasKey("ticksPerBeat"):
    config.ticksPerBeat = node["ticksPerBeat"].getInt()
  if node.hasKey("tokenCap"):
    config.tokenCap = node["tokenCap"].getInt()
  if node.hasKey("tokenRespawnTicks"):
    config.tokenRespawnTicks = node["tokenRespawnTicks"].getInt()
  if node.hasKey("beamRange"):
    config.beamRange = node["beamRange"].getInt()
  if node.hasKey("freezeTicks"):
    config.freezeTicks = node["freezeTicks"].getInt()
  if node.hasKey("stepCooldownTicks"):
    config.stepCooldownTicks = node["stepCooldownTicks"].getInt()
  if node.hasKey("beamResetCooldown"):
    config.beamResetCooldown = node["beamResetCooldown"].getInt()
  if node.hasKey("beamMissCooldown"):
    config.beamMissCooldown = node["beamMissCooldown"].getInt()
  if node.hasKey("viewRadius"):
    config.viewRadius = node["viewRadius"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if node.hasKey("minBeatSeconds"):
    config.minBeatSeconds = node["minBeatSeconds"].getInt()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("playerConnectTimeoutSeconds"):
    config.playerConnectTimeoutSeconds =
      node["playerConnectTimeoutSeconds"].getInt()
  if node.hasKey("shutdownGraceSeconds"):
    config.shutdownGraceSeconds = node["shutdownGraceSeconds"].getInt()
  config.validate()

proc configJson*(config: GameConfig): JsonNode =
  ## The fully resolved config, CONNECTION TOKENS EXCLUDED, as pinned into
  ## the replay. The matrix is inlined so the viewer never has to know the
  ## variant table.
  let spec = matrixSpec(config.matrix)
  var tokens = newJArray()
  for name in spec.tokens:
    tokens.add(%name)
  var rowPay = newJArray()
  var colPay = newJArray()
  for i in 0 ..< spec.k:
    rowPay.add(%spec.rowPay[i])
    colPay.add(%spec.colPay[i])
  var endowment = newJArray()
  for _ in 0 ..< spec.k:
    endowment.add(%1)
  %*{
    "matrix": config.matrix,
    "K": spec.k,
    "tokens": tokens,
    "rowPay": rowPay,
    "colPay": colPay,
    "coopToken": spec.coopToken,
    "num_agents": config.numAgents,
    "beats": config.beats,
    "ticksPerBeat": config.ticksPerBeat,
    "tokenCap": config.tokenCap,
    "endowment": endowment,
    "beamRange": config.beamRange,
    "freezeTicks": config.freezeTicks,
    "stepCooldownTicks": config.stepCooldownTicks,
    "beamResetCooldown": config.beamResetCooldown,
    "beamMissCooldown": config.beamMissCooldown,
    "tokenRespawnTicks": config.tokenRespawnTicks,
    "viewRadius": config.viewRadius,
    "crossCampOnly": spec.crossCampOnly,
    "fps": TargetFps
  }
