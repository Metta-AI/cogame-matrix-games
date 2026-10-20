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

`promptVariant` selects one of five training presentations: `canonical`, `plain`,
`numbered`, `questions`, or `reordered`. `mixed` resolves a nonnegative explicit
`promptSeed` modulo five once per episode without consuming simulation randomness.
The `matrix-games-rules-v3` bank retains the original canonical prompt bytes.
Complete yard, timing, beam, inventory-payoff, and scoring explanations vary in
wording and order. Payoff tables, private observations, intent semantics, and reply
schemas stay fixed.
`heldout-briefing` and `heldout-reference` are evaluation-only; training bridge resets
and source exports reject them. Private metadata hashes the rendered messages.
External policies receive the selected prompt configuration with each observation.

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

Each output retains the original complete private episodes, train/validation JSONL,
and manifest. Teacher labels correspond to accepted engine-applied actions. Private
files have mode 0600 and directories 0700. Existing outputs are refused, and exports
require clean committed source so revision pins identify the code.

Append a wording and independent prompt seed, for example:
`/tmp/matrix-export /tmp/matrix-mixed 10 1 chicken mixed 0`.
Mixed exports cycle separately within training and validation; every fifth scenario
is validation. All payoff variants retain the `matrix-games-SEED` family. Check actual
training rows for all five presentations before training. Corpora still require
content review. Scripted checks do not establish learned robustness or hosted sampling parity.

Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for the maintained SLIME training and adapter-packaging workflows after dataset review.

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
including private notes and spectator-only speech. Every reply passes through the
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

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test`
split. Omitted, training, and unrecognized splits reject them.

Native trajectories and training rows share an episode ID containing requested selection,
resolved wording, and prompt seed. Matched wording collections have distinct IDs while
their gameplay seed families remain unchanged.

Version three independently phrases numbered, question-led, reordered, and held-out
explanations. Numeric facts, the payoff matrix, intent definitions, and output contract
remain fixed. Canonical/plain text is unchanged.
