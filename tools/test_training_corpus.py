"""Validate complete private episodes and exact projected teacher labels."""

import json
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
assert manifest["format"] == "coworld-private-complete-episodes-v1"
assert stat.S_IMODE(root.stat().st_mode) == 0o700
labels = {}
for split in ["train", "validation"]:
    path = root / (split + ".jsonl")
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(rows) == manifest[split + "_examples"] > 0
    for row in rows:
        labels[(row["episode_id"], str(row["decision_id"]))] = row
for run in manifest["runs"]:
    path = root / (run["episode_id"] + ".jsonl")
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    episode = json.loads(path.read_text())
    assert episode["episode"]["status"] == "completed"
    assert episode["episode"]["source_revision"] == manifest["source_revision"]
    assert len(episode["decisions"]) == run["decisions"]
    assert all(decision["terminal"] for decision in episode["decisions"][-8:])
    for decision in episode["decisions"]:
        selected = next(
            attempt
            for attempt in decision["attempts"]
            if attempt["attempt_id"] == decision["selected_attempt_id"]
        )
        assert (
            selected["origin"] == "teacher"
            and selected["policy"] == manifest["target_policy"]
        )
        assert (
            selected["accepted"]
            and selected["parsed_action"] == decision["executed_action"]
        )
        label = labels.pop((run["episode_id"], decision["decision_id"]))
        assert label["prompt"] == selected["prompt"]
        assert (
            json.loads(label["completion"][0]["content"]) == decision["executed_action"]
        )
        observation = decision["observation"]
        assert (
            observation["tick_after"] - observation["tick_before"]
            == observation["macro_ticks"]
        )
assert not labels
assert stat.S_IMODE((root / "manifest.json").stat().st_mode) == 0o600
print(
    "Private complete episodes and exact teacher projections passed:",
    manifest["variant"],
    len(manifest["runs"]),
)
