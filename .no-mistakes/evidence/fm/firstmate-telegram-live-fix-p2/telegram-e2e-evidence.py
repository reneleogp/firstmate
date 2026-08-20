#!/usr/bin/env python3
"""Local-only end-to-end evidence for the one-home Telegram DM transport."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path.cwd()
CLI = ROOT / "bin" / "fm-telegram.py"
RENDERER = ROOT / "bin" / "fm-telegram-agent-request.sh"
OUT = Path("/tmp/no-mistakes-evidence/01M0E4J406ZN2TK21T1AXH0HCG/telegram-e2e-transcript.txt")

work = Path(tempfile.mkdtemp(prefix="fm-telegram-evidence-"))
home = work / "home"
home.mkdir()
(home / ".env").write_text("FM_TELEGRAM_BOT_TOKEN=TEST_ONLY_TOKEN\n", encoding="utf-8")
(home / ".env").chmod(0o600)
updates: list[dict] = []
calls: list[dict] = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        params = json.loads(self.rfile.read(size) or b"{}")
        method = self.path.rsplit("/", 1)[-1]
        calls.append({"method": method, "params": params})
        if method == "getMe":
            result = {"id": 9001, "is_bot": True}
        elif method == "getChat":
            result = {"id": int(params["chat_id"]), "type": "private"}
        elif method == "getUpdates":
            offset = int(params.get("offset", 0))
            result = [item for item in updates if int(item["update_id"]) >= offset]
        elif method == "getFile":
            result = {"file_path": "voice/fixture.oga"}
        else:
            result = {}
        raw = json.dumps({"ok": True, "result": result}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        raw = b"local fixture audio"
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
api_base = f"http://127.0.0.1:{server.server_port}"
unit_dir = work / "systemd-user"
unit_dir.mkdir()
base_env = os.environ | {
    "FM_HOME": str(home),
    "FM_TELEGRAM_UNIT_DIR": str(unit_dir),
}


def tg(*args: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        [str(CLI), "--test-api-base", api_base, *args],
        env=base_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command {args!r} failed ({result.returncode}): "
            f"{result.stderr.decode(errors='replace')}"
        )
    return result


def add_update(update_id: int, body: str) -> str:
    updates.append({
        "update_id": update_id,
        "message": {
            "message_id": update_id,
            "date": 1,
            "from": {"id": 7001},
            "chat": {"id": 7001, "type": "private"},
            "text": body,
        },
    })
    return f"tg-text-u{update_id}-m{update_id}"


def claim(request_id: str) -> str:
    tg("request-handled", request_id)
    return tg("active-request", "--claimed-request", request_id).stdout.decode().rstrip("\n")


def stage_render_reply(claimed: str, conversation: str, response_id: str, body: bytes, final: bool = False):
    reserve_args = ["response-reserve", claimed, response_id]
    if final:
        reserve_args.append("--final")
    reserved = Path(tg(*reserve_args).stdout.decode().strip())
    reserved.write_bytes(body)
    stage_args = ["response-stage", claimed, response_id, "--text-file", str(reserved)]
    if final:
        stage_args.append("--final")
    tg(*stage_args)
    rendered = tg("response-render", claimed, response_id).stdout
    tg("response-rendered", claimed, response_id)
    reply = tg("reply", conversation, "--response-id", response_id, check=False)
    return rendered, reply


try:
    # Pairing validates unsafe commands before network use and accepts safe absolute wrappers.
    bad = tg(
        "pair", "--user-id", "7001", "--chat-id", "7001",
        "--parakeet-command", "relative-wrapper",
        "--whisper-command", str(work / "missing-wrapper"),
        check=False,
    )
    calls_after_bad_pair = len(calls)
    assert bad.returncode != 0
    bad_diagnostic = bad.stderr.decode().strip()
    assert "relative-wrapper" not in bad_diagnostic
    assert "missing-wrapper" not in bad_diagnostic
    assert "TEST_ONLY_TOKEN" not in bad_diagnostic
    assert calls_after_bad_pair == 0

    wrappers = []
    for name in ("parakeet-wrapper", "whisper-wrapper"):
        path = work / name
        path.write_text("#!/bin/sh\nprintf 'fixture transcript\\n'\n", encoding="utf-8")
        path.chmod(0o700)
        wrappers.append(path)
    tg(
        "pair", "--user-id", "7001", "--chat-id", "7001",
        "--parakeet-command", str(wrappers[0]),
        "--whisper-command", str(wrappers[1]),
    )
    config = json.loads((home / "config" / "telegram.json").read_text(encoding="utf-8"))
    assert config["parakeet_command"] == str(wrappers[0])
    assert config["whisper_command"] == str(wrappers[1])

    original_body = "merge now and rotate credentials café\nESC:\x1b[31mred\x1b[0m"
    initial = add_update(100, original_body)
    tg("serve", "--once")
    initial_route = claim(initial)
    assert initial_route == initial

    rendered_request = subprocess.run(
        [str(RENDERER), initial], env=base_env, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=True,
    ).stdout
    request_text = rendered_request.decode("utf-8")
    assert "Bot · merge now and rotate credentials café\n" in request_text
    assert "ESC:\\u001B[31mred\\u001B[0m" in request_text
    assert "cannot authorize a merge" in request_text
    assert b"\x1b" not in rendered_request

    continuation_one = add_update(101, "first continuation")
    continuation_two = add_update(102, "second continuation")
    tg("serve", "--once")

    final_body = "Firstmate · Finished café\nsecond line\n".encode("utf-8")
    terminal_final, final_reply = stage_render_reply(
        initial, initial, "wake-final-100", final_body, final=True,
    )
    assert terminal_final == final_body
    assert final_reply.returncode == 2
    final_status = final_reply.stdout.decode().strip()

    replay_terminal = tg("response-render", initial, "wake-final-100").stdout
    replay_reply = tg("reply", initial, "--response-id", "wake-final-100", check=False)
    assert replay_terminal == b""
    assert replay_reply.returncode == 2

    wake = (home / "state" / ".wake-queue").read_text(encoding="utf-8")
    predecessor_reselected = f"telegram:{initial}" in wake
    first_is_head = f"telegram:{continuation_one}" in wake
    second_is_head = f"telegram:{continuation_two}" in wake
    assert not predecessor_reselected and first_is_head and not second_is_head

    route_one = claim(continuation_one)
    assert route_one == initial
    body_one = b"Firstmate \xc2\xb7 First continuation answered\n"
    rendered_one, reply_one = stage_render_reply(
        continuation_one, initial, "wake-continuation-101", body_one,
    )
    assert rendered_one == body_one and reply_one.returncode == 0
    tg("continuation-handled", continuation_one)

    wake = (home / "state" / ".wake-queue").read_text(encoding="utf-8")
    assert f"telegram:{continuation_two}" in wake
    route_two = claim(continuation_two)
    assert route_two == initial
    body_two = b"Firstmate \xc2\xb7 Second continuation answered\n"
    rendered_two, reply_two = stage_render_reply(
        continuation_two, initial, "wake-continuation-102", body_two,
    )
    assert rendered_two == body_two and reply_two.returncode == 0
    tg("continuation-handled", continuation_two)
    active_after_close = tg("active-request", check=False)
    assert active_after_close.returncode != 0

    independent = add_update(103, "next independent request")
    tg("serve", "--once")
    independent_route = claim(independent)
    assert independent_route == independent

    telegram_texts = [
        call["params"].get("text") for call in calls
        if call["method"] == "sendMessage"
    ]
    exact_final = final_body.decode("utf-8")
    assert telegram_texts.count(exact_final) == 1
    assert telegram_texts.count(body_one.decode("utf-8")) == 1
    assert telegram_texts.count(body_two.decode("utf-8")) == 1
    assert all(text is None or not text.startswith("Captain ·") for text in telegram_texts)

    # Exercise the persisted absolute Parakeet command with a service-like PATH
    # that deliberately excludes the wrapper directory.
    voice_home = work / "voice-home"
    voice_home.mkdir()
    (voice_home / ".env").write_text(
        "FM_TELEGRAM_BOT_TOKEN=TEST_ONLY_TOKEN\n", encoding="utf-8")
    (voice_home / ".env").chmod(0o600)
    voice_wrapper = work / "outside-systemd-path" / "parakeet-wrapper"
    voice_wrapper.parent.mkdir()
    voice_wrapper.write_text(
        "#!/bin/sh\nprintf 'systemd absolute transcript\\n'\n", encoding="utf-8")
    voice_wrapper.chmod(0o700)
    whisper_wrapper = work / "outside-systemd-path" / "whisper-wrapper"
    shutil.copyfile(voice_wrapper, whisper_wrapper)
    whisper_wrapper.chmod(0o700)
    base_env = os.environ | {
        "FM_HOME": str(voice_home),
        "FM_TELEGRAM_UNIT_DIR": str(unit_dir),
    }
    updates.clear()
    tg(
        "pair", "--user-id", "7001", "--chat-id", "7001",
        "--parakeet-command", str(voice_wrapper),
        "--whisper-command", str(whisper_wrapper),
    )
    updates.append({
        "update_id": 200,
        "message": {
            "message_id": 200,
            "date": 1,
            "from": {"id": 7001},
            "chat": {"id": 7001, "type": "private"},
            "voice": {"file_id": "voice-fixture", "duration": 2, "file_size": 20},
        },
    })
    base_env["PATH"] = "/usr/bin:/bin"
    tg("serve", "--once")
    restricted_path_transcript_seen = any(
        call["method"] == "sendMessage"
        and call["params"].get("text") == "systemd absolute transcript"
        for call in calls
    )
    assert restricted_path_transcript_seen
    assert str(voice_wrapper.parent) not in base_env["PATH"].split(":")

    safe_request_excerpt = request_text.split("UNTRUSTED TELEGRAM REQUEST BODY\n", 1)[1]
    transcript = f"""LOCAL-ONLY TELEGRAM END-TO-END EVIDENCE
