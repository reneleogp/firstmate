#!/usr/bin/env python3
"""Focused acceptance tests for bin/fm-telegram.py, the WSL Telegram mirror bot.

Each test drives the real bot process end to end: a fake Telegram Bot API over
loopback HTTP, a fake Pi extension over the bot's own Unix socket, and a fake
local Parakeet command. Nothing here inspects the bot's source.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parents[1]
BOT = ROOT / "bin" / "fm-telegram.py"
TOKEN = "123:test-token"
USER_ID = 4242
CHAT_ID = 9797
VOICE_BYTES = b"OggS-fake-voice"
DEADLINE = 10.0


class FakeTelegram:
    """Minimal Bot API surface: getUpdates, sendMessage, edits, callbacks, files."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.pending: list[dict[str, Any]] = []
        self.sent: list[dict[str, Any]] = []
        self.edits: list[dict[str, Any]] = []
        self.callback_answers: list[dict[str, Any]] = []
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.next_message_id = 1000
        self.next_update_id = 1
        harness = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args: Any) -> None:
                pass

            def _json(self, payload: Any) -> None:
                body = json.dumps({"ok": True, "result": payload}).encode("utf-8")
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(VOICE_BYTES)))
                    self.end_headers()
                    self.wfile.write(VOICE_BYTES)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                length = int(self.headers.get("Content-Length") or 0)
                params = json.loads(self.rfile.read(length) or b"{}")
                method = self.path.rsplit("/", 1)[-1]
                self._json(harness.dispatch(method, params))

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.handle_error = lambda *_args: None  # a killed bot is expected
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def dispatch(self, method: str, params: dict[str, Any]) -> Any:
        if method != "getUpdates":
            with self.lock:
                self.calls.append((method, params))
        if method == "getUpdates":
            deadline = time.time() + 0.2
            while time.time() < deadline:
                with self.lock:
                    if self.pending:
                        updates, self.pending = self.pending, []
                        return updates
                time.sleep(0.01)
            return []
        if method == "sendMessage":
            with self.lock:
                self.next_message_id += 1
                message = dict(params)
                message["message_id"] = self.next_message_id
                self.sent.append(message)
                return message
        if method == "editMessageText":
            with self.lock:
                self.edits.append(dict(params))
                return dict(params)
        if method == "answerCallbackQuery":
            with self.lock:
                self.callback_answers.append(dict(params))
                return True
        if method == "getFile":
            return {"file_path": "voice/note.oga"}
        return True

    # --- update injection ---

    def push(self, update: dict[str, Any]) -> None:
        with self.lock:
            update["update_id"] = self.next_update_id
            self.next_update_id += 1
            self.pending.append(update)

    def push_text(self, text: str, message_id: int, user: int = USER_ID,
                  chat: int = CHAT_ID, reply_to: Optional[int] = None) -> int:
        message: dict[str, Any] = {
            "message_id": message_id,
            "from": {"id": user},
            "chat": {"id": chat, "type": "private"},
            "text": text,
        }
        if reply_to is not None:
            message["reply_to_message"] = {"message_id": reply_to}
        self.push({"message": message})
        return message_id

    def push_voice(self, message_id: int) -> int:
        self.push({"message": {
            "message_id": message_id,
            "from": {"id": USER_ID},
            "chat": {"id": CHAT_ID, "type": "private"},
            "voice": {"file_id": f"file-{message_id}", "duration": 3},
        }})
        return message_id

    def push_callback(self, data: str, card_id: int, callback_id: str = "cb") -> None:
        self.push({"callback_query": {
            "id": callback_id,
            "from": {"id": USER_ID},
            "data": data,
            "message": {"message_id": card_id, "chat": {"id": CHAT_ID, "type": "private"}},
        }})

    # --- assertions ---

    def wait_sent(self, predicate, timeout: float = DEADLINE) -> dict[str, Any]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for message in self.sent:
                    if predicate(message):
                        return message
            time.sleep(0.02)
        raise AssertionError(f"no sent message matched; saw {self.sent_texts()}")

    def wait_edit(self, predicate, timeout: float = DEADLINE) -> dict[str, Any]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for edit in self.edits:
                    if predicate(edit):
                        return edit
            time.sleep(0.02)
        raise AssertionError(f"no edit matched; saw {[e.get('text') for e in self.edits]}")

    def wait_call(self, method: str, timeout: float = DEADLINE) -> dict[str, Any]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for name, params in self.calls:
                    if name == method:
                        return params
            time.sleep(0.02)
        raise AssertionError(f"the bot never called {method}; saw {[c[0] for c in self.calls]}")

    def sent_texts(self) -> list[str]:
        with self.lock:
            return [str(message.get("text")) for message in self.sent]


