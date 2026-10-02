import std/unittest
include ../src/matrix_games/server
import support/helpers

suite "external training authority":
  test "player assertions cannot create teacher labels":
    for origin in [aoTeacher, aoHuman]:
      let game = initSim(testConfig("chicken", 17, 2))
      var state = ServerState(actions: newSeq[JsonNode](Seats),
        attempts: newSeq[seq[DecisionAttempt]](Seats))
      let action = %*{"intent": "hold", "say": "public", "notes": "private"}
      var evidence = newDecisionAttempt("teacher-claim", "external", origin)
      evidence.response = %($action)
      state.acceptExternalAction(game, 0, %*{"action": action,
        "attempts": [evidence.attemptEvidenceJson()]})
      check state.attempts[0][0].origin == aoUnknown
      check not state.actions[0].isNil

  test "model text must independently match the submitted canonical action":
    let game = initSim(testConfig("chicken", 17, 2))
    var state = ServerState(actions: newSeq[JsonNode](Seats),
      attempts: newSeq[seq[DecisionAttempt]](Seats))
    let generated = %*{"intent": "hold", "say": "model speech", "notes": "private"}
    let submitted = %*{"intent": "hold", "say": "different speech", "notes": "private"}
    var evidence = newDecisionAttempt("native-model", "model", aoModel)
    evidence.response = %($generated)
    expect MatrixGamesError:
      state.acceptExternalAction(game, 0, %*{"action": submitted,
        "attempts": [evidence.attemptEvidenceJson()]})
    check state.actions[0].isNil
    check not state.attempts[0][0].accepted
    check state.attempts[0][0].parsedAction["say"].getStr() == "model speech"

  test "matching native response remains eligible for an engine join":
    let game = initSim(testConfig("chicken", 17, 2))
    var state = ServerState(actions: newSeq[JsonNode](Seats),
      attempts: newSeq[seq[DecisionAttempt]](Seats))
    let generated = %*{"intent": "hold", "say": "public", "notes": "private"}
    var evidence = newDecisionAttempt("native-model", "model", aoModel)
    evidence.response = %($generated)
    state.acceptExternalAction(game, 0, %*{"action": generated,
      "attempts": [evidence.attemptEvidenceJson()]})
    check state.attempts[0][0].origin == aoModel
    check state.attempts[0][0].parsedAction ==
      actionJson(parseOrder(state.actions[0], buildObservation(game, 0)), buildObservation(game, 0))
