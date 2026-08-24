# cogame-matrix-games

**Eight cogs, a yard full of tokens, and one payoff matrix that changes
everything.**

Matrix Games is a merged port of Melting Pot's `*_in_the_matrix` family. Eight
cogs roam one 24 x 14 walled yard collecting K token types. Your **inventory
mix IS your strategy** — not a declaration, not a button press: the fraction of
your inventory that is `defect` is the probability weight you are playing on
`defect`. Fire the interaction beam at another cog and the two mixes are
multiplied through the variant's payoff matrix; both of you are paid, both of
you reset to one token of each type, and both of you freeze for half a second.

Commitment is therefore expensive, visible and perishable. A cog within seven
cells with clear line of sight can read your whole inventory before it decides
whether to close, so a feint — buying tokens you do not intend to spend — is a
real move. Camping a zone to starve a rival shows up as a public counter
falling. And because a resolution resets you, the cog that just won a fight is
the cheapest target in the yard.

Seven variants share the engine and differ only in the matrix: **running with
scissors** (cyclic zero-sum), **prisoners' dilemma**, **chicken**, **stag
hunt**, **Bach or Stravinsky** (asymmetric camps, cross-camp interactions
only), **pure coordination** and **rationalizable coordination**.

Seats decide once per 50-tick beat; a deterministic kernel executes that
intent — gather, deny, hunt, avoid, hold — tick by tick. All eight seats'
decisions go out as ONE parallel batch per beat.

**A policy is just a prompt** — see [docs/POLICIES.md](docs/POLICIES.md).

## Layout

- `src/matrix_games.nim` — entrypoint. Seed randomisation happens HERE, before
  the pinned seed is honoured, so every seed-derived draw follows the final
  seed.
- `src/matrix_games_player.nim` — the thin prompt-carrying player. It never
  decides anything.
- `src/matrix_games/` — `sim_types.nim` (constants, wire types, the two text
  helpers), `matrices.nim` (the seven matrices), `arena_map.nim` (the ASCII
  yard), `sim_config.nim`, `sim_state.nim` (the `Sim` object, the seeded
  spawner draw, the digest), `kernel.nim` (the five intents' per-tick kernel
  and the BFS), `indices.nim`, `scripted.nim` (the five baselines), `sim.nim`
  (the ten numbered tick rules and the seat observation), `events.nim`,
  `llm.nim` (the batched decision layer), `broadcast.nim` (the chrome frame),
  `global.nim` (the viewer packet), `map_art.nim`, `replays.nim`,
  `server.nim`.
- `client/` — `chrome_common.js` copied BYTE-FOR-BYTE from `coworld-ctf`,
  `broadcast_core.js` (the board renderer), and `replay_broadcast.html`: the
  inherited paintbot chrome with the matrix-games game block appended under a
  banner comment.
- `replay-viewer/` — the static wasm bundle: `config.nims`,
  `matrix_games_replay.nim`, `static_replay.js`, `static_replay_worker.js`.
- `tests/` — every file is a standalone program; `tests/support/` holds the
  shared helpers so the `tests/*.nim` glob never runs one.

## Generated files

Three things are generated and must be regenerated rather than edited:

```bash
python3 scripts/art/split_cog_sheet.py data/cog   # nano-banana cog poses
python3 scripts/art/gen_matrix_art.py             # liveries, tokens, floor, FX
python3 scripts/gen_manifest.py                   # coworld_manifest_template.json
```

The manifest INLINES `README.md`, `docs/RULES.md`, `docs/MATRICES.md`,
`docs/POLICIES.md`, `docs/PROTOCOL.md` and `docs/GLOBAL.md`, so editing a doc
without re-running the generator leaves the coworld page stale.

## Two name spaces

A seat sees only the eight aliases `Ash Birch Cedar Dune Elm Fern Gorse
Holly`. Real policy names live in the replay's `policyNames[]`, the scorebug
plates, the endcard, `results.names[]` and the `/global` snapshot — nowhere a
seat can read them.

## Rune boundaries

Every string that can reach the replay or the results goes through
`sim_types.cleanText`. Never slice one of those by byte index: a
byte-truncated multi-byte character renders in a browser and then fails a
strict JSON parser, which is how a hosted replay becomes unreadable.

## CI is the harness

`ci.yml` runs every `tests/*.nim` twice (debug and `-d:release`), builds the
production image and runs one real 8-seat episode in raw docker from the
certification fixture, then builds the static replay bundle and OPENS it in
headless chromium against that episode's replay.
`tools/build_replay_viewer.sh` and `tools/ci/docker_smoke.sh` must stay mode
100755 — `coworld build` refuses to package a source replay-viewer bundle
unless the hook is `os.X_OK`.
