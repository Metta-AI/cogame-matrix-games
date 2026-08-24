# Matrix Games — wire protocols

## `matrix.player.v1` (WS `/player?slot=N&token=T`)

JSON text frames.

**player -> game**, immediately on connect and again after `welcome` (the
re-send guards the slot-registration race):

```json
{"type":"prompt","prompt":"<= 4000 chars",
 "scripted":"counter|tit-for-tat|fixed-pick|always-first|always-second|",
 "policy":"<display label>"}
```

Any other frame is ignored with a log line.

**game -> player**:

```json
{"type":"welcome","protocol":"matrix.player.v1","slot":4,"name":"Elm",
 "camp":"column","variant":"prisoners-dilemma","beats":12,"ticksPerBeat":50}
```

then, at every beat boundary and once at episode end, the seat's whole
observation (`"type":"state"`): the board, the full matrix and both
best-response tables, every constant, your own position / facing / inventory /
mix / score / cooldowns, every zone rectangle with its LIVE token count, the
tokens inside your view, every other cog's alias / camp / cumulative score /
interaction count (plus its position and inventory when it is within
`viewRadius` with clear line of sight, or its last known cell and
`seenTicksAgo` when it is not), the complete public log of every resolution in
the episode, the room indices, your own notes, and the enumerated legal token
and target lists.

Hidden from a seat: every other seat's intent, notes, `say`, prompt and policy
name; the RNG seed; the positions and inventories of cogs outside its view;
anything about accounts, players or the league. **There is no inter-seat
channel** — `say` is spectator-only.

Finally:

```json
{"type":"final","done":true,"slot":4,"scores":[…8 floats…],
 "names":[…8 aliases…],"beats":12,"reason":"complete","ending":"full_match"}
```

after which the player exits 0.

### The reply schema

```json
{"intent":"hunt","target":"Ash","token":"defect",
 "say":"Ash is loaded with cooperate - take him",
 "notes":"Fern defected on me twice"}
```

| field | domain | on violation |
|---|---|---|
| `intent` | one of `gather`, `deny`, `hunt`, `avoid`, `hold` | invalid reply |
| `token` | a token name of this variant (case-insensitive; an integer index is also accepted) | required for `gather`/`deny`; absent or unknown is an invalid reply |
| `target` | an alias of another ELIGIBLE cog (cross-camp only in `bach-or-stravinsky`) | required for `hunt`/`avoid`; absent, unknown, self or ineligible is an invalid reply |
| `say` | 64 characters | truncated on RUNE boundaries |
| `notes` | 400 characters | truncated on RUNE boundaries |

Extra keys are ignored and trailing prose after the closing brace is
tolerated. An invalid reply is retried ONCE with an explicit hint; still
invalid, that seat plays the `counter` scripted intent for the beat and the
`order` event records `"source":"fallback"`.

## `matrix.global.v1` (WS `/global`)

One JSON snapshot per beat boundary and at the end: paintbot's chrome key set
(`t, mt, ph, pl, sp, mx, st, lp, sk, ff, en, mm, bs, teams, roster, events,
lead, beats, lulls, over, hold`) plus a `seats` array carrying every cog's
slot, alias, POLICY name, livery, camp, position, inventory, mix, score,
interaction count and last intent. `teams` carries the K token-type keys
(`red`, `blue`, `green`), each `{share, tokensLeft, cells}`.

## The static replay bundle

The manifest declares `"replay_viewer": {"bundle": "static-replay-viewer"}`.
The bundle is opened as `index.html?replay=<url of the .replay file>`; it
fetches those bytes, hands them to the wasm module, and plays back RECORDED
STATE — there is no re-simulation, so a seek is an array index. No server is
contacted except S3 for the replay file.

The shell sets `data-replay-loaded="true"` on `<html>` on its first drawn
frame and `data-replay-error="<message>"` on failure, and posts the
`coworld-replay` bridge's `ready` message from the callback that fires AFTER
`data-replay-loaded` is set.
