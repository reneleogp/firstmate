#!/usr/bin/env python3
"""fm-telegram.py - Firstmate's Telegram terminal mirror bot (WSL only).

One private Telegram bot that mirrors the one Firstmate terminal conversation
in both directions. It runs beside Pi as a WSL user service and talks to the
tracked Pi extension .pi/extensions/fm-telegram-mirror.ts over one local Unix
socket. The bot contains no model, agent loop, or Firstmate reasoning.

Layout (one private directory, owner-only, default ~/.firstmate-telegram,
overridden by FM_TELEGRAM_DIR):

  env          KEY=VALUE file holding TELEGRAM_BOT_TOKEN (never in the unit)
  config.json  pairing and local commands:
                 user_id            paired Telegram account id (integer)
                 chat_id            paired private chat id (integer)
                 transcribe_command local Parakeet command (string; the audio
                                    path replaces {audio} or is appended)
                 confirmations      send "Pi · Sent to Firstmate." or not
                                    (boolean, default true, persisted by the
                                    Telegram control button)
  bot.sock     Unix socket the Pi extension connects to
  audio/       temporary voice downloads, deleted after send, cancel, failure,
               and at start and stop

Wire protocol (newline-delimited JSON, both directions):

  extension -> bot  {"t":"hello"}
                    {"t":"terminal","text":...}     terminal submission
                    {"t":"reply","text":...}        final visible Firstmate text
                    {"t":"command","id":N,"command":"on"|"off"|"status"}
                    {"t":"accepted","id":"..."}     Pi accepted that message
  bot -> extension  {"t":"deliver","id":"...","text":...}
                    {"t":"command_result","id":N,"text":...}

These commands work from both Telegram and the Pi terminal and never reach
Firstmate as conversation text:

  /telegram on | off | status        both surfaces
  /telegram_on | /telegram_off | /telegram_status
                                     Telegram menu aliases, published to the
                                     paired chat with setMyCommands because
                                     Telegram's menu rejects a space

Mirror mode starts off on every start and lives in memory only. The inbound
queue is an in-memory FIFO with no durable queue, expiry, replay journal, or
retention subsystem: a queued message that has not reached Pi is lost when the
bot or WSL stops.

Reply threading: every transport status the bot itself produces replies to the
exact Telegram message it describes, because the bot knows that message. A
mirrored Firstmate reply is always sent as a normal unthreaded message. Pi
batches back-to-back submissions into one run, so a reply has no single source
message, and a guessed target would attach answers to the wrong one.

Usage:
  fm-telegram.py run                run the bot in the foreground (the service)
  fm-telegram.py pair               record the first private sender as the pair
  fm-telegram.py status             print pairing, service, and socket status
  fm-telegram.py service-unit       print the systemd user unit text
  fm-telegram.py install-service    write, enable, and start the WSL user service
  fm-telegram.py uninstall-service  stop, disable, and remove that service

Environment:
  FM_TELEGRAM_DIR        private directory (default ~/.firstmate-telegram)
  FM_TELEGRAM_API_BASE   Telegram API base URL (tests point this at a fake)
  FM_TELEGRAM_ASSUME_WSL 1 or 0 to force the WSL verdict for service commands
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import shlex
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

SERVICE_NAME = "firstmate-telegram.service"
DEFAULT_API_BASE = "https://api.telegram.org"
DEFAULT_TRANSCRIBE_COMMAND = "parakeet-tdt-0.6b-v3"

MIRROR_OFF_REPLY = "Telegram mirror is off. Send /telegram on to enable it."
OFFLINE_REPLY = "Firstmate is not running. Your message is queued until it starts."
ACCEPTED_REPLY = "Pi · Sent to Firstmate."
TRANSCRIBING_REPLY = "Transcribing…"
TERMINAL_LABEL = "You · Terminal"
SENT_FOOTER = "Sent to Firstmate"
CANCELLED_FOOTER = "Cancelled"
EDIT_PROMPT = "Reply to this message with the corrected text."
TRANSCRIBE_FAILED_REPLY = "Transcription failed. Nothing was sent to Firstmate."
UNSUPPORTED_REPLY = "Only text and voice notes are mirrored."
HELP_REPLY = (
    "Firstmate terminal mirror.\n"
    "/telegram_on or /telegram on - start mirroring\n"
    "/telegram_off or /telegram off - stop mirroring\n"
    "/telegram_status or /telegram status - show mirror and Firstmate state"
)

MIRROR_COMMANDS = ("on", "off", "status")
# Telegram's command menu accepts only lowercase letters, digits, and
# underscores, so "/telegram on" cannot appear in it. These single-token
# aliases are the menu entries; both forms do the same thing.
MIRROR_ALIASES = {
    "/telegram_on": "on",
    "/telegram_off": "off",
    "/telegram_status": "status",
}
MENU_COMMANDS = [
    {"command": "telegram_on", "description": "Start mirroring the Firstmate terminal"},
    {"command": "telegram_off", "description": "Stop mirroring"},
    {"command": "telegram_status", "description": "Show mirror and Firstmate state"},
]
# The delivery-confirmation setting is a Telegram-side preference, so its only
# control is this button on the command replies. Pi gets no command for it.
CONFIRMATIONS_CALLBACK = "c:confirmations"
DISABLE_CONFIRMATIONS_LABEL = "Disable confirmations"
ENABLE_CONFIRMATIONS_LABEL = "Enable confirmations"
TELEGRAM_TEXT_LIMIT = 3900
COPY_TEXT_LIMIT = 256
TRANSCRIBE_TIMEOUT = 180
POLL_TIMEOUT = 25
MAX_VOICE_BYTES = 20 * 1024 * 1024


class TelegramError(RuntimeError):
    """A Telegram API or local configuration failure."""


def log(message: str) -> None:
    print(f"fm-telegram: {message}", file=sys.stderr, flush=True)


# --- configuration ----------------------------------------------------------


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    try:
        path.chmod(0o700)
    except OSError:
        pass
    return path


def home_dir() -> Path:
    value = os.environ.get("FM_TELEGRAM_DIR")
    if value:
        return Path(value).expanduser()
    return Path.home() / ".firstmate-telegram"


def env_file(home: Path) -> Path:
    return home / "env"


def config_file(home: Path) -> Path:
    return home / "config.json"


def socket_path(home: Path) -> Path:
    return home / "bot.sock"


def audio_dir(home: Path) -> Path:
    return home / "audio"


def read_env(home: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        raw = env_file(home).read_text(encoding="utf-8")
    except OSError:
        return values
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def read_config(home: Path) -> dict[str, Any]:
    try:
        data = json.loads(config_file(home).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def write_config(home: Path, data: dict[str, Any]) -> None:
    private_dir(home)
    target = config_file(home)
    target.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    target.chmod(0o600)


@dataclass
class Config:
    home: Path
    token: str
    user_id: int
    chat_id: int
    transcribe_command: str
    api_base: str
    confirmations: bool = True


def load_config(home: Path) -> Config:
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or read_env(home).get("TELEGRAM_BOT_TOKEN", "")
    if not token:
        raise TelegramError(
            f"no TELEGRAM_BOT_TOKEN in {env_file(home)}; add it as TELEGRAM_BOT_TOKEN=<token>"
        )
    data = read_config(home)
    user_id = data.get("user_id")
    chat_id = data.get("chat_id")
    if not isinstance(user_id, int) or not isinstance(chat_id, int):
        raise TelegramError(
            f"no pairing in {config_file(home)}; run fm-telegram.py pair and message the bot"
        )
    command = data.get("transcribe_command") or DEFAULT_TRANSCRIBE_COMMAND
    api_base = os.environ.get("FM_TELEGRAM_API_BASE") or data.get("api_base") or DEFAULT_API_BASE
    confirmations = data.get("confirmations")
    return Config(
        home=home,
        token=token,
        user_id=user_id,
        chat_id=chat_id,
        transcribe_command=str(command),
        api_base=str(api_base).rstrip("/"),
        confirmations=confirmations if isinstance(confirmations, bool) else True,
    )


# --- Telegram API -----------------------------------------------------------


class TelegramApi:
    def __init__(self, base: str, token: str) -> None:
        self._base = base.rstrip("/")
        self._token = token

    def request_sync(self, method: str, params: dict[str, Any], timeout: float = 30) -> Any:
        url = f"{self._base}/bot{self._token}/{method}"
        body = json.dumps(params).encode("utf-8")
        request = urllib.request.Request(
            url, data=body, headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:400]
            raise TelegramError(f"{method} failed with HTTP {exc.code}: {detail}") from exc
        except (OSError, json.JSONDecodeError) as exc:
            raise TelegramError(f"{method} failed: {exc}") from exc
        if not isinstance(payload, dict) or not payload.get("ok"):
            raise TelegramError(f"{method} rejected: {str(payload)[:400]}")
        return payload.get("result")

    async def call(self, method: str, params: Optional[dict[str, Any]] = None,
                   timeout: float = 30) -> Any:
        return await asyncio.to_thread(self.request_sync, method, params or {}, timeout)

    def _download(self, file_path: str, target: Path, timeout: float) -> None:
        url = f"{self._base}/file/bot{self._token}/{file_path}"
        try:
            with urllib.request.urlopen(url, timeout=timeout) as response:
                data = response.read(MAX_VOICE_BYTES + 1)
        except (OSError, urllib.error.HTTPError) as exc:
            raise TelegramError(f"voice download failed: {exc}") from exc
        if len(data) > MAX_VOICE_BYTES:
            raise TelegramError("voice note is too large to transcribe")
        target.write_bytes(data)
        target.chmod(0o600)

    async def download(self, file_path: str, target: Path, timeout: float = 120) -> None:
        await asyncio.to_thread(self._download, file_path, target, timeout)


# --- bot state --------------------------------------------------------------


@dataclass
class Queued:
    id: str
    text: str
    reply_to: int


@dataclass
class Voice:
    voice_id: int
    card_id: int
    text: str
    revision: int = 1
    audio: Optional[Path] = None
    prompt_id: Optional[int] = None


@dataclass
class MirrorBot:
    config: Config
    api: TelegramApi
    mirror_on: bool = False
    queue: deque[Queued] = field(default_factory=deque)
    pending: "OrderedDict[str, Queued]" = field(default_factory=OrderedDict)
    voices: dict[int, Voice] = field(default_factory=dict)
    prompts: dict[int, int] = field(default_factory=dict)
    client: Optional[asyncio.StreamWriter] = None
    background: set = field(default_factory=set)
    _sequence: int = 0
    _stopping: bool = False

    # --- helpers ---

    @property
    def connected(self) -> bool:
        return self.client is not None

    def next_id(self) -> str:
        self._sequence += 1
        return f"m{self._sequence}"

    async def send(self, text: str, reply_to: Optional[int] = None,
                   markup: Optional[dict[str, Any]] = None) -> Optional[dict[str, Any]]:
        result: Optional[dict[str, Any]] = None
        chunks = chunk_text(text)
        for index, chunk in enumerate(chunks):
            params: dict[str, Any] = {"chat_id": self.config.chat_id, "text": chunk}
            if reply_to is not None:
                params["reply_parameters"] = {
                    "message_id": reply_to,
                    "allow_sending_without_reply": True,
                }
            if markup is not None and index == len(chunks) - 1:
                params["reply_markup"] = markup
            try:
                result = await self.api.call("sendMessage", params)
            except TelegramError as exc:
                log(str(exc))
                return None
        return result

    async def edit_card(self, message_id: int, text: str,
                        markup: Optional[dict[str, Any]]) -> None:
        params: dict[str, Any] = {
            "chat_id": self.config.chat_id,
            "message_id": message_id,
            "text": text[:TELEGRAM_TEXT_LIMIT],
        }
        params["reply_markup"] = markup if markup is not None else {"inline_keyboard": []}
        try:
            await self.api.call("editMessageText", params)
        except TelegramError as exc:
            log(str(exc))

    async def answer_callback(self, callback_id: str, text: str = "") -> None:
        params: dict[str, Any] = {"callback_query_id": callback_id}
        if text:
            params["text"] = text
        try:
            await self.api.call("answerCallbackQuery", params)
        except TelegramError as exc:
            log(str(exc))

    # --- inbound Telegram -> Pi ---

    def paired_message(self, message: dict[str, Any]) -> bool:
        sender = message.get("from") or {}
        chat = message.get("chat") or {}
        return (
            sender.get("id") == self.config.user_id
            and chat.get("id") == self.config.chat_id
            and chat.get("type") == "private"
        )

    async def handle_update(self, update: dict[str, Any]) -> None:
        message = update.get("message")
        if isinstance(message, dict):
            if not self.paired_message(message):
                return
            await self.handle_message(message)
            return
        callback = update.get("callback_query")
        if isinstance(callback, dict):
            sender = callback.get("from") or {}
            source = callback.get("message") or {}
            chat = source.get("chat") or {}
            if sender.get("id") != self.config.user_id or chat.get("id") != self.config.chat_id:
                return
            await self.handle_callback(callback)

    async def handle_message(self, message: dict[str, Any]) -> None:
        message_id = message.get("message_id")
        text = message.get("text")
        if isinstance(text, str):
            command = mirror_command(text)
            if command:
                await self.send(self.apply_command(command), reply_to=message_id,
                                markup=self.control_markup())
                return
            head = text.strip().split(" ", 1)[0].split("@", 1)[0]
            if head in ("/start", "/help", "/telegram"):
                await self.send(HELP_REPLY, reply_to=message_id)
                return
            reply_to = (message.get("reply_to_message") or {}).get("message_id")
            if isinstance(reply_to, int) and reply_to in self.prompts:
                await self.apply_edit(self.prompts[reply_to], text, message_id)
                return
            if not self.mirror_on:
                await self.send(MIRROR_OFF_REPLY, reply_to=message_id)
                return
            await self.accept_text(text, message_id)
            return
        if isinstance(message.get("voice"), dict):
            if not self.mirror_on:
                await self.send(MIRROR_OFF_REPLY, reply_to=message_id)
                return
            # Transcription runs beside the poll loop so a long voice note
            # never stalls ordinary text, commands, or button taps.
            task = asyncio.create_task(self.handle_voice(message))
            self.background.add(task)
            task.add_done_callback(self.background.discard)
            return
        if not self.mirror_on:
            await self.send(MIRROR_OFF_REPLY, reply_to=message_id)
            return
        await self.send(UNSUPPORTED_REPLY, reply_to=message_id)

    def apply_command(self, command: str) -> str:
        if command == "on":
            self.mirror_on = True
        elif command == "off":
            self.mirror_on = False
        return self.status_text()

    def status_text(self) -> str:
        mirror = "on" if self.mirror_on else "off"
        firstmate = "connected" if self.connected else "not running"
        confirmations = "on" if self.config.confirmations else "off"
        status = f"Mirror is {mirror}. Firstmate is {firstmate}. Confirmations are {confirmations}."
        queued = len(self.queue) + len(self.pending)
        if queued:
            status += f" {queued} message(s) waiting."
        return status

    def control_markup(self) -> dict[str, Any]:
        label = DISABLE_CONFIRMATIONS_LABEL if self.config.confirmations else ENABLE_CONFIRMATIONS_LABEL
        return {"inline_keyboard": [[{"text": label, "callback_data": CONFIRMATIONS_CALLBACK}]]}

    def set_confirmations(self, enabled: bool) -> None:
        self.config.confirmations = enabled
        data = read_config(self.config.home)
        data["confirmations"] = enabled
        try:
            write_config(self.config.home, data)
        except OSError as exc:
            # The choice still applies to this run; only its persistence failed.
            log(f"could not persist the confirmations setting: {exc}")

    async def accept_text(self, text: str, reply_to: int) -> None:
        item = Queued(id=self.next_id(), text=text, reply_to=reply_to)
        self.queue.append(item)
        if not self.connected:
            await self.send(OFFLINE_REPLY, reply_to=reply_to)
        await self.pump()

    async def pump(self) -> None:
        while self.queue and self.client is not None:
            item = self.queue.popleft()
            if not await self.write_frame({"t": "deliver", "id": item.id, "text": item.text}):
                self.queue.appendleft(item)
                return
            self.pending[item.id] = item

    async def on_accepted(self, message_id: str) -> None:
        item = self.pending.pop(message_id, None)
        if item is None:
            return
        # Pending state clears either way: the message reached Pi, so it must
        # never be re-delivered. Only the visible receipt is optional.
        if not self.config.confirmations:
            return
        await self.send(ACCEPTED_REPLY, reply_to=item.reply_to)

    # --- voice ---

    async def handle_voice(self, message: dict[str, Any]) -> None:
        voice_id = int(message["message_id"])
        await self.send(TRANSCRIBING_REPLY, reply_to=voice_id)
        audio = audio_dir(self.config.home) / f"{voice_id}.ogg"
        try:
            file_id = (message.get("voice") or {}).get("file_id")
            info = await self.api.call("getFile", {"file_id": file_id})
            private_dir(audio_dir(self.config.home))
            await self.api.download(str((info or {}).get("file_path", "")), audio)
            transcript = await transcribe(self.config.transcribe_command, audio)
        except TelegramError as exc:
            log(str(exc))
            remove_file(audio)
            await self.send(TRANSCRIBE_FAILED_REPLY, reply_to=voice_id)
            return
        card = await self.send(transcript, reply_to=voice_id, markup=main_markup(voice_id, 1))
        if card is None:
            remove_file(audio)
            return
        self.voices[voice_id] = Voice(
            voice_id=voice_id, card_id=int(card["message_id"]), text=transcript, audio=audio
        )

    async def handle_callback(self, callback: dict[str, Any]) -> None:
        callback_id = str(callback.get("id"))
        data = str(callback.get("data") or "")
        if data == CONFIRMATIONS_CALLBACK:
            await self.answer_callback(callback_id)
            self.set_confirmations(not self.config.confirmations)
            card = callback.get("message") or {}
            message_id = card.get("message_id")
            if isinstance(message_id, int):
                await self.edit_card(message_id, self.status_text(), self.control_markup())
            return
        parsed = parse_callback(data)
        if parsed is None:
            await self.answer_callback(callback_id, "Unsupported button.")
            return
        voice_id, revision, action = parsed
        entry = self.voices.get(voice_id)
        if entry is None:
            await self.answer_callback(callback_id, "This transcript is no longer active.")
            return
        if revision != entry.revision:
            await self.answer_callback(callback_id, "This transcript has already moved on.")
            return
        await self.answer_callback(callback_id)
        if action == "send":
            await self.finish_voice(entry, SENT_FOOTER)
            await self.accept_text(entry.text, entry.voice_id)
            return
        if action == "cancel":
            await self.finish_voice(entry, CANCELLED_FOOTER)
            return
        if action == "edit":
            entry.revision += 1
            await self.edit_card(entry.card_id, entry.text, edit_markup(entry))
            prompt = await self.send(EDIT_PROMPT, reply_to=entry.card_id, markup={
                "force_reply": True,
                "input_field_placeholder": "Corrected text",
            })
            if prompt is not None:
                entry.prompt_id = int(prompt["message_id"])
                self.prompts[entry.prompt_id] = entry.voice_id
            return
        if action == "back":
            entry.revision += 1
            self.clear_prompt(entry)
            await self.edit_card(entry.card_id, entry.text, main_markup(entry.voice_id, entry.revision))

    async def apply_edit(self, voice_id: int, text: str, message_id: int) -> None:
        entry = self.voices.get(voice_id)
        if entry is None:
            await self.send("That transcript is no longer active.", reply_to=message_id)
            return
        entry.text = text
        entry.revision += 1
        self.clear_prompt(entry)
        await self.edit_card(entry.card_id, entry.text, main_markup(entry.voice_id, entry.revision))

    async def finish_voice(self, entry: Voice, footer: str) -> None:
        self.clear_prompt(entry)
        self.voices.pop(entry.voice_id, None)
        remove_file(entry.audio)
        entry.audio = None
        await self.edit_card(entry.card_id, f"{entry.text}\n\n{footer}", None)

    def clear_prompt(self, entry: Voice) -> None:
        if entry.prompt_id is not None:
            self.prompts.pop(entry.prompt_id, None)
            entry.prompt_id = None

    # --- Pi extension socket ---

    async def write_frame(self, frame: dict[str, Any]) -> bool:
        writer = self.client
        if writer is None:
            return False
        try:
            writer.write((json.dumps(frame) + "\n").encode("utf-8"))
            await writer.drain()
            return True
        except (OSError, ConnectionError):
            await self.drop_client(writer)
            return False

    async def drop_client(self, writer: asyncio.StreamWriter) -> None:
        if self.client is not writer:
            return
        self.client = None
        # Anything delivered but not yet confirmed goes back to the front of the
        # queue in order. A session that vanished between accepting a message
        # and confirming it can therefore see that one message twice, which is
        # the deliberate trade for keeping the queue in memory only.
        for item in reversed(list(self.pending.values())):
            self.queue.appendleft(item)
        self.pending.clear()
        try:
            writer.close()
        except OSError:
            pass

    async def handle_client(self, reader: asyncio.StreamReader,
                            writer: asyncio.StreamWriter) -> None:
        previous = self.client
        if previous is not None:
            await self.drop_client(previous)
        self.client = writer
        await self.pump()
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    frame = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if isinstance(frame, dict):
                    await self.handle_frame(frame)
        except (OSError, ConnectionError):
            pass
        finally:
            await self.drop_client(writer)

    async def handle_frame(self, frame: dict[str, Any]) -> None:
        kind = frame.get("t")
        if kind == "hello":
            await self.pump()
            return
        if kind == "accepted":
            await self.on_accepted(str(frame.get("id")))
            return
        if kind == "terminal":
            if self.mirror_on and isinstance(frame.get("text"), str):
                await self.send(f"{TERMINAL_LABEL}\n{frame['text']}")
            return
        if kind == "reply":
            # Never threaded. Pi batches back-to-back submissions into one run,
            # so a reply cannot be attributed to one source message; guessing a
            # target would attach answers to the wrong message. Transport
            # statuses below still reply to the exact message they describe,
            # because the bot knows those precisely.
            if self.mirror_on and isinstance(frame.get("text"), str):
                await self.send(frame["text"])
            return
        if kind == "command":
            command = str(frame.get("command"))
            text = self.apply_command(command) if command in MIRROR_COMMANDS else (
                f"Unknown command {command!r}."
            )
            await self.write_frame({"t": "command_result", "id": frame.get("id"), "text": text})

    # --- run loop ---

    async def register_menu(self) -> None:
        """Publish the menu aliases, scoped to the paired chat.

        A failure here costs the menu, never the mirror, so it is logged and the
        bot keeps running: both command forms still work by typing them.
        """
        try:
            await self.api.call("setMyCommands", {
                "commands": MENU_COMMANDS,
                "scope": {"type": "chat", "chat_id": self.config.chat_id},
            })
        except TelegramError as exc:
            log(f"could not publish the command menu: {exc}")

    async def poll(self) -> None:
        offset: Optional[int] = None
        while not self._stopping:
            params: dict[str, Any] = {
                "timeout": POLL_TIMEOUT,
                "allowed_updates": ["message", "callback_query"],
            }
            if offset is not None:
                params["offset"] = offset
            try:
                updates = await self.api.call("getUpdates", params, timeout=POLL_TIMEOUT + 15)
            except TelegramError as exc:
                log(str(exc))
                await asyncio.sleep(3)
                continue
            for update in updates or []:
                if not isinstance(update, dict):
                    continue
                offset = int(update.get("update_id", 0)) + 1
                try:
                    await self.handle_update(update)
                except TelegramError as exc:
                    log(str(exc))

    async def run(self) -> None:
        path = socket_path(self.config.home)
        private_dir(self.config.home)
        clear_audio(self.config.home)
        remove_file(path)
        server = await asyncio.start_unix_server(self.handle_client, path=str(path))
        os.chmod(path, 0o600)
        log(f"listening on {path}")
        loop = asyncio.get_running_loop()
        stopping = asyncio.Event()
        for name in (signal.SIGTERM, signal.SIGINT):
            with contextlib.suppress(NotImplementedError, RuntimeError):
                loop.add_signal_handler(name, stopping.set)
        poller = asyncio.create_task(self.poll())
        waiter = asyncio.create_task(stopping.wait())
        menu = asyncio.create_task(self.register_menu())
        self.background.add(menu)
        menu.add_done_callback(self.background.discard)
        try:
            async with server:
                await asyncio.wait({poller, waiter}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            self._stopping = True
            for task in (poller, waiter, *list(self.background)):
                task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await asyncio.gather(poller, waiter, *list(self.background),
                                     return_exceptions=True)
            remove_file(path)
            clear_audio(self.config.home)


# --- pure helpers -----------------------------------------------------------


def chunk_text(text: str) -> list[str]:
    body = text if text.strip() else "(empty message)"
    return [body[i:i + TELEGRAM_TEXT_LIMIT] for i in range(0, len(body), TELEGRAM_TEXT_LIMIT)] or [body]


def mirror_command(text: str) -> Optional[str]:
    parts = text.strip().split()
    if not parts:
        return None
    head = parts[0].split("@", 1)[0]
    if head in MIRROR_ALIASES:
        return MIRROR_ALIASES[head]
    if len(parts) != 2 or head != "/telegram" or parts[1] not in MIRROR_COMMANDS:
        return None
    return parts[1]


def main_markup(voice_id: int, revision: int) -> dict[str, Any]:
    return {
        "inline_keyboard": [
            [{"text": "Send to Firstmate", "callback_data": f"v:{voice_id}:{revision}:send"}],
            [
                {"text": "Edit", "callback_data": f"v:{voice_id}:{revision}:edit"},
                {"text": "Cancel", "callback_data": f"v:{voice_id}:{revision}:cancel"},
            ],
        ]
    }


def edit_markup(entry: Voice) -> dict[str, Any]:
    row: list[dict[str, Any]] = []
    if len(entry.text) <= COPY_TEXT_LIMIT:
        row.append({"text": "Copy text", "copy_text": {"text": entry.text}})
    row.append({"text": "Back", "callback_data": f"v:{entry.voice_id}:{entry.revision}:back"})
    return {"inline_keyboard": [row]}


def parse_callback(data: str) -> Optional[tuple[int, int, str]]:
    parts = data.split(":")
    if len(parts) != 4 or parts[0] != "v":
        return None
    if parts[3] not in ("send", "edit", "cancel", "back"):
        return None
    try:
        return int(parts[1]), int(parts[2]), parts[3]
    except ValueError:
        return None


def remove_file(path: Optional[Path]) -> None:
    if path is None:
        return
    try:
        path.unlink()
    except OSError:
        pass


def clear_audio(home: Path) -> None:
    directory = audio_dir(home)
    if not directory.is_dir():
        return
    for entry in directory.iterdir():
        if entry.is_file():
            remove_file(entry)


def transcribe_argv(command: str, audio: Path) -> list[str]:
    parts = shlex.split(command)
    if not parts:
        raise TelegramError("transcribe_command is empty")
    if any("{audio}" in part for part in parts):
        return [part.replace("{audio}", str(audio)) for part in parts]
    return [*parts, str(audio)]


def run_transcribe(command: str, audio: Path) -> str:
    argv = transcribe_argv(command, audio)
    try:
        completed = subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=TRANSCRIBE_TIMEOUT, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise TelegramError(f"transcription command failed: {exc}") from exc
    if completed.returncode != 0:
        detail = (completed.stderr or "").strip()[:200]
        raise TelegramError(f"transcription command exited {completed.returncode}: {detail}")
    transcript = (completed.stdout or "").strip()
    if not transcript:
        raise TelegramError("transcription produced no text")
    return transcript


async def transcribe(command: str, audio: Path) -> str:
    return await asyncio.to_thread(run_transcribe, command, audio)


# --- service and CLI --------------------------------------------------------


def is_wsl() -> bool:
    assume = os.environ.get("FM_TELEGRAM_ASSUME_WSL")
    if assume in ("0", "1"):
        return assume == "1"
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        return "microsoft" in Path("/proc/sys/kernel/osrelease").read_text(encoding="utf-8").lower()
    except OSError:
        return False


def unit_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "systemd" / "user" / SERVICE_NAME


def unit_text(home: Path) -> str:
    script = Path(__file__).resolve()
    return (
        "[Unit]\n"
        "Description=Firstmate Telegram terminal mirror\n"
        "After=network-online.target\n"
        "\n"
        "[Service]\n"
        "Type=simple\n"
        f"Environment=FM_TELEGRAM_DIR={shlex.quote(str(home))}\n"
        f"ExecStart={sys.executable} {shlex.quote(str(script))} run\n"
        "Restart=always\n"
        "RestartSec=5\n"
        "\n"
        "[Install]\n"
        "WantedBy=default.target\n"
    )


def systemctl(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["systemctl", "--user", *arguments], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, check=False,
    )


def require_wsl() -> None:
    if not is_wsl():
        raise TelegramError("the Telegram mirror service is WSL only; this host is not WSL")


def install_service(home: Path) -> int:
    require_wsl()
    target = unit_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(unit_text(home), encoding="utf-8")
    for arguments in (("daemon-reload",), ("enable", "--now", SERVICE_NAME)):
        result = systemctl(*arguments)
        if result.returncode != 0:
            print(result.stdout, end="")
            raise TelegramError(f"systemctl --user {' '.join(arguments)} failed")
    print(f"installed {target} and started {SERVICE_NAME}")
    return 0


def uninstall_service() -> int:
    require_wsl()
    systemctl("disable", "--now", SERVICE_NAME)
    target = unit_path()
    remove_file(target)
    systemctl("daemon-reload")
    print(f"removed {target}")
    return 0


def pair(home: Path) -> int:
    token = os.environ.get("TELEGRAM_BOT_TOKEN") or read_env(home).get("TELEGRAM_BOT_TOKEN", "")
    if not token:
        raise TelegramError(f"no TELEGRAM_BOT_TOKEN in {env_file(home)}")
    base = os.environ.get("FM_TELEGRAM_API_BASE") or DEFAULT_API_BASE
    api = TelegramApi(base, token)
    print("send any message to the bot from the Telegram account you want paired...")
    offset: Optional[int] = None
    deadline = time.time() + 300
    while time.time() < deadline:
        params: dict[str, Any] = {"timeout": 10, "allowed_updates": ["message"]}
        if offset is not None:
            params["offset"] = offset
        result = api.request_sync("getUpdates", params, 30)
        for update in result or []:
            offset = int(update.get("update_id", 0)) + 1
            message = update.get("message") or {}
            chat = message.get("chat") or {}
            sender = message.get("from") or {}
            if chat.get("type") != "private":
                continue
            data = read_config(home)
            data["user_id"] = int(sender["id"])
            data["chat_id"] = int(chat["id"])
            data.setdefault("transcribe_command", DEFAULT_TRANSCRIBE_COMMAND)
            write_config(home, data)
            print(f"paired user {data['user_id']} in chat {data['chat_id']}")
            return 0
    raise TelegramError("no private message arrived within 5 minutes")


def status(home: Path) -> int:
    data = read_config(home)
    token = "present" if (os.environ.get("TELEGRAM_BOT_TOKEN")
                          or read_env(home).get("TELEGRAM_BOT_TOKEN")) else "missing"
    print(f"home: {home}")
    print(f"token: {token}")
    print(f"paired user: {data.get('user_id', 'none')}")
    print(f"paired chat: {data.get('chat_id', 'none')}")
    print(f"transcribe command: {data.get('transcribe_command', DEFAULT_TRANSCRIBE_COMMAND)}")
    print(f"socket: {'present' if socket_path(home).exists() else 'absent'}")
    result = systemctl("is-active", SERVICE_NAME)
    print(f"service: {result.stdout.strip() or 'unknown'}")
    return 0


def run(home: Path) -> int:
    config = load_config(home)
    bot = MirrorBot(config=config, api=TelegramApi(config.api_base, config.token))
    try:
        asyncio.run(bot.run())
    except KeyboardInterrupt:
        pass
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="fm-telegram.py",
        description="Firstmate's Telegram terminal mirror bot (WSL only).",
        epilog=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "command",
        choices=["run", "pair", "status", "service-unit", "install-service", "uninstall-service"],
    )
    args = parser.parse_args(argv)
    home = private_dir(home_dir())
    if args.command == "run":
        return run(home)
    if args.command == "pair":
        return pair(home)
    if args.command == "status":
        return status(home)
    if args.command == "service-unit":
        print(unit_text(home), end="")
        return 0
    if args.command == "install-service":
        return install_service(home)
    return uninstall_service()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except TelegramError as error:
        log(str(error))
        sys.exit(1)
