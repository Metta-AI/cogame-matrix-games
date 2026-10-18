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

## Episode wording

`promptVariant` selects one of five training introductions: `canonical`, `plain`,
`numbered`, `questions`, or `reordered`. `mixed` resolves a nonnegative explicit
`promptSeed` modulo five once per episode without consuming simulation randomness.
The `matrix-games-rules-v1` bank retains the original canonical prompt bytes.
Shared payoff tables, private observations, intent rules, and reply schemas stay fixed.
`heldout-briefing` and `heldout-reference` are evaluation-only; training bridge resets
and source exports reject them. Private metadata hashes the rendered messages.
External policies receive the selected prompt configuration with each observation.

## Complete teacher corpus

Commit the qualified source, sync `nimby.lock`, then export every variant:

```sh
nim c -d:release --path:src --out:/tmp/matrix-export tools/export_posttrain.nim
nim c -d:release --path:src --out:/tmp/matrix-check-episode tools/check_episode.nim
for variant in running-with-scissors prisoners-dilemma chicken stag-hunt \
  bach-or-stravinsky pure-coordination rationalizable-coordination; do
  /tmp/matrix-export "/tmp/matrix-${variant}" 10 1 "$variant"
  python3 tools/test_training_corpus.py "/tmp/matrix-${variant}" /tmp/matrix-check-episode
done
```

Each output contains complete private event trajectories, per-episode replays,
aggregate `trajectories.jsonl`, and a review-required manifest. No training or
validation labels are assigned. Every seat uses its ordinary hosted prompt and
parser. Actual installed orders and private observations reconstruct every public
replay frame, event, and outcome through the production simulator. Fresh directories
are required; mode 0700 directories and 0600 files protect prompts and responses.

Append a wording and independent prompt seed to select a training introduction:
`/tmp/matrix-export /tmp/matrix-plain 10 1 chicken plain 0`. All payoff variants and
wording replicas retain the same `matrix-games-SEED` family. The shared typed
importer and independent review determine admission and family-level splits.
Unreviewed candidates cannot become training labels. Scripted evidence does not
establish model quality or hosted sampling parity.

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
