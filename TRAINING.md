# Metta post-training data

The native simulator and published `counter` policy export supervised examples
for all seven certified Matrix Games variants:

```sh
nimby sync nimby.lock
for variant in running-with-scissors prisoners-dilemma chicken stag-hunt \
  bach-or-stravinsky pure-coordination rationalizable-coordination; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/matrix-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
episodes. At each simultaneous decision boundary, the exporter freezes all
eight seat observations. It records each seat's hosted system and user prompts,
then parses a `counter` move through the game's reply parser. Parsed moves
drive the simulator. Whole episodes stay in one split. The manifest records
source revision, variant, scores, tick count, and row counts. Existing output
directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/matrix-running-with-scissors \
  --output /tmp/matrix-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete episodes per variant yielded 6,720 examples. Every example fit
the Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum was 2,672.
One CPU optimizer step per variant with a local tiny model verifies the Metta
post-training path. These examples distill the scripted teacher; they do not
establish stronger league play.

For reinforcement learning, compile the persistent bridge and test all seven
certified variants:

```sh
nim c -d:release --path:src -o:matrix-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py ./matrix-train-bridge
```

From Metta, use `recipes.external.coworld.train` for native PufferLib or
`recipes.external.coworld_metta_rl.train` for Metta RL. Pass a command with
absolute bridge and manifest paths, the variant ID, `players=8`, and a
timestep limit. The bridge exposes 140 player-visible numeric values and a
fixed 21-choice catalog. It masks choices outside each variant's token and
target lists. The published `counter` policy supplies opponents and optional
teacher labels. Metta support is stacked in #24679 above #24573.