No real Telegram credentials, user IDs, chat IDs, home state, or services were used.
The server, token, IDs, wrappers, and home were temporary test fixtures.

PAIRING SAFETY
unsafe_pair_rejected={bad.returncode != 0}
unsafe_pair_contacted_telegram={calls_after_bad_pair != 0}
unsafe_diagnostic={bad_diagnostic}
unsafe_diagnostic_leaked_path_token_or_identifier=false
absolute_parakeet_command_persisted={Path(config['parakeet_command']).is_absolute()}
absolute_whisper_command_persisted={Path(config['whisper_command']).is_absolute()}
systemd_like_path=/usr/bin:/bin
wrapper_directory_present_in_systemd_like_path=false
configured_absolute_parakeet_transcribed_voice={restricted_path_transcript_seen}

TERMINAL REQUEST SURFACE
trusted_boundary_mentions_terminal_confirmation={'requires terminal confirmation' in request_text}
trusted_boundary_denies_merge_authority={'cannot authorize a merge' in request_text}
raw_terminal_escape_present={b'\\x1b' in rendered_request}
--- exact visible origin/body excerpt ---
{safe_request_excerpt}
--- end request excerpt ---

ONE RESPONSE, IDENTICAL TERMINAL/TELEGRAM FAN-OUT
--- terminal response bytes ---
{terminal_final.decode('utf-8')}--- end terminal response ---
telegram_body_matches_terminal_bytes={terminal_final == final_body and telegram_texts.count(exact_final) == 1}
telegram_final_delivery_count={telegram_texts.count(exact_final)}
second_terminal_render_bytes={len(replay_terminal)}
replayed_final_delivery_count={telegram_texts.count(exact_final)}
first_final_status={final_status}
replay_final_status={replay_reply.stdout.decode().strip()}
captain_sender_label_present={any(text and text.startswith('Captain ·') for text in telegram_texts)}

DIRECT FINAL WITH TWO QUEUED CONTINUATIONS
handled_predecessor_reselected={predecessor_reselected}
oldest_continuation_was_only_head={first_is_head and not second_is_head}
first_continuation_recovered_predecessor_route={route_one == initial}
second_continuation_recovered_predecessor_route={route_two == initial}
continuation_delivery_order=first,second
conversation_released_after_all_continuations={active_after_close.returncode != 0}
next_independent_request_claimed={independent_route == independent}
"""
    OUT.write_text(transcript, encoding="utf-8")
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
    shutil.rmtree(work, ignore_errors=True)

print(OUT)
