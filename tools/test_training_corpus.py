"""Validate complete private candidates through the native replay verifier."""

import hashlib
import json
import stat
import subprocess
import sys
from pathlib import Path

root, verifier = map(Path, sys.argv[1:])
manifest = json.loads((root / "manifest.json").read_text())
assert manifest["format"] == "coworld-private-candidates-v1"
assert manifest["review_required"]
assert stat.S_IMODE(root.stat().st_mode) == 0o700
assert not (root / "train.jsonl").exists() and not (root / "validation.jsonl").exists()
aggregate = []
for run in manifest["runs"]:
    path = root / run["trajectory"]
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    records = [json.loads(line) for line in path.read_text().splitlines()]
    aggregate.extend(records)
    episode = records[-1]
    decisions = records[:-1]
    assert episode["status"] == "completed"
    assert episode["seed_family"] == "matrix-games-" + str(run["seed"])
    assert episode["source_revision"] == manifest["source_revision"]
    assert len(decisions) == run["decisions"]
    assert all(decision["terminal"] for decision in decisions[-8:])
    subprocess.run([verifier, path, root / run["replay"]], check=True)
    for decision in decisions:
        (selected,) = decision["attempts"]
        assert selected["attempt_id"] == decision["selected_attempt_id"]
        assert (
            selected["origin"] == "teacher" and selected["policy"] == "scripted-counter"
        )
        assert (
            selected["accepted"]
            and selected["parsed_action"] == decision["executed_action"]
        )
        assert selected["request"] is None and selected["platform_call_id"] is None
        assert json.loads(selected["response"]) == decision["executed_action"]
        metadata = decision["observation"]["prompt_template"]
        assert metadata["variant"] == manifest["prompt_configuration"]["variant"]
        for role, index in (("system", 0), ("user", 1)):
            assert (
                metadata[role + "_sha256"]
                == hashlib.sha256(
                    selected["prompt"][index]["content"].encode()
                ).hexdigest()
            )
assert aggregate == [
    json.loads(line) for line in (root / "trajectories.jsonl").read_text().splitlines()
]
assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in root.iterdir())
print(
    "Private complete candidates and replay checks passed:",
    manifest["variant"],
    len(manifest["runs"]),
)
