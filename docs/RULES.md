# Matrix Games — rules

## The yard

One fixed arena, 24 cells wide by 14 tall, rendered at 40 px per cell (a
960 x 560 board). It is the same map in every variant, mirror-symmetric
left-right and top-bottom, fully connected, with 216 free cells. `#` is wall,
`.` is floor:

```
########################
#....##..........##....#
#..........##..........#
#.##....#......#....##.#
#.##................##.#
#......##......##......#
#..##..............##..#
#..##..............##..#
#......##......##......#
#.##................##.#
#.##....#......#....##.#
#..........##..........#
#....##..........##....#
########################
```

Eight cogs play, always: `Ash Birch Cedar Dune Elm Fern Gorse Holly`, one per
slot, each in a fixed livery. In `bach-or-stravinsky` slots 0-3 are the row
(blue) camp and slots 4-7 the column (orange) camp; in every other variant
every cog is eligible against every other.

One episode is 12 beats of 50 ticks = 600 ticks. Playback is 24 fps, so a full
replay is 25 seconds of video.

## Tokens

The variant fixes `K` (2 or 3) and the token names. Spawners are fixed cells
that hold at most one token, drawn once at episode start from the seeded RNG:
16 in zone A (type 0, top left), 16 in zone B (type 1, top right), 16 in zone
C (type 2, centre bottom, K = 3 only), and a 12-spawner mixed scatter across
the centre band whose n-th spawner carries type `n mod K`.

Stepping onto a spawner that holds a token collects it unless that type is
already at `tokenCap = 8`. A collected spawner refills 45 ticks later. Zone
token counts are public, so camping a zone to starve a rival is visible to
everyone as a falling counter.

Every cog starts, and after every resolution resets to, the ENDOWMENT: one
token of each type. Maximum purity is 8/9 (K = 2) or 8/10 (K = 3):
commitment is expensive and never total.

**Inventory mix IS strategy.** A cog's strategy at the moment of an
interaction is the rational vector `x_i = n_i / N`.

## One intent per beat

At each beat boundary every seat submits ONE intent, which a deterministic
per-tick kernel then executes for the next 50 ticks.

| intent | argument | what the kernel does |
|---|---|---|
| `gather` | `token` | path to the nearest cell holding a token of that type and collect it; at the cap, hold at the type's zone centre. Never fires. |
| `deny` | `token` | take the token of that type nearest to the nearest other cog. Never fires. |
| `hunt` | `target` | path toward that cog's last known cell; fire the first tick it is in the ray and the beam is ready. |
| `avoid` | `target` | move away and never enter a cell within 2 of it. Never fires. |
| `hold` | — | stand still, re-face the nearest cog within 6 cells every 4 ticks, fire when one is in the ray. |

Pathing is a breadth-first search over free cells with ties broken in the
direction order N, E, S, W. A cog with no legal step waits.

## The ten numbered tick rules

1. **Timers.** `freeze`, `stepCd`, `beamCd` and `immune` each tick down to 0.
2. **Token respawn.** Every spawner whose `refillAt == t` gets its token back.
3. **Intent evaluation.** Each unfrozen cog produces one micro-action:
   `step(dir)`, `turn(dir)`, `fire` or `wait`. Frozen cogs produce `wait`.
4. **Movement**, seats in ascending slot order. A cog with `stepCd == 0` moves
   one cell if it is floor and currently unoccupied, sets its facing and takes
   `stepCooldownTicks = 3`. `turn(dir)` costs nothing.
5. **Pickup**, ascending slot order.
6. **Beam fire**, ascending slot order. Range 4 cells along the facing,
   stopped by the first wall; the first cog in the ray is the target. No
   target, or a frozen / immune target, or (in `bach-or-stravinsky`) a
   same-camp target, is a miss or a no-contest and costs
   `beamMissCooldown = 6`.
7. **Resolution.** The row player is the shooter, except in
   `bach-or-stravinsky` where it is the row-camp participant regardless of who
   fired. With the row inventory `n` (`N = sum n`) and the column inventory `m`
   (`M = sum m`):

   ```
   rowPayCp = ( sum_i sum_j  n_i * rowPay[i][j] * m_j * 100 ) div (N * M)
   colPayCp = ( sum_i sum_j  n_i * colPay[i][j] * m_j * 100 ) div (N * M)
   ```

   `div` truncates toward zero. Payoffs are in centipoints. The cell the
   viewer pops is `(argmax n, argmax m)`, ties to the lowest index.
8. **Reset.** Both participants reset to the endowment, `freeze = 12`,
   `immune = 12`, `beamCd = beamResetCooldown = 25`.
9. **Indices.** The convention histogram, the cooperation accumulator, the
   per-seat exploitability accumulators and the leader check.
10. **Record.** One state frame, its events and two series rows.

## Scoring

`scores[i]` is the sum of the payoffs seat `i` collected, in points. **Higher
is better.** In `running-with-scissors` the scores are zero-sum and negatives
are normal. A cog that never resolves an interaction scores exactly 0: there
is no participation bonus and no penalty for hiding.

The episode ends at the first of: 12 beats played (`complete` / `full_match`);
the play deadline, 60 % of `episodeTimeoutSeconds`, crossed between beats
(`deadline`); or no seat socket connected within 180 s (`forfeit`). Those
three are the only legal `results.reason` values.
