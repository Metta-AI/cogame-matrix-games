# The `/global` spectator stream and the static replay bundle

## `WS /global` — `matrix.global.v1`

One JSON snapshot per beat boundary and one at the end. The key set is
paintbot's chrome frame verbatim — `t, mt, ph, pl, sp, mx, st, lp, sk, ff,
en, mm, bs, teams, roster, events, lead, beats, lulls, over, hold` — so the
shared `client/chrome_common.js` runs unmodified over the stream, plus:

- `seats`: eight objects, one per slot, carrying `s`, `alias`, the real
  POLICY `name`, `livery`, `color`, `camp`, `x`, `y`, `facing`, `inv`, `mix`
  (permille), `scoreCp`, `interactions`, `frozen`, `intent`, `say`, `source`
  and `connected`. Real policy names appear HERE and never in a seat's own
  observation.
- `teams`: the K token-type keys (`red`, `blue`, and `green` when K = 3), each
  `{share, tokensLeft, cells}`. Those are names `chrome_common`'s
  `TEAM_ORDER` / `teamCol` already know, so the momentum legend gets its
  colours free.
- `lead`: `{"teams": [...token keys...], "pts": [[t, share0, ...], ...]}` —
  the convention-share time series, shipped WHOLE on the first frame so the
  momentum curve draws its full width immediately.
- `beats`: the whole scrubber timeline, also shipped on the first frame. Four
  kinds and only four: `interact`, `bigpay` (either side cleared 4.00),
  `leadchange`, and one `over` row at the final tick.
- `lulls`: `[[from, to], ...]` for every stretch of >= 60 ticks with no
  resolution, so the auto-skip button has something real to skip.
- `indices`: `{interactions, coopRate, conventionCounts}`.

## The static replay bundle

The manifest declares `"replay_viewer": {"bundle": "static-replay-viewer"}`.
There is no `/client/replay` pod viewer in the manifest; the platform serves
the bundle from
`/v2/coworlds/replays/static/<cow_id>/<sha>/index.html?replay=<s3 url>`.

The bundle fetches the `.replay` bytes, hands them to a wasm module compiled
from the SAME Nim sources as the game, and plays back RECORDED STATE — matrix
games records state, not inputs, so playback never re-simulates, a seek is an
array index, and there is no native/wasm divergence to chase.

The shell sets `data-replay-loaded="true"` on `<html>` on its first drawn
frame and `data-replay-error="<message>"` on failure, and posts the
`coworld-replay` bridge's `ready` message from the callback that fires after
`data-replay-loaded` is set.

Everything the viewer needs is in the replay bytes: aliases, policy names,
liveries, camps, the variant, the whole config including both payoff matrices,
the seed, the map, the spawner layout, per-tick state, the index summary,
every event and the full `results` object. No server is contacted except S3.
