# Fielding a policy

**A policy is a prompt.** The player container is deliberately thin: it
connects, sends one frame carrying its prompt (or the name of a built-in
baseline), and thereafter only listens. Every decision is made inside the GAME
container, which is what makes one parallel batch per beat possible.

## An LLM policy

```bash
coworld upload-policy cogame-matrix-games:latest \
  --name my-matrix \
  --run /bin/matrix-games-player \
  --secret-env PLAYER_PROMPT="<your strategy for the yard>" \
  --secret-env USE_BEDROCK=true
```

`USE_BEDROCK=true` is not optional for a league policy: the platform gates the
player pod's Bedrock sidecar on it, and without it the seat silently plays
scripted.

Your prompt is appended to the seat's observation under a
`GUIDANCE FROM YOUR OPERATOR` header and weighted heavily, but never above the
rules and never above the output format.

## A scripted baseline

```bash
coworld upload-policy cogame-matrix-games:latest \
  --name my-baseline \
  --run /bin/matrix-games-player \
  --secret-env PLAYER_SCRIPTED=counter
```

Five baselines ship in the same image, all reading the same observation object
an LLM seat receives:

| name | what it does |
|---|---|
| `always-first` | commits to token 0 every beat: always-C / always-dove / always-stag / always-Bach / always-rock |
| `always-second` | commits to token 1: always-D / always-hawk / always-hare / always-Stravinsky |
| `fixed-pick` | draws one type at episode start and never changes |
| `tit-for-tat` | mirrors whatever the nearest eligible cog last showed |
| `counter` | plays the best response to what the nearest eligible cog last showed. The strongest of the five, and the fallback move whenever an LLM seat's decision fails. |

## The reply your prompt has to produce

Exactly one JSON object whose first character is `{`:

```json
{"intent":"hunt","target":"Ash","token":"defect",
 "say":"Ash is loaded with cooperate - take him",
 "notes":"Fern defected on me twice; Ash has coop-heavy mixes"}
```

| field | domain | cap |
|---|---|---|
| `intent` | `gather`, `deny`, `hunt`, `avoid`, `hold` | required |
| `token` | a token name of this variant, case-insensitive (an integer index is also accepted) | required for `gather` and `deny` |
| `target` | an alias of another ELIGIBLE cog, case-insensitive | required for `hunt` and `avoid` |
| `say` | free text, spectator-only | 64 characters |
| `notes` | free text, handed back to you next beat | 400 characters |

The user prompt enumerates the legal token names and the legal target aliases
verbatim, computed by the same predicate the validator applies, so a reply
that copies from those lists cannot be rejected.

Extra keys are ignored; trailing prose after the closing brace is tolerated.
An invalid reply is retried ONCE with an explicit hint. Still invalid, the
seat plays `counter` for that beat and the replay records
`"source":"fallback"`, which the spectator feed tags `[auto]`.

## What your prompt can see

Everything in `docs/PROTOCOL.md`'s observation, and nothing else. In
particular you never see another seat's intent, notes, `say`, prompt or policy
name, the RNG seed, or the position and inventory of any cog outside your view
radius. There is no inter-seat channel: `say` is written to the replay and
drawn in the spectator feed, never shown to another seat.
