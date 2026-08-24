# The seven matrices

Every variant names two integer K x K matrices, `rowPay` and `colPay`. For
every symmetric variant `colPay = transpose(rowPay)`; only
`bach-or-stravinsky` differs. Each cell below is `row payoff / column payoff`.

## `running-with-scissors` (default) — K = 3, `rock, paper, scissors`

|        | rock | paper | scissors |
|---|---|---|---|
| **rock** | 0 / 0 | -3 / 3 | 3 / -3 |
| **paper** | 3 / -3 | 0 / 0 | -3 / 3 |
| **scissors** | -3 / 3 | 3 / -3 | 0 / 0 |

Cyclic and zero-sum, scaled x3 so one clean win pays the same 3 as mutual
cooperation in the prisoners' dilemma. No fixed policy survives: whatever you
commit to is visible in your inventory before the beam lands, so feints and
token denial are the game.

## `prisoners-dilemma` — K = 2, `cooperate, defect`

|        | cooperate | defect |
|---|---|---|
| **cooperate** | 3 / 3 | 0 / 5 |
| **defect** | 5 / 0 | 1 / 1 |

Conditional cooperation with strangers. Defect strictly dominates per
encounter; a room that manages to hold a cooperative convention out-earns a
room that does not.

## `chicken` — K = 2, `dove, hawk`

|        | dove | hawk |
|---|---|---|
| **dove** | 3 / 3 | 1 / 4 |
| **hawk** | 4 / 1 | 0 / 0 |

Anti-coordination: T = 4 > R = 3 > S = 1 > P = 0, and mutual hawk is the
crash, 0 / 0. Who yields — with no words, because there is no inter-seat
channel.

## `stag-hunt` — K = 2, `stag, hare`

|        | stag | hare |
|---|---|---|
| **stag** | 4 / 4 | 0 / 2 |
| **hare** | 2 / 0 | 2 / 2 |

Assurance. Stag/stag is payoff-dominant, hare is risk-dominant, and the whole
question is whether the room can trust the other cog to have bought stag.

## `bach-or-stravinsky` — K = 2, `bach, stravinsky`, ASYMMETRIC

|        | bach | stravinsky |
|---|---|---|
| **bach** | 3 / 2 | 0 / 0 |
| **stravinsky** | 0 / 0 | 2 / 3 |

The row (blue) camp — slots 0-3 — is paid 3 for Bach; the column (orange)
camp — slots 4-7 — is paid 3 for Stravinsky. Interactions only resolve
BETWEEN camps: a beam at your own camp is a no-contest.

## `pure-coordination` — K = 3, `red, green, blue`

The identity matrix: all three matches pay 1 / 1, everything else pays 0 / 0.
Common interest with no conflict at all — the only problem is agreeing.

## `rationalizable-coordination` — K = 3, `bronze, silver, gold`

The diagonal pays 1 / 1, 2 / 2 and 3 / 3; everything else pays 0 / 0. Same
coordination problem, but now one convention is strictly better than another,
so a room that settles on bronze has left money on the table.

## What is derived

Two best-response tables are computed once per variant and shipped in every
seat's observation, so a seat never has to work the counter out itself:

```
bestResponseRow[j] = argmax_i rowPay[i][j]
bestResponseCol[i] = argmax_j colPay[i][j]
```

Ties go to the lowest index.
