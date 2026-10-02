"""Exercise every certified Matrix Games variant through its JSONL bridge."""

import json
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
variants = (
    "running-with-scissors",
    "prisoners-dilemma",
    "chicken",
    "stag-hunt",
    "bach-or-stravinsky",
    "pure-coordination",
    "rationalizable-coordination",
)
for language in [False, True]:
    for variant in variants:
        command = [sys.argv[1], str(manifest), variant]
        if language:
            command.append("--language")
        with subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
        ) as bridge:
            assert bridge.stdin is not None and bridge.stdout is not None

            def request(payload):
                bridge.stdin.write(json.dumps(payload) + "\n")
                bridge.stdin.flush()
                return json.loads(bridge.stdout.readline())

            observation = request(
                {"kind": "reset", "seed": "bridge-test", "players": 8}
            )
            decisions = 0
            legal_widths = set()
            while observation["kind"] == "decision":
                assert [message["role"] for message in observation["messages"]] == [
                    "system",
                    "user",
                ]
                response = request({"kind": "teacher"})["response"]
                action = json.loads(response)
                if language:
                    assert "notes" in action and "say" in action
                    action["notes"] = "Private training memory"
                    action["say"] = "Public speech"
                    response = "```json\n" + json.dumps(action) + "\n```"
                    if observation["turn"] > 0:
                        assert (
                            observation["semantic_view"]["notes"]
                            == "Private training memory"
                        )
                else:
                    encoded = request({"kind": "encode"})
                    assert encoded["decision_id"] == observation["decision_id"]
                    assert (
                        len(encoded["values"]) == 140 and len(encoded["actions"]) == 21
                    )
                    legal_widths.add(
                        sum(action is not None for action in encoded["actions"])
                    )
                    assert action in encoded["actions"]
                result = request(
                    {
                        "kind": "step",
                        "decision_id": observation["decision_id"],
                        "response": response,
                    }
                )
                assert result["kind"] == "accepted" and result["action"] == action
                observation = result["observation"]
                decisions += 1
            assert decisions == 96 and set(observation["scores"]) == {
                str(seat) for seat in range(8)
            }
            if not language:
                expected = (
                    13
                    if variant == "bach-or-stravinsky"
                    else 19
                    if variant in ("prisoners-dilemma", "chicken", "stag-hunt")
                    else 21
                )
                assert legal_widths == {expected}
            bridge.stdin.close()
            assert bridge.wait() == 0
        print(f"{variant}: {decisions} decisions; language={language}")
