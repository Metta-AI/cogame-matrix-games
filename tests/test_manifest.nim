## Packaging: everything the platform validator and the certifier check that
## repo CI can check first.

import std/[json, os, strutils, unittest]
import matrix_games/[sim_types, sim_config, matrices, server]

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

suite "coworld_manifest_template.json":
  setup:
    let root = repoRoot()
    let manifest = parseJson(readFile(root / "coworld_manifest_template.json"))
    let game = manifest{"game"}

  test "num_agents is 8 in all seven variants AND the cert fixture":
    check manifest{"variants"}.len == MatrixNames.len
    for variant in manifest{"variants"}:
      check variant{"game_config"}{"num_agents"}.getInt() == Seats
      check variant{"game_config"}{"players"}.len == Seats
    check manifest{"certification"}{"game_config"}{"num_agents"}.getInt() ==
      Seats
    check manifest{"certification"}{"game_config"}{"players"}.len == Seats
    check manifest{"certification"}{"players"}.len == Seats

  test "every variant names one of the seven matrices, with a description":
    var seen: seq[string]
    for variant in manifest{"variants"}:
      let id = variant{"id"}.getStr()
      check id notin seen
      seen.add(id)
      check variant{"description"}.getStr().len > 0
      let matrix = variant{"game_config"}{"matrix"}.getStr()
      check matrix in MatrixNames
      discard matrixSpec(matrix)
    for name in MatrixNames:
      check name in seen

  test "the image placeholder is the one derived from compose.yaml":
    ## `coworld build` derives the placeholder from the compose SERVICE name
    ## and hard-fails anything else (the lantern learning). Derive it here the
    ## same way rather than hard-coding it.
    var service = ""
    var inServices = false
    for line in readFile(root / "compose.yaml").splitLines():
      if line.startsWith("services:"):
        inServices = true
        continue
      if not inServices:
        continue
      if line.len > 2 and line[0] == ' ' and line[1] == ' ' and
          line[2] != ' ' and line.strip().endsWith(":"):
        service = line.strip().strip(chars = {':'})
        break
    check service.len > 0
    let placeholder = "{{" & service.toUpperAscii() & "_IMAGE}}"
    check placeholder == "{{GAME_IMAGE}}"
    check game{"runnable"}{"image"}.getStr() == placeholder
    for player in manifest{"player"}:
      check player{"image"}.getStr() == placeholder

  test "the replay viewer is the static bundle, never a pod":
    check game{"replay_viewer"}{"bundle"}.getStr() == "static-replay-viewer"
    check game{"replay_viewer"}{"url"} == nil
    check "/client/replay" notin $game{"runnable"}
    ## And no pod path serves the broadcast page under ANY name: the asset
    ## route refuses it, so the only replay viewer is the S3 bundle.
    check not servableClientAsset("replay_broadcast.html")
    check not servableClientAsset("../client/replay_broadcast.html")
    check not servableClientAsset(".env")
    ## The assets the two live pages really do need are still served.
    for name in ["chrome_common.js", "broadcast_core.js", "global.html",
        "player.html"]:
      check servableClientAsset(name)

  test "docs are text objects with a readme and non-empty pages":
    check game{"docs"}{"readme"}{"type"}.getStr() == "text"
    check game{"docs"}{"readme"}{"value"}.getStr().len > 400
    check game{"docs"}{"pages"}.len >= 3
    for page in game{"docs"}{"pages"}:
      check page{"id"}.getStr().len > 0
      check page{"title"}.getStr().len > 0
      check page{"content"}{"type"}.getStr() == "text"
      check page{"content"}{"value"}.getStr().len > 200

  test "both protocols are present and both are text objects":
    ## Bare strings fail the platform validator (the garble trap) and repo CI
    ## is the only place that catches it before an upload.
    for key in ["player", "global"]:
      let node = game{"protocols"}{key}
      check node != nil
      check node.kind == JObject
      check node{"type"}.getStr() == "text"
      check node{"value"}.getStr().len > 200

  test "the game runnable declares its type and the coworld secret":
    check game{"runnable"}{"type"}.getStr() == "game"
    check game{"runnable"}{"run"}[0].getStr() == "/bin/matrix-games"
    check game{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
      "secret://coworld/matrix-games/anthropic_api_key"
    check game{"runnable"}{"source_url"}.getStr().len > 0

  test "top-level episode_timeout_minutes, $schema and >= 3 tags":
    check manifest{"$schema"}.getStr().len > 0
    check manifest{"episode_timeout_minutes"}.getInt() > 0
    check manifest{"tags"}.len >= 3

  test "every array property in config_schema carries minItems and maxItems":
    ## Certification fails `manifest_invalid` otherwise (tandem 0.1.0).
    let properties = game{"config_schema"}{"properties"}
    var arrays = 0
    for name, node in properties:
      if node{"type"}.getStr() != "array":
        continue
      arrays.inc
      check node{"minItems"} != nil
      check node{"maxItems"} != nil
    check arrays >= 2
    check game{"config_schema"}{"additionalProperties"}.getBool() == false

  test "config_schema defaults agree with the compiled defaults":
    let properties = game{"config_schema"}{"properties"}
    let defaults = defaultGameConfig()
    check properties{"num_agents"}{"default"}.getInt() == defaults.numAgents
    check properties{"beats"}{"default"}.getInt() == defaults.beats
    check properties{"ticksPerBeat"}{"default"}.getInt() ==
      defaults.ticksPerBeat
    check properties{"tokenCap"}{"default"}.getInt() == defaults.tokenCap
    check properties{"beamRange"}{"default"}.getInt() == defaults.beamRange
    check properties{"viewRadius"}{"default"}.getInt() == defaults.viewRadius
    check properties{"matrix"}{"default"}.getStr() == defaults.matrix
    check properties{"llmTimeoutSeconds"}{"default"}.getInt() ==
      defaults.llmTimeoutSeconds
    check properties{"minBeatSeconds"}{"default"}.getInt() ==
      defaults.minBeatSeconds
    check properties{"maxOutputTokens"}{"default"}.getInt() ==
      defaults.maxOutputTokens
    check properties{"shutdownGraceSeconds"}{"default"}.getInt() ==
      defaults.shutdownGraceSeconds

  test "every beats value the config schema publishes starts the game":
    ## `validate()` and `game.config_schema` are ONE contract: a config the
    ## published schema accepts must not make the container exit 2 before the
    ## server starts (`src/matrix_games.nim`). A `beats` the play budget cannot
    ## carry is truncated by the beat loop's deadline check, not refused.
    let properties = game{"config_schema"}{"properties"}
    let beats = properties{"beats"}
    for value in beats{"minimum"}.getInt() .. beats{"maximum"}.getInt():
      var config = defaultGameConfig()
      config.beats = value
      config.validate()
    ## The two other fields the budget reads, each at its published maximum.
    var slowConnect = defaultGameConfig()
    slowConnect.playerConnectTimeoutSeconds =
      properties{"playerConnectTimeoutSeconds"}{"maximum"}.getInt()
    slowConnect.validate()
    var slowModel = defaultGameConfig()
    slowModel.llmTimeoutSeconds =
      properties{"llmTimeoutSeconds"}{"maximum"}.getInt()
    slowModel.validate()

  test "a config with no room for a single beat is still refused":
    ## The floor the budget check still enforces: a cross-field constraint
    ## cannot be written in JSON Schema, so this one is the game's to keep.
    var config = defaultGameConfig()
    config.episodeTimeoutSeconds = 300      ## 180 s of play deadline
    config.playerConnectTimeoutSeconds = 180
    config.llmTimeoutSeconds = 20           ## 180 + 3 + 40 = 223 > 180
    expect MatrixGamesError:
      config.validate()
    check config.startupBudgetSeconds() + config.beatBudgetSeconds() == 223

  test "results_schema allows null exploitability and null coopRate":
    let properties = game{"results_schema"}{"properties"}
    var kinds: seq[string]
    for entry in properties{"exploitability"}{"items"}{"type"}:
      kinds.add(entry.getStr())
    check kinds == @["number", "null"]
    kinds = @[]
    for entry in properties{"coopRate"}{"type"}:
      kinds.add(entry.getStr())
    check kinds == @["number", "null"]
    var reasons: seq[string]
    for entry in properties{"reason"}{"enum"}:
      reasons.add(entry.getStr())
    for legal in LegalReasons:
      check legal in reasons

  test "six player entries, all on the player entrypoint":
    check manifest{"player"}.len == 6
    var ids: seq[string]
    for player in manifest{"player"}:
      check player{"type"}.getStr() == "player"
      check player{"name"}.getStr().len > 0
      check player{"description"}.getStr().len > 0
      check player{"run"}[0].getStr() == "/bin/matrix-games-player"
      ids.add(player{"id"}.getStr())
    check "matrix-games-player" in ids
    ## The four scripted background bots the design note asks for.
    for baseline in ["counter", "tit-for-tat", "fixed-pick", "always-first",
        "always-second"]:
      check ("matrix-games-" & baseline) in ids
    ## The bare reference policy carries NO env: PLAYER_PROMPT is supplied at
    ## upload time.
    for player in manifest{"player"}:
      if player{"id"}.getStr() == "matrix-games-player":
        check player{"env"} == nil
      else:
        check player{"env"}{"PLAYER_SCRIPTED"}.getStr().len > 0

  test "every declared player id is seated at least once in certification":
    ## `players-run` seats the whole roster; a baseline x N fixture fails
    ## `players_missing` (the raid learning).
    var seated: seq[string]
    for seat in manifest{"certification"}{"players"}:
      seated.add(seat{"player_id"}.getStr())
    for player in manifest{"player"}:
      check player{"id"}.getStr() in seated

  test "the cert fixture is longer than the ten-second viewer soak":
    let fixture = manifest{"certification"}{"game_config"}
    let ticks = fixture{"beats"}.getInt() * fixture{"ticksPerBeat"}.getInt()
    check ticks.float / TargetFps.float > 10.0

suite "tools/ci/policies.json":
  setup:
    let root = repoRoot()
    let policies = parseJson(readFile(root / "tools" / "ci" / "policies.json"))

  test "two prompt champions and two scripted fillers, all one image":
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    for policy in policies:
      check policy{"run"}.getStr() == "/bin/matrix-games-player"
      check policy{"name"}.getStr().startsWith("matrix-games-")
      if policy{"env"}{"PLAYER_PROMPT"} != nil:
        prompts.inc
        check policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 200
        ## Without USE_BEDROCK the platform gives the player pod no Bedrock
        ## sidecar and the seat silently plays scripted (the cogolf trap).
        check policy{"env"}{"USE_BEDROCK"}.getStr() == "true"
      if policy{"env"}{"PLAYER_SCRIPTED"} != nil:
        scripted.inc
        check parseScriptKind(policy{"env"}{"PLAYER_SCRIPTED"}.getStr()) !=
          skNone
    check prompts == 2
    check scripted == 2

  test "champion #2 is uploaded as daveey-1 and the prompts differ":
    check policies[0]{"player"} == nil
    check policies[1]{"player"}.getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check policies[0]{"env"}{"PLAYER_PROMPT"}.getStr() !=
      policies[1]{"env"}{"PLAYER_PROMPT"}.getStr()

suite "the CI scaffold":
  test "no unsubstituted placeholder survives in the workflows or tools/ci":
    let root = repoRoot()
    for path in [".github/workflows/ci.yml",
        ".github/workflows/coworld-release.yml",
        ".github/workflows/coworld-submit.yml",
        "tools/ci/docker_smoke.sh", "tools/ci/policies.json"]:
      let text = readFile(root / path)
      check "<slug>" notin text
      check "<IMAGE>" notin text
      check "<SEATS>" notin text

  test "both build hooks are present and executable":
    let root = repoRoot()
    for path in ["tools/build_replay_viewer.sh", "tools/ci/docker_smoke.sh"]:
      let full = root / path
      check fileExists(full)
      check (getFilePermissions(full) * {fpUserExec, fpGroupExec,
        fpOthersExec}).len > 0

  test "the seat cross-check in docker_smoke.sh agrees with the manifest":
    let root = repoRoot()
    let smoke = readFile(root / "tools" / "ci" / "docker_smoke.sh")
    check ("seats_expected=\"${SMOKE_SEATS:-" & $Seats & "}\"") in smoke
    ## It also has to assert every PLAYER container's exit code, not just the
    ## game's (the raid learning).
    check "player container ${slot} exited" in smoke
