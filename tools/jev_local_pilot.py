"""Run matched local Matrix Games episodes with Jev and Claude.

Build ``matrix-jev:local``, then set TYPESAFE_API_KEY and ANTHROPIC_API_KEY
and run ``python3 tools/jev_local_pilot.py 7``. Artifacts stay in dist/.
Set MATRIX_VARIANT to exercise another matrix with the same player roster.
"""

import copy
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "coworld_manifest_template.json").read_text())
image = "matrix-jev:local"
seed = int(sys.argv[1])
arms = sys.argv[2:] or ("jev", "claude", "counter")
variant = os.environ.get("MATRIX_VARIANT", "prisoners-dilemma")


def docker(*args, env=None, timeout=300):
    return subprocess.run(
        ["docker", *args], check=True, capture_output=True, text=True,
        env=env, timeout=timeout,
    ).stdout.strip()


for arm in arms:
    name = f"local-{arm}-seed-{seed}"
    if variant != "prisoners-dilemma":
        name = f"local-{variant}-{arm}-seed-{seed}"
    out = root / "dist" / name
    out.mkdir(parents=True, exist_ok=True)
    config = copy.deepcopy(manifest["certification"]["game_config"])
    config.update(seed=seed, matrix=variant, beats=6, minBeatSeconds=1,
                  playerConnectTimeoutSeconds=20, shutdownGraceSeconds=0,
                  tokens=[f"token-{slot}" for slot in range(8)])
    (out / "config.json").write_text(json.dumps(config))
    prefix = "matrix-jev-" + uuid.uuid4().hex[:12]
    network = prefix + "-net"
    containers = []
    docker("network", "create", network)
    try:
        game = prefix + "-game"
        containers.append(game)
        game_env = dict(os.environ)
        provider_env = []
        if arm == "jev":
            provider_env = ["-e", "TYPESAFE_API_KEY"]
        elif arm == "claude":
            provider_env = ["-e", "ANTHROPIC_API_KEY"]
        docker(
            "run", "-d", "--name", game, "--network", network,
            "--network-alias", game, "-e", "COGAME_HOST=0.0.0.0",
            "-e", "COGAME_PORT=8080",
            "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
            "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
            "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
            "-e", "COGAME_PLAYER_FAILURE_URI=file:///coworld/player_failure.json",
            *provider_env, "-v", f"{out}:/coworld:rw", image,
            "/bin/matrix-games", env=game_env,
        )
        for slot in range(8):
            player = prefix + f"-p{slot}"
            containers.append(player)
            policy_env = ["-e", "PLAYER_SCRIPTED=counter"]
            if slot == 0 and arm == "jev":
                policy_env = ["-e", "PLAYER_JEV=1",
                              "-e", "PLAYER_PROMPT=Choose the best legal move for your own score."]
            elif slot == 0 and arm == "claude":
                policy_env = ["-e", "PLAYER_PROMPT=Choose the best legal move for your own score."]
            docker(
                "run", "-d", "--name", player, "--network", network,
                "-e", f"COWORLD_PLAYER_WS_URL=ws://{game}:8080/player?slot={slot}&token=token-{slot}",
                *policy_env, image, "/bin/matrix-games-player",
            )
        exits = [docker("wait", name, timeout=240) for name in containers]
        assert exits == ["0"] * 9, exits
        results = json.loads((out / "results.json").read_text())
        replay = json.loads((out / "replay.json").read_text())
        orders = [event for event in replay["events"]
                  if event["k"] == "order" and event["seat"] == 0]
        expected = "jev" if arm == "jev" else "llm" if arm == "claude" else "scripted"
        assert len(orders) == config["beats"], len(orders)
        assert all(order["source"] == expected for order in orders), orders
        print(arm, "score", results["scores"][0], "orders", len(orders),
              "mean latency ms",
              round(sum(order["latencyMs"] for order in orders) / len(orders)))
    finally:
        for name in containers:
            log = subprocess.run(["docker", "logs", name],
                                 capture_output=True, text=True)
            (out / f"{name.split('-')[-1]}.log").write_text(log.stdout + log.stderr)
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        subprocess.run(["docker", "network", "rm", network], capture_output=True)
