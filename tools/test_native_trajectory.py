"""Verify native HTTP/WebSocket trajectory evidence without provider credentials.

Arguments: compiled game, fresh private output, source commit, replay verifier.
"""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from websockets.sync.client import connect

parser = argparse.ArgumentParser()
parser.add_argument("binary", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("revision")
parser.add_argument("verifier", type=Path)
parser.add_argument("--published", action="store_true")
parser.add_argument("--variant", default="prisoners-dilemma")
parser.add_argument("--wording", default="canonical")
parser.add_argument(
    "--mode", choices=("accepted", "retry", "fallback", "greedy", "refusal")
)
args = parser.parse_args()
binary, revision = args.binary, args.revision
root = args.output.resolve()
root.mkdir(mode=0o700, parents=True, exist_ok=False)
reports = []
for mode in (
    [args.mode] if args.mode else ["accepted", "retry", "fallback", "greedy", "refusal"]
):
    folder = root / mode
    folder.mkdir(mode=0o700)
    requests = []

    class Native(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            assert self.path == "/v1/messages"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            user = body["messages"][0]["content"]
            action = {
                "intent": "hold",
                "say": "fixture public speech",
                "notes": "PRIVATE NOTE SENTINEL",
            }
            raw = json.dumps(action, separators=(",", ":"))
            if (
                mode == "fallback"
                or mode == "retry"
                and "previous reply was invalid" not in user
            ):
                raw = "PRIVATE INVALID RESPONSE SENTINEL"
            call_id = str(uuid.uuid4())
            response = {
                "id": call_id,
                "type": "message",
                "role": "assistant",
                "model": body["model"],
                "content": [{"type": "text", "text": raw}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 100, "output_tokens": 20},
            }
            if mode == "refusal":
                response["stop_reason"] = "refusal"
            if mode == "greedy":
                response["sampling_evidence"] = {
                    "prompt_token_ids": [1],
                    "completion_token_ids": [2],
                    "behavior_log_probs": None,
                    "stop_reason": "eos",
                }
            response["model"] = "fixture/actual-served"
            requests.append(
                {
                    "platform_call_id": call_id,
                    "caller_request": body,
                    "caller_slot": self.headers["X-Coworld-Player-Slot"],
                    "provider_response": response,
                }
            )
            payload = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            self.send_header("X-Coworld-Checkpoint-Sha256", "a" * 64)
            self.send_header("X-Coworld-Tokenizer-Sha256", "b" * 64)
            self.send_header("X-Coworld-Chat-Template-Sha256", "c" * 64)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Native)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    config: dict = {
        "seed": 17,
        "num_agents": 8,
        "matrix": "prisoners-dilemma",
        "beats": 2,
        "ticksPerBeat": 10,
        "minBeatSeconds": 0,
        "llmTimeoutSeconds": 1,
        "playerConnectTimeoutSeconds": 3,
        "shutdownGraceSeconds": 0,
        "episodeTimeoutSeconds": 60,
        "tokens": [str(i) for i in range(8)],
        "players": [{"name": "fixture-" + str(i)} for i in range(8)],
    }
    if args.published:
        manifest = json.loads(
            (
                Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
            ).read_text()
        )
        config = {
            key: schema["default"]
            for key, schema in manifest["game"]["config_schema"]["properties"].items()
            if "default" in schema
        }
        config.update(
            next(
                v["game_config"]
                for v in manifest["variants"]
                if v["id"] == args.variant
            )
        )
        config.update(
            seed=17,
            tokens=[str(i) for i in range(8)],
            players=[{"name": "fixture-" + str(i)} for i in range(8)],
        )
    config.update(promptVariant=args.wording, promptSeed=3)
    config_path = folder / "config.json"
    config_path.write_text(json.dumps(config))
    environment = dict(os.environ)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=config_path.as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{server.server_port}",
        COWORLD_LLM_MODEL="fixture/native",
        COWORLD_LLM_TEMPERATURE="0",
        COWORLD_EPISODE_ID="fixture-" + mode,
        COWORLD_GAME_VERSION="source-fixture",
        COWORLD_SOURCE_REVISION=revision,
    )
    started = time.monotonic()
    final_frames = []
    with (folder / "game.log").open("w") as log:
        process = subprocess.Popen(
            [binary], env=environment, stdout=log, stderr=subprocess.STDOUT
        )
        try:
            deadline = time.monotonic() + 10
            while True:
                probe = socket.socket()
                ready = probe.connect_ex(("127.0.0.1", port)) == 0
                probe.close()
                if ready:
                    break
                assert process.poll() is None, (folder / "game.log").read_text()
                assert time.monotonic() < deadline
                threading.Event().wait(0.01)
            sockets = [
                connect(f"ws://127.0.0.1:{port}/player?slot={slot}&token={slot}")
                for slot in range(8)
            ]
            try:
                for seat in sockets:
                    seat.send(
                        json.dumps(
                            {"type": "prompt", "prompt": "PRIVATE OPERATOR SENTINEL"}
                        )
                    )

                def receive(seat):
                    for message in seat:
                        frame = json.loads(message)
                        if frame["type"] == "final":
                            final_frames.append(frame)
                            break

                readers = [
                    threading.Thread(target=receive, args=(seat,)) for seat in sockets
                ]
                for reader in readers:
                    reader.start()
                assert process.wait(timeout=config["episodeTimeoutSeconds"]) == 0, (
                    folder / "game.log"
                ).read_text()
                for reader in readers:
                    reader.join(timeout=5)
                    assert not reader.is_alive()
                assert len(final_frames) == 8
            finally:
                for seat in sockets:
                    seat.close()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            server.shutdown()
            server.server_close()
    events = [
        json.loads(line)
        for line in (folder / "trajectory.jsonl").read_text().splitlines()
    ]
    decisions = events[:-1]
    assert len(decisions) == config["beats"] * 8 and all(
        decision["terminal"] for decision in decisions[-8:]
    )
    assert events[-1]["status"] == "completed"
    assert events[-1]["outcome"]["beats"] == config["beats"]
    assert events[-1]["source_revision"] == revision
    if args.published:
        assert (
            time.monotonic() - started
            >= (config["beats"] - 1) * config["minBeatSeconds"]
        )
    subprocess.run(
        [args.verifier, folder / "trajectory.jsonl", folder / "replay.json"], check=True
    )
    calls = {record["platform_call_id"]: record for record in requests}
    for decision in decisions:
        metadata = decision["observation"]["prompt_template"]
        assert metadata["bank"] == "matrix-games-rules-v1"
        assert metadata["selection"] == args.wording and metadata["seed"] == 3
        expected = "questions" if args.wording == "mixed" else args.wording
        assert metadata["variant"] == expected
        first_prompt = decision["attempts"][0]["prompt"]
        for role, index in (("system", 0), ("user", 1)):
            assert (
                metadata[role + "_sha256"]
                == hashlib.sha256(first_prompt[index]["content"].encode()).hexdigest()
            )
        for attempt in decision["attempts"]:
            archive = calls[attempt["platform_call_id"]]
            assert decision["seat"] == archive["caller_slot"]
            assert attempt["request"] == archive["caller_request"]
            assert attempt["request"]["model"] == "fixture/native"
            assert (
                attempt["model"]
                == archive["provider_response"]["model"]
                == "fixture/actual-served"
            )
            assert attempt["decoder"] == {
                "max_tokens": archive["caller_request"]["max_tokens"],
                "temperature": 0,
            }
            assert attempt["model_identity"] == "a" * 64
            assert attempt["tokenizer_identity"] == "b" * 64
            assert attempt["chat_template_sha256"] == "c" * 64
            if mode == "greedy":
                assert attempt["prompt_token_ids"] == [1]
                assert attempt["sampled_token_ids"] == [2]
                assert attempt["behavior_logprobs"] is None
            assert attempt["raw_response"] == archive["provider_response"]
        if decision["action_status"] == "accepted":
            selected = next(
                a
                for a in decision["attempts"]
                if a["attempt_id"] == decision["selected_attempt_id"]
            )
            assert (
                selected["accepted"]
                and selected["parsed_action"] == decision["executed_action"]
            )
            assert selected["parsed_action"] == json.loads(selected["response"])
        else:
            assert (
                mode in {"fallback", "refusal"}
                and decision["selected_attempt_id"] is None
            )
    for private_text in ["PRIVATE NOTE SENTINEL", "PRIVATE INVALID RESPONSE SENTINEL"]:
        assert private_text not in (folder / "replay.json").read_text()
        assert private_text not in (folder / "game.log").read_text()
    assert "PRIVATE OPERATOR SENTINEL" not in (folder / "replay.json").read_text()
    assert "PRIVATE OPERATOR SENTINEL" not in (folder / "game.log").read_text()
    assert "PRIVATE OPERATOR SENTINEL" in (folder / "trajectory.jsonl").read_text()
    assert (folder / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
    reports.append(
        {
            "mode": mode,
            "variant": args.variant,
            "wording": args.wording,
            "published": args.published,
            "complete_episodes": 1,
            "decisions": len(decisions),
            "native_call_joins": len(requests),
            "source_revision": revision,
            "cohort": "native HTTP fixture; no platform hosted claim",
        }
    )
(root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
print(json.dumps(reports))
