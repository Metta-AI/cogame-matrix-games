#!/usr/bin/env python3
"""Generate `coworld_manifest_template.json`.

Run from the repository root after editing README.md, docs/RULES.md or
docs/PROTOCOL.md -- the manifest INLINES them, so editing a doc without
re-running this leaves the coworld page stale:

    python3 scripts/gen_manifest.py

The image placeholder is derived from `compose.yaml`'s service name, which is
what `coworld build` does (service `game` -> `{{GAME_IMAGE}}`); hard-coding
one is the lantern failure.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SLUG = "matrix-games"
SEATS = 8

ALIASES = ["Ash", "Birch", "Cedar", "Dune", "Elm", "Fern", "Gorse", "Holly"]

VARIANTS = [
    ("running-with-scissors", "Cyclic zero-sum: no fixed policy survives."),
    ("prisoners-dilemma", "Conditional cooperation with strangers."),
    ("chicken", "Anti-coordination: who yields, with no words."),
    ("stag-hunt", "Assurance: risk- versus payoff-dominant equilibria."),
    ("bach-or-stravinsky", "Asymmetric camps; interactions only cross-camp."),
    ("pure-coordination", "Three matches, all paying 1."),
    ("rationalizable-coordination", "Three matches, paying 1 / 2 / 3."),
]

PLAYERS = [
    ("matrix-games-player", {},
     "The reference matrix-games policy: a prompt seat. Supply PLAYER_PROMPT"
     " at upload time to field your own strategy."),
    ("matrix-games-counter", {"PLAYER_SCRIPTED": "counter"},
     "Plays the best response to whatever the nearest eligible cog last"
     " showed. The strongest of the five baselines."),
    ("matrix-games-tit-for-tat", {"PLAYER_SCRIPTED": "tit-for-tat"},
     "Mirrors whatever the nearest eligible cog last showed."),
    ("matrix-games-fixed-pick", {"PLAYER_SCRIPTED": "fixed-pick"},
     "Draws one token type at episode start and commits to it forever."),
    ("matrix-games-always-first", {"PLAYER_SCRIPTED": "always-first"},
     "Always the first token: always-C, always-dove, always-stag,"
     " always-Bach, always-rock."),
    ("matrix-games-always-second", {"PLAYER_SCRIPTED": "always-second"},
     "Always the second token: always-D, always-hawk, always-hare,"
     " always-Stravinsky."),
]


def compose_placeholder() -> str:
    """`coworld build` derives the placeholder from the compose SERVICE name."""
    text = (ROOT / "compose.yaml").read_text()
    services = text.split("services:", 1)[1]
    for line in services.splitlines():
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            return "{{" + match.group(1).upper() + "_IMAGE}}"
    raise SystemExit("no compose service found")


def read(path: str) -> str:
    return (ROOT / path).read_text().strip()


def seat_players() -> list[dict]:
    return [{"name": alias} for alias in ALIASES]


def config_schema() -> dict:
    def integer(desc, minimum, maximum, default):
        return {"description": desc, "type": "integer", "minimum": minimum,
                "maximum": maximum, "default": default}

    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "required": ["tokens", "players"],
        "properties": {
            "tokens": {
                "description":
                    "One connection token per player slot, indexed by slot.",
                "type": "array", "minItems": 1, "maxItems": SEATS,
                "items": {"type": "string", "minLength": 1},
            },
            "players": {
                "description":
                    "One player display-name object per seat, indexed by slot.",
                "type": "array", "minItems": 1, "maxItems": SEATS,
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["name"],
                    "properties": {"name": {"type": "string", "minLength": 1}},
                },
            },
            "num_agents": integer(
                "Seat count; injected by the commissioner. Matrix Games is an"
                " eight-cog game, in every variant.", SEATS, SEATS, SEATS),
            "seed": {
                "description":
                    "Pins the spawner layout and the fixed-pick draw. Omit for"
                    " a fresh random seed per episode.",
                "type": "integer",
            },
            "matrix": {
                "description":
                    "Which of the seven payoff matrices this episode plays."
                    " The matrix fixes K, the token names and both payoff"
                    " tables.",
                "type": "string",
                "enum": [name for name, _ in VARIANTS],
                "default": "running-with-scissors",
            },
            "beats": integer("Decision beats in the episode.", 1, 24, 12),
            "ticksPerBeat": integer(
                "Ticks per beat at 24 ticks per second.", 10, 120, 50),
            "tokenCap": integer(
                "Most tokens of one type a cog can hold.", 2, 16, 8),
            "tokenRespawnTicks": integer(
                "Ticks before a collected spawner refills.", 5, 200, 45),
            "beamRange": integer(
                "Interaction beam reach, in cells.", 1, 8, 4),
            "freezeTicks": integer(
                "Ticks a cog is frozen after a resolution.", 0, 60, 12),
            "stepCooldownTicks": integer(
                "Ticks between steps.", 1, 10, 3),
            "beamResetCooldown": integer(
                "Beam cooldown after a resolution.", 0, 120, 25),
            "beamMissCooldown": integer(
                "Beam cooldown after a miss or a no-contest.", 0, 60, 6),
            "viewRadius": integer(
                "How far a cog can read another cog's inventory, in cells,"
                " with clear line of sight.", 1, 24, 7),
            "llmTimeoutSeconds": integer(
                "Deadline for one parallel decision batch.", 1, 120, 20),
            "minBeatSeconds": integer(
                "Wall-clock floor between decision batches. The Bedrock"
                " sidecar caps 30 requests per minute per episode and eight"
                " seats per batch makes this the binding constraint.",
                0, 120, 17),
            "maxOutputTokens": integer(
                "Model output cap. 400 truncates mid-JSON.", 64, 2000, 900),
            "model": {
                "description": "Claude model that drives every LLM seat.",
                "type": "string", "default": "claude-haiku-4-5",
            },
            "episodeTimeoutSeconds": integer(
                "Wall clock the game assumes the platform allows when"
                " COWORLD_TIMEOUT_SECONDS is not in its environment. Play"
                " settles inside 60 % of it.", 60, 6000, 1200),
            "playerConnectTimeoutSeconds": integer(
                "Bounded wait for the eight player containers to connect.",
                0, 600, 180),
            "shutdownGraceSeconds": integer(
                "How long /healthz and /global keep answering after the"
                " artifacts are written. Hosted certification pings the global"
                " websocket AFTER the player pods start.", 0, 120, 20),
        },
    }


def results_schema() -> dict:
    def arr(items, desc):
        return {"type": "array", "minItems": SEATS, "maxItems": SEATS,
                "items": items, "description": desc}

    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "required": ["names", "scores", "win", "aliases", "reason"],
        "properties": {
            "names": arr({"type": "string"},
                         "POLICY display names by slot. Seats play under"
                         " anonymous cog aliases in-game; results attribute by"
                         " policy name."),
            "scores": arr({"type": "number"},
                          "Total payoff collected, in points. HIGHER IS"
                          " BETTER. Negative scores are normal and expected in"
                          " running-with-scissors, which is zero-sum."),
            "win": arr({"type": "boolean"}, "scores[i] == max(scores)."),
            "aliases": arr({"type": "string"}, "Ash..Holly, by slot."),
            "camps": arr({"type": "string"},
                         "row / column in bach-or-stravinsky, none elsewhere."),
            "variant": {"type": "string",
                        "enum": [name for name, _ in VARIANTS]},
            "interactions": {"type": "integer", "minimum": 0},
            "perSeatInteractions": arr({"type": "integer", "minimum": 0},
                                       "Resolutions each seat took part in."),
            "meanPayoff": arr({"type": "number"},
                              "scores[i] / perSeatInteractions[i], or 0.0."),
            "exploitability": arr(
                {"type": ["number", "null"]},
                "Points left on the table against the mean opponent mix."
                " null for a seat with zero resolutions."),
            "coopRate": {
                "type": ["number", "null"], "minimum": 0, "maximum": 1,
                "description":
                    "Share of the inventory mass carried into resolutions that"
                    " was the coop token. null for the four variants that"
                    " declare no coop token.",
            },
            "conventionCounts": {
                "type": "array", "minItems": 2, "maxItems": 3,
                "description":
                    "conventionCounts[i][j] = resolutions that hit cell (i,j).",
                "items": {"type": "array", "minItems": 2, "maxItems": 3,
                          "items": {"type": "integer", "minimum": 0}},
            },
            "tokens": {"type": "array", "minItems": 2, "maxItems": 3,
                       "items": {"type": "string"},
                       "description": "This variant's token names."},
            "beats": {"type": "integer", "minimum": 0},
            "ticks": {"type": "integer", "minimum": 0},
            "reason": {"type": "string",
                       "enum": ["complete", "deadline", "forfeit"]},
            "ending": {"type": "string",
                       "enum": ["full_match", "deadline", "forfeit"]},
        },
    }


def docs() -> dict:
    return {
        "readme": {"type": "text", "value": read("README.md")},
        "pages": [
            {"id": "rules.md", "title": "Rules",
             "content": {"type": "text", "value": read("docs/RULES.md")}},
            {"id": "matrices.md", "title": "The seven matrices",
             "content": {"type": "text", "value": read("docs/MATRICES.md")}},
            {"id": "policies.md", "title": "Fielding a policy",
             "content": {"type": "text", "value": read("docs/POLICIES.md")}},
        ],
    }


def main() -> int:
    image = compose_placeholder()
    variants = []
    for name, description in VARIANTS:
        variants.append({
            "id": name,
            "name": name.replace("-", " ").title(),
            "description": description,
            "game_config": {
                "num_agents": SEATS,
                "matrix": name,
                "beats": 12,
                "ticksPerBeat": 50,
                "tokenCap": 8,
                "players": seat_players(),
            },
        })
    manifest = {
        "$schema":
            "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/"
            "coworld/coworld_manifest_schema.json",
        "tags": ["game-theory", "melting-pot", "multi-agent", "llm-driven",
                 "real-time", "eight-player"],
        "episode_timeout_minutes": 20,
        "game": {
            "name": SLUG,
            "owner": "daveey@softmax.com",
            "description":
                "Eight cogs, a yard full of tokens, and one payoff matrix that"
                " changes everything. A merged port of Melting Pot's"
                " *_in_the_matrix family: your inventory mix IS your strategy,"
                " and an interaction beam resolves it against whoever you hit.",
            # replay_compression: the platform stores the PUBLIC browser
            # copy of each replay as gzip bytes (no Content-Encoding, same
            # URL); the Worker sniffs the gzip magic and inflates before the
            # wasm loader.
            "replay_viewer": {"bundle": "static-replay-viewer",
                              "replay_compression": "gzip"},
            "runnable": {
                "type": "game",
                "image": image,
                "run": ["/bin/matrix-games"],
                "env": {
                    "ANTHROPIC_API_KEY_URI":
                        f"secret://coworld/{SLUG}/anthropic_api_key",
                },
                "source_url":
                    "https://github.com/Metta-AI/cogame-matrix-games/tree/main",
            },
            "config_schema": config_schema(),
            "results_schema": results_schema(),
            "docs": docs(),
            "protocols": {
                "player": {"type": "text", "value": read("docs/PROTOCOL.md")},
                "global": {"type": "text", "value": read("docs/GLOBAL.md")},
            },
        },
        "player": [
            {
                "id": name,
                "type": "player",
                "name": name,
                "description": description,
                "image": image,
                "run": ["/bin/matrix-games-player"],
                **({"env": env} if env else {}),
            }
            for name, env, description in PLAYERS
        ],
        "variants": variants,
        "certification": {
            "game_config": {
                "num_agents": SEATS,
                "seed": 7,
                "matrix": "prisoners-dilemma",
                "beats": 6,
                "ticksPerBeat": 50,
                "playerConnectTimeoutSeconds": 180,
                "players": seat_players(),
            },
            # Every declared player[] id is seated at least once: `players-run`
            # seats the whole roster and a `baseline x N` fixture fails
            # `players_missing` (the raid learning).
            "players": [
                {"player_id": "matrix-games-player"},
                {"player_id": "matrix-games-counter"},
                {"player_id": "matrix-games-tit-for-tat"},
                {"player_id": "matrix-games-fixed-pick"},
                {"player_id": "matrix-games-always-first"},
                {"player_id": "matrix-games-always-second"},
                {"player_id": "matrix-games-counter"},
                {"player_id": "matrix-games-tit-for-tat"},
            ],
        },
    }
    out = ROOT / "coworld_manifest_template.json"
    out.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
