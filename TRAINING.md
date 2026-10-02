# Private Matrix Games language training

The ordinary hosted game builds each seat's private observation, sends its native
Messages request, parses the reply, installs all eight orders, and executes a
full beat. Training evidence records that same boundary: exact prompts and
attempts, actual served model and decoder, platform call IDs, installed orders,
macro duration, terminal outcomes, and immutable source revision. Retries and
consumed fallbacks remain in the private episode. Fallbacks are excluded from
model learning targets.

Hosted capture requires `COGAME_SAVE_TRAJECTORY_URI`, `COWORLD_EPISODE_ID`,
`COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`. Never publish these private
artifacts as replays. Public snapshots and newly written replay events redact
private notes and pending order intent/token/target; stored readers remain intact.

## Complete teacher corpus

Commit the qualified source, sync `nimby.lock`, then export every variant:

```sh
nim c -d:release --path:src --out:/tmp/matrix-export tools/export_posttrain.nim
for variant in running-with-scissors prisoners-dilemma chicken stag-hunt \
  bach-or-stravinsky pure-coordination rationalizable-coordination; do
  /tmp/matrix-export "/tmp/matrix-${variant}" 10 1 "$variant"
  python3 tools/test_training_corpus.py "/tmp/matrix-${variant}"
done
```

Each output contains one complete private episode per file, projected
`train.jsonl`/`validation.jsonl` labels, and a manifest selecting
`scripted-counter`. Every seat uses its ordinary hosted prompt and parser.
The installed order supplies the executed-action label. Whole episodes remain
in one split. Outputs require fresh directories; mode 0700 directories and
0600 files protect prompts and responses. Source revision, scores, ticks, and
macro durations are recorded. Scripted labels establish teacher imitation,
not trained checkpoint strength or reinforcement learning readiness.

The shared Metta qualifier validates these episodes with
`qualify_training_episodes(..., transport="local", target_policy="scripted-counter")`.
The shared hosted importer accepts complete-episode JSONL through
`metta-posttrain export-hosted SOURCE OUTPUT --policy scripted-counter`;
it retains all generation evidence while selecting teacher labels.

Ordinary supervised training uses Metta's maintained upstream SLIME integration.
From the Metta checkout, after dataset review:

```sh
uv run ./tools/run.py coworld_posttrain.train \
  dataset=/tmp/matrix-running-with-scissors model=MODEL_OR_PATH \
  revision=IMMUTABLE_MODEL_REVISION run=matrix-sft config.updates=64
```

Reload and verify the resulting artifact with the shared `SlimeRun` and owned
learner gateway. Save the player with a registered
`COWORLD_LLM_MODEL=checkpoint/<artifact-sha256>` and explicit
`COWORLD_LLM_TEMPERATURE`. The native game default is temperature 1; a frozen
greedy gateway requires an explicit value of 0. Accepted token budgets must
match the gateway's ceilings. The platform owns endpoint selection, route
credentials, artifact/tokenizer/template verification, and existing mutual TLS
egress. Players cannot select an arbitrary serving URL or claim another model.

## Language bridge and numeric research mode

```sh
nim c -d:release --path:src --out:/tmp/matrix-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/matrix-train-bridge
/tmp/matrix-train-bridge coworld_manifest_template.json running-with-scissors --language
```

`--language` exposes the exact hosted system/user prompts and counter completion,
including private notes and public speech. Every reply passes through the
production `extractJsonObject` and `parseOrder` before canonical execution.
The test plays all seven variants in both modes and verifies note continuity.

Without `--language`, the bridge exposes the separate numeric research interface:
140 visible values and a fixed 21-choice intent/token/target catalog. It projects
speech and memory out of that catalog. Numeric tests establish catalog validity;
they do not qualify semantic parity with hosted language players.

Online token reinforcement learning additionally requires actual sampled token
IDs and draw-time behavior log probabilities from the owned serving engine.
Greedy token IDs may be retained without probabilities. Never reconstruct token
IDs from replay text or fabricate likelihoods. Use shared SLIME `GameTask`
provenance, checkpoint reload verification, and matched base/trained evaluation
before claiming a trained player is ready for hosted inference.
