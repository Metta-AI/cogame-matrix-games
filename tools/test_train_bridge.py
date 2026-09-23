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
for variant in variants:
    with subprocess.Popen(
        [sys.argv[1], str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as bridge:
        assert bridge.stdin is not None and bridge.stdout is not None

        def request(payload):
            bridge.stdin.write(json.dumps(payload) + "\n")
            bridge.stdin.flush()
            return json.loads(bridge.stdout.readline())

        observation = request({"kind": "reset", "seed": "bridge-test", "players": 8})
        decisions = 0
        legal_widths = set()
        while observation["kind"] == "decision":
            encoded = request({"kind": "encode"})
            assert encoded["decision_id"] == observation["decision_id"]
            assert len(encoded["values"]) == 140 and len(encoded["actions"]) == 21
            legal_widths.add(sum(action is not None for action in encoded["actions"]))
            response = request({"kind": "teacher"})["response"]
            action = json.loads(response)
            assert action in encoded["actions"]
            result = request({"kind": "step", "decision_id": observation["decision_id"], "response": response})
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
        assert decisions == 96 and set(observation["scores"]) == {str(seat) for seat in range(8)}
        assert legal_widths == ({13} if variant == "bach-or-stravinsky" else {19} if variant in (
            "prisoners-dilemma", "chicken", "stag-hunt"
        ) else {21})
        bridge.stdin.close()
        assert bridge.wait() == 0
    print(f"{variant}: {decisions} decisions")