class FakePi:
    """The Pi extension's side of the bot socket."""

    def __init__(self, path: Path) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(DEADLINE)
        self.sock.connect(str(path))
        self.buffer = b""
        self.states: list[dict[str, Any]] = []
        self.send({"t": "hello"})

    def send(self, frame: dict[str, Any]) -> None:
        self.sock.sendall((json.dumps(frame) + "\n").encode("utf-8"))

    def read_frame(self, timeout: float = DEADLINE) -> dict[str, Any]:
        """Next frame of any kind, including the bot's state broadcasts."""
        deadline = time.time() + timeout
        while b"\n" not in self.buffer:
            self.sock.settimeout(max(0.05, deadline - time.time()))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise AssertionError("bot closed the socket")
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return json.loads(line.decode("utf-8"))

    def read(self, timeout: float = DEADLINE) -> dict[str, Any]:
        """Next frame that is not a state broadcast; states are recorded."""
        deadline = time.time() + timeout
        while True:
            frame = self.read_frame(max(0.05, deadline - time.time()))
            if frame.get("t") == "state":
                self.states.append(frame)
                continue
            return frame

    def expect_nothing(self, seconds: float = 0.5) -> None:
        """No work frame arrives; a state broadcast is not work."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                frame = self.read_frame(max(0.05, deadline - time.time()))
            except (socket.timeout, TimeoutError):
                return
            if frame.get("t") == "state":
                self.states.append(frame)
                continue
            raise AssertionError(f"unexpected frame from bot: {frame}")

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


class MirrorTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.telegram = FakeTelegram()
        self.addCleanup(self.telegram.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir(parents=True)
        (self.home / "env").write_text(f"TELEGRAM_BOT_TOKEN={TOKEN}\n", encoding="utf-8")
        transcript_script = Path(self.tmp.name) / "fake-parakeet"
        transcript_script.write_text(
            "#!/bin/sh\n"
            "[ -s \"$1\" ] || { echo 'no audio file was downloaded' >&2; exit 3; }\n"
            "printf '%s\\n' \"$(cat \"$FM_TEST_TRANSCRIPT\")\"\n",
            encoding="utf-8",
        )
        transcript_script.chmod(0o755)
        self.transcript_file = Path(self.tmp.name) / "transcript.txt"
        self.transcript_file.write_text("please rebase the branch", encoding="utf-8")
        (self.home / "config.json").write_text(json.dumps({
            "user_id": USER_ID,
            "chat_id": CHAT_ID,
            "transcribe_command": str(transcript_script),
        }), encoding="utf-8")

        environment = dict(os.environ)
        environment.update({
            "FM_TELEGRAM_DIR": str(self.home),
            "FM_TELEGRAM_API_BASE": self.telegram.base,
            "FM_TEST_TRANSCRIPT": str(self.transcript_file),
        })
        self.environment = environment
        self.socket_path = self.home / "bot.sock"
        self.start_bot()

    def start_bot(self) -> None:
        self.bot = subprocess.Popen(
            [sys.executable, str(BOT), "run"], env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.stop_bot)
        deadline = time.time() + DEADLINE
        while not self.socket_path.exists() and time.time() < deadline:
            if self.bot.poll() is not None:
                raise AssertionError(f"bot exited: {self.bot.communicate()[1]}")
            time.sleep(0.02)
        self.assertTrue(self.socket_path.exists(), "bot never opened its socket")

    def stop_bot(self) -> None:
        if self.bot.poll() is None:
            self.bot.terminate()
            try:
                self.bot.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.bot.kill()
                self.bot.wait(timeout=5)
        for stream in (self.bot.stdout, self.bot.stderr):
            if stream is not None:
                stream.close()

    def connect_pi(self) -> FakePi:
        pi = FakePi(self.socket_path)
        self.addCleanup(pi.close)
        return pi

    def enable_mirror(self, pi: FakePi) -> None:
        pi.send({"t": "command", "id": 1, "command": "on"})
        frame = pi.read()
        self.assertEqual(frame["t"], "command_result")
        self.assertIn("Mirror is on", frame["text"])

    def card_id_for(self, text: str) -> int:
        message = self.telegram.wait_sent(lambda m: m.get("text") == text and m.get("reply_markup"))
        return int(message["message_id"])

    # --- scenarios ---

    def test_mirror_off_refuses_ordinary_text(self) -> None:
        pi = self.connect_pi()
        self.telegram.push_text("do the thing", 11)
        reply = self.telegram.wait_sent(
            lambda m: m.get("text") == "Telegram mirror is off. Send /telegram on to enable it."
        )
        self.assertEqual(reply["reply_parameters"]["message_id"], 11)
        pi.expect_nothing()

    def test_commands_work_from_telegram_and_from_pi(self) -> None:
        pi = self.connect_pi()
        self.telegram.push_text("/telegram status", 12)
        first = self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is off"))
        self.assertIn("Firstmate is connected", first["text"])
        self.telegram.push_text("/telegram on", 13)
        self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is on"))
        pi.send({"t": "command", "id": 7, "command": "status"})
        frame = pi.read()
        self.assertEqual(frame, {"t": "command_result", "id": 7,
                                 "text": "Mirror is on. Firstmate is connected. Confirmations are on."})
        pi.send({"t": "command", "id": 8, "command": "off"})
        self.assertIn("Mirror is off", pi.read()["text"])

    def test_menu_aliases_are_published_and_switch_the_mirror(self) -> None:
        pi = self.connect_pi()
        published = self.telegram.wait_call("setMyCommands")
        self.assertEqual(
            [entry["command"] for entry in published["commands"]],
            ["telegram_on", "telegram_off", "telegram_status"],
        )
        self.assertTrue(all(entry.get("description") for entry in published["commands"]))
        self.assertEqual(published["scope"], {"type": "chat", "chat_id": CHAT_ID})

        self.telegram.push_text("/telegram_on", 71)
        started = self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is on"))
        self.assertEqual(started["reply_parameters"]["message_id"], 71)

        # An alias is transport, so it is never forwarded to Firstmate.
        pi.expect_nothing()

        self.telegram.push_text("/telegram_status@FirstmateMirrorBot", 72)
        status = self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Mirror is on")
            and m.get("reply_parameters", {}).get("message_id") == 72
        )
        self.assertIn("Firstmate is connected", status["text"])

        self.telegram.push_text("/telegram_off", 73)
        self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Mirror is off")
            and m.get("reply_parameters", {}).get("message_id") == 73
        )

        # Both spellings stay live: the spaced form still switches it back on.
        self.telegram.push_text("/telegram on", 74)
        self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Mirror is on")
            and m.get("reply_parameters", {}).get("message_id") == 74
        )
        self.telegram.push_text("an ordinary message", 75)
        self.assertEqual(pi.read()["text"], "an ordinary message")

    def test_confirmations_default_on_toggle_persists_and_gates_only_the_receipt(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_text("/telegram_status", 201)
        card = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 201
        )
        self.assertIn("Confirmations are on.", card["text"])
        self.assertEqual(
            card["reply_markup"]["inline_keyboard"][0][0]["text"], "Disable confirmations"
        )
        card_id = int(card["message_id"])

        # A delivered message is still confirmed while the setting is on.
        self.telegram.push_text("before the toggle", 202)
        frame = pi.read()
        pi.send({"t": "accepted", "id": frame["id"]})
        receipt = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(receipt["reply_parameters"]["message_id"], 202)

        self.telegram.push_callback("c:confirmations", card_id, "cb-confirm")
        toggled = self.telegram.wait_edit(lambda e: "Confirmations are off." in str(e.get("text")))
        self.assertEqual(
            toggled["reply_markup"]["inline_keyboard"][0][0]["text"], "Enable confirmations"
        )
        self.assertIs(json.loads((self.home / "config.json").read_text())["confirmations"], False)

        # With the setting off the receipt is gone, but the message must still
        # leave the pending queue: reconnecting may not deliver it a second time.
        receipts_before = len([m for m in self.telegram.sent if m.get("text") == "Pi · Sent to Firstmate."])
        self.telegram.push_text("after the toggle", 203)
        second = pi.read()
        self.assertEqual(second["text"], "after the toggle")
        pi.send({"t": "accepted", "id": second["id"]})
        time.sleep(0.6)
        receipts_after = len([m for m in self.telegram.sent if m.get("text") == "Pi · Sent to Firstmate."])
        self.assertEqual(receipts_after, receipts_before)
        pi.close()
        time.sleep(0.3)
        later = self.connect_pi()
        later.expect_nothing(1.0)

        # The choice survives a restart, and the mirror still starts off.
        self.stop_bot()
        deadline = time.time() + DEADLINE
        while self.socket_path.exists() and time.time() < deadline:
            time.sleep(0.02)
        self.start_bot()
        restarted = self.connect_pi()
        restarted.send({"t": "command", "id": 3, "command": "status"})
        self.assertEqual(
            restarted.read()["text"],
            "Mirror is off. Firstmate is connected. Confirmations are off.",
        )

    def test_voice_send_without_confirmations_still_reaches_pi(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_text("/telegram_status", 211)
        card = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 211
        )
        self.telegram.push_callback("c:confirmations", int(card["message_id"]), "cb-off")
        self.telegram.wait_edit(lambda e: "Confirmations are off." in str(e.get("text")))

        self.telegram.push_voice(212)
        transcript_id = self.card_id_for("please rebase the branch")
        self.telegram.push_callback("v:212:1:send", transcript_id, "cb-voice-send")
        self.telegram.wait_edit(lambda e: str(e.get("text", "")).endswith("Sent to Firstmate"))
        frame = pi.read()
        self.assertEqual(frame["text"], "please rebase the branch")
        pi.send({"t": "accepted", "id": frame["id"]})
        time.sleep(0.6)
        self.assertNotIn("Pi · Sent to Firstmate.", self.telegram.sent_texts())
        self.assertFalse((self.home / "audio" / "212.ogg").exists())

    def test_state_frames_track_both_surfaces_and_the_pi_toggle(self) -> None:
        pi = self.connect_pi()
        # A connecting session is told the current state without asking.
        first = pi.read_frame()
        self.assertEqual(first, {"t": "state", "mirror": False, "confirmations": True})

        # Telegram turning the mirror on must reach Pi's footer.
        self.telegram.push_text("/telegram_on", 301)
        self.assertEqual(pi.read_frame(), {"t": "state", "mirror": True, "confirmations": True})

        # Bare /telegram in Pi toggles, and answers with the same status line.
        pi.send({"t": "command", "id": 1, "command": "toggle"})
        result = pi.read_frame()
        self.assertEqual(result["t"], "command_result")
        self.assertIn("Mirror is off", result["text"])
        self.assertEqual(pi.read_frame(), {"t": "state", "mirror": False, "confirmations": True})
        pi.send({"t": "command", "id": 2, "command": "toggle"})
        self.assertIn("Mirror is on", pi.read_frame()["text"])
        self.assertEqual(pi.read_frame(), {"t": "state", "mirror": True, "confirmations": True})

        # A toggle from Pi is visible to Telegram too.
        self.telegram.push_text("/telegram_status", 302)
        card = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 302
        )
        self.assertIn("Mirror is on", card["text"])

    def test_confirmations_toggle_from_pi_settings_matches_telegram(self) -> None:
        pi = self.connect_pi()
        self.assertEqual(pi.read_frame(), {"t": "state", "mirror": False, "confirmations": True})

        # Pi's settings UI writes through the same owner as the Telegram button.
        pi.send({"t": "set", "id": 5, "setting": "confirmations", "value": False})
        result = pi.read_frame()
        self.assertEqual(result["t"], "command_result")
        self.assertIn("Confirmations are off", result["text"])
        self.assertEqual(pi.read_frame(), {"t": "state", "mirror": False, "confirmations": False})
        self.assertIs(json.loads((self.home / "config.json").read_text())["confirmations"], False)

        # Telegram shows the same value, and its button now offers the opposite.
        self.telegram.push_text("/telegram_status", 311)
        card = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 311
        )
        self.assertIn("Confirmations are off", card["text"])
        self.assertEqual(
            card["reply_markup"]["inline_keyboard"][0][0]["text"], "Enable confirmations"
        )

        # Toggling back from Telegram publishes the new value to Pi.
        self.telegram.push_callback("c:confirmations", int(card["message_id"]), "cb-back-on")
        deadline = time.time() + DEADLINE
        published = None
        while time.time() < deadline:
            frame = pi.read_frame(timeout=2)
            if frame.get("t") == "state" and frame.get("confirmations") is True:
                published = frame
                break
        self.assertIsNotNone(published, "the Telegram toggle was never published to Pi")
        self.assertIs(json.loads((self.home / "config.json").read_text())["confirmations"], True)

    def test_telegram_text_reaches_pi_unchanged_and_is_confirmed(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_text("look at the failing test", 21)
        frame = pi.read()
        self.assertEqual(frame["t"], "deliver")
        self.assertEqual(frame["text"], "look at the failing test")
        self.assertEqual(set(frame), {"t", "id", "text"})
        pi.send({"t": "accepted", "id": frame["id"]})
        confirmation = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(confirmation["reply_parameters"]["message_id"], 21)

    def test_back_to_back_messages_keep_arrival_order(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        for index, text in enumerate(["first", "second", "third"]):
            self.telegram.push_text(text, 30 + index)
        seen = []
        for _ in range(3):
            frame = pi.read()
            seen.append(frame["text"])
            pi.send({"t": "accepted", "id": frame["id"]})
        self.assertEqual(seen, ["first", "second", "third"])

    def test_other_senders_and_chats_are_ignored(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_text("stranger", 41, user=1)
        self.telegram.push_text("wrong chat", 42, chat=1)
        self.telegram.push_text("paired", 43)
        frame = pi.read()
        self.assertEqual(frame["text"], "paired")
        self.assertNotIn("stranger", " ".join(self.telegram.sent_texts()))
        self.assertNotIn("wrong chat", " ".join(self.telegram.sent_texts()))

    def test_offline_messages_queue_in_memory_and_drain_on_connect(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.close()
        time.sleep(0.3)
        self.telegram.push_text("queued one", 51)
        offline = self.telegram.wait_sent(
            lambda m: m.get("text") == "Firstmate is not running. Your message is queued until it starts."
        )
        self.assertEqual(offline["reply_parameters"]["message_id"], 51)
        self.telegram.push_text("queued two", 52)
        time.sleep(0.3)
        later = self.connect_pi()
        first = later.read()
        second = later.read()
        self.assertEqual([first["text"], second["text"]], ["queued one", "queued two"])
        later.send({"t": "accepted", "id": first["id"]})
        confirmation = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(confirmation["reply_parameters"]["message_id"], 51)

    def test_terminal_and_reply_mirroring_follows_mirror_mode(self) -> None:
        pi = self.connect_pi()
        pi.send({"t": "terminal", "text": "typed while off"})
        pi.send({"t": "reply", "text": "answered while off"})
        time.sleep(0.4)
        self.assertEqual(self.telegram.sent_texts(), [])
        self.enable_mirror(pi)
        pi.send({"t": "terminal", "text": "check the logs"})
        mirrored = self.telegram.wait_sent(lambda m: "check the logs" in str(m.get("text")))
        self.assertEqual(mirrored["text"], "You · Terminal\ncheck the logs")
        pi.send({"t": "reply", "text": "The logs are clean."})
        reply = self.telegram.wait_sent(lambda m: m.get("text") == "The logs are clean.")
        self.assertNotIn("reply_parameters", reply)

    def test_firstmate_replies_are_never_threaded_while_statuses_are(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_text("what is the status", 61)
        frame = pi.read()
        pi.send({"t": "accepted", "id": frame["id"]})
        confirmation = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(confirmation["reply_parameters"]["message_id"], 61)
        pi.send({"t": "reply", "text": "Everything is green."})
        reply = self.telegram.wait_sent(lambda m: m.get("text") == "Everything is green.")
        self.assertNotIn("reply_parameters", reply)

    def test_a_burst_never_threads_replies_but_keeps_every_status_attached(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        # Pi answers a back-to-back burst inside one run, so no reply belongs to
        # any single source message.
        for index, text in enumerate(["burst one", "burst two", "burst three"]):
            self.telegram.push_text(text, 101 + index)
        sources = []
        for _ in range(3):
            frame = pi.read()
            sources.append(frame["text"])
            pi.send({"t": "accepted", "id": frame["id"]})
        self.assertEqual(sources, ["burst one", "burst two", "burst three"])
        for text in ["Reply 1", "Reply 2", "Reply 3", "Reply 4", "Reply 5"]:
            pi.send({"t": "reply", "text": text})
            mirrored = self.telegram.wait_sent(lambda m, want=text: m.get("text") == want)
            self.assertNotIn("reply_parameters", mirrored)
        pi.send({"t": "terminal", "text": "typed while bursting"})
        echoed = self.telegram.wait_sent(lambda m: "typed while bursting" in str(m.get("text")))
        self.assertNotIn("reply_parameters", echoed)

        # Every transport status still names the exact message it describes.
        confirmations = [
            message["reply_parameters"]["message_id"]
            for message in self.telegram.sent
            if message.get("text") == "Pi · Sent to Firstmate."
        ]
        self.assertEqual(sorted(confirmations), [101, 102, 103])
        pi.send({"t": "command", "id": 9, "command": "off"})
        self.assertIn("Mirror is off", pi.read()["text"])
        self.telegram.push_text("after the burst", 110)
        refusal = self.telegram.wait_sent(
            lambda m: m.get("text") == "Telegram mirror is off. Send /telegram on to enable it."
        )
        self.assertEqual(refusal["reply_parameters"]["message_id"], 110)

    def test_voice_note_edit_then_send(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(71)
        progress = self.telegram.wait_sent(lambda m: m.get("text") == "Transcribing…")
        self.assertEqual(progress["reply_parameters"]["message_id"], 71)
        card = self.telegram.wait_sent(
            lambda m: m.get("text") == "please rebase the branch" and m.get("reply_markup")
        )
        self.assertEqual(card["reply_parameters"]["message_id"], 71)
        buttons = [button["text"] for row in card["reply_markup"]["inline_keyboard"] for button in row]
        self.assertEqual(buttons, ["Send to Firstmate", "Edit", "Cancel"])
        card_id = int(card["message_id"])
        pi.expect_nothing()

        self.telegram.push_callback(f"v:71:1:edit", card_id, "cb-edit")
        edit_view = self.telegram.wait_edit(lambda e: e.get("message_id") == card_id)
        edit_buttons = [b["text"] for row in edit_view["reply_markup"]["inline_keyboard"] for b in row]
        self.assertEqual(edit_buttons, ["Copy text", "Back"])
        prompt = self.telegram.wait_sent(
            lambda m: m.get("text") == "Reply to this message with the corrected text."
        )
        self.assertTrue(prompt["reply_markup"]["force_reply"])

        self.telegram.push_text("please rebase the release branch", 72,
                                reply_to=int(prompt["message_id"]))
        corrected = self.telegram.wait_edit(
            lambda e: e.get("text") == "please rebase the release branch"
        )
        restored = [b["text"] for row in corrected["reply_markup"]["inline_keyboard"] for b in row]
        self.assertEqual(restored, ["Send to Firstmate", "Edit", "Cancel"])
        pi.expect_nothing()

        self.telegram.push_callback("v:71:1:send", card_id, "cb-stale")
        stale = [answer for answer in self.telegram.callback_answers if answer.get("text")]
        deadline = time.time() + DEADLINE
        while not stale and time.time() < deadline:
            time.sleep(0.02)
            stale = [answer for answer in self.telegram.callback_answers if answer.get("text")]
        self.assertIn("moved on", stale[0]["text"])
        pi.expect_nothing()

        self.telegram.push_callback("v:71:3:send", card_id, "cb-send")
        sent_card = self.telegram.wait_edit(lambda e: str(e.get("text", "")).endswith("Sent to Firstmate"))
        self.assertEqual(sent_card["reply_markup"], {"inline_keyboard": []})
        frame = pi.read()
        self.assertEqual(frame["text"], "please rebase the release branch")
        pi.send({"t": "accepted", "id": frame["id"]})
        confirmation = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(confirmation["reply_parameters"]["message_id"], 71)
        self.assertFalse((self.home / "audio" / "71.ogg").exists())

        self.telegram.push_callback("v:71:3:send", card_id, "cb-repeat")
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            texts = [a.get("text", "") for a in self.telegram.callback_answers]
            if any("no longer active" in text for text in texts):
                break
            time.sleep(0.02)
        else:
            raise AssertionError("a repeated tap was not refused")
        pi.expect_nothing()

    def test_voice_note_cancel_sends_nothing(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(81)
        card_id = self.card_id_for("please rebase the branch")
        self.telegram.push_callback("v:81:1:cancel", card_id, "cb-cancel")
        cancelled = self.telegram.wait_edit(lambda e: str(e.get("text", "")).endswith("Cancelled"))
        self.assertEqual(cancelled["reply_markup"], {"inline_keyboard": []})
        self.assertFalse((self.home / "audio" / "81.ogg").exists())
        pi.expect_nothing()

    def test_a_restart_loses_the_in_memory_queue_and_resets_mirror_mode(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.close()
        time.sleep(0.3)
        self.telegram.push_text("waiting for firstmate", 91)
        self.telegram.wait_sent(
            lambda m: m.get("text") == "Firstmate is not running. Your message is queued until it starts."
        )
        self.stop_bot()
        deadline = time.time() + DEADLINE
        while self.socket_path.exists() and time.time() < deadline:
            time.sleep(0.02)
        self.assertFalse(self.socket_path.exists(), "the stopped bot left its socket behind")

        self.start_bot()
        later = self.connect_pi()
        later.expect_nothing(1.0)
        later.send({"t": "command", "id": 1, "command": "status"})
        self.assertEqual(later.read()["text"],
                         "Mirror is off. Firstmate is connected. Confirmations are on.")


class ServiceUnitTestCase(unittest.TestCase):
    def test_unit_starts_the_bot_and_carries_no_secret(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            environment = dict(os.environ)
            environment.update({"FM_TELEGRAM_DIR": tmp, "TELEGRAM_BOT_TOKEN": TOKEN})
            unit = subprocess.run(
                [sys.executable, str(BOT), "service-unit"], env=environment,
                stdout=subprocess.PIPE, text=True, check=True,
            ).stdout
        self.assertIn("WantedBy=default.target", unit)
        self.assertIn(f"{BOT} run", unit)
        self.assertIn(f"Environment=FM_TELEGRAM_DIR={tmp}", unit)
        self.assertNotIn(TOKEN, unit)

    def test_service_install_refuses_outside_wsl(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            environment = dict(os.environ)
            environment.update({"FM_TELEGRAM_DIR": tmp, "TELEGRAM_BOT_TOKEN": TOKEN})
            environment.pop("WSL_DISTRO_NAME", None)
            environment["FM_TELEGRAM_ASSUME_WSL"] = "0"
            environment["HOME"] = tmp
            result = subprocess.run(
                [sys.executable, str(BOT), "install-service"], env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WSL only", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
