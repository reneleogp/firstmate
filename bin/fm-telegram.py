#!/usr/bin/env python3
"""Small, private Telegram transport for one Firstmate home.

The service deliberately owns transport and queue durability only.  It does not
interpret requests, choose actions, or authorize Firstmate operations.
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

SERVICE_NAME = "firstmate-telegram.service"
CONFIG_NAME = "telegram.json"
MAX_SEEN = 4096
MAX_HANDLED = 4096
MAX_INBOX = 256
MAX_TEXT = 12000
MAX_TRANSCRIPT_UNITS = 4096
MAX_VOICE_BYTES = 10 * 1024 * 1024
MAX_VOICE_SECONDS = 120
INBOX_TTL = 7 * 24 * 60 * 60
PENDING_TTL = 10 * 60
POLL_TIMEOUT = 30


class TelegramError(RuntimeError):
    def __init__(self, message: str, delivery_unknown: bool = False):
        super().__init__(message)
        self.delivery_unknown = delivery_unknown


def die(message: str) -> int:
    print("fm-telegram: " + message, file=sys.stderr)
    return 1


def home_from(args: argparse.Namespace) -> Path:
    value = getattr(args, "home", None) or os.environ.get("FM_HOME")
    if not value:
        raise TelegramError("FM_HOME or --home is required")
    return Path(value).expanduser().resolve()


def private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def private_file(path: Path) -> None:
    os.chmod(path, 0o600)


def atomic_bytes(path: Path, data: bytes, mode: int = 0o600) -> None:
    private_dir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        private_file(path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def atomic_json(path: Path, value: Any) -> None:
    atomic_bytes(path, (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode())


def read_json(path: Path, default: Any = None) -> Any:
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def env_value(home: Path, key: str) -> Optional[str]:
    dotenv = home / ".env"
    try:
        lines = dotenv.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name.strip() == key:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            return value
    return None


def token_for(home: Path) -> str:
    token = env_value(home, "FM_TELEGRAM_BOT_TOKEN")
    if not token:
        raise TelegramError("FM_TELEGRAM_BOT_TOKEN is not configured in this home")
    return token


def config_path(home: Path) -> Path:
    return home / "config" / CONFIG_NAME


def state_dir(home: Path) -> Path:
    path = home / "state" / "telegram"
    private_dir(path)
    return path


def load_config(home: Path) -> Dict[str, Any]:
    path = config_path(home)
    config = read_json(path)
    if not isinstance(config, dict):
        raise TelegramError("Telegram pairing is not configured")
    for key in ("user_id", "chat_id", "bot_id"):
        if not strict_int(config.get(key)):
            raise TelegramError("Telegram pairing is incomplete")
    try:
        mode = path.stat().st_mode & 0o777
        if mode != 0o600:
            raise TelegramError("Telegram pairing config must be mode 0600")
    except FileNotFoundError as exc:
        raise TelegramError("Telegram pairing is not configured") from exc
    return config


def api_base(home: Path, config: Optional[Dict[str, Any]] = None) -> str:
    value = os.environ.get("FM_TELEGRAM_API_BASE")
    if value is None and config:
        value = str(config.get("api_base", ""))
    return (value or "https://api.telegram.org").rstrip("/")


def api_call(home: Path, method: str, params: Optional[Dict[str, Any]] = None,
             config: Optional[Dict[str, Any]] = None) -> Any:
    token = token_for(home)
    body = json.dumps(params or {}, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        f"{api_base(home, config)}/bot{token}/{method}",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        raise TelegramError(f"Telegram request failed for {method}") from exc
    except (OSError, urllib.error.URLError) as exc:
        raise TelegramError(f"Telegram request failed for {method}", delivery_unknown=True) from exc
    try:
        envelope = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise TelegramError(f"Telegram returned invalid data for {method}", delivery_unknown=True) from exc
    if not isinstance(envelope, dict) or envelope.get("ok") is not True:
        raise TelegramError(f"Telegram rejected {method}")
    return envelope.get("result")


def download_file(home: Path, file_path: str, target: Path, config: Dict[str, Any]) -> None:
    if not isinstance(file_path, str) or not file_path or "\x00" in file_path:
        raise TelegramError("Telegram returned an invalid audio path")
    token = token_for(home)
    request = urllib.request.Request(
        f"{api_base(home, config)}/file/bot{token}/{file_path}", method="GET"
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response, target.open("wb") as stream:
            total = 0
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_VOICE_BYTES:
                    raise TelegramError("voice note exceeds the size limit")
                stream.write(chunk)
    except (OSError, urllib.error.URLError) as exc:
        raise TelegramError("Telegram audio download failed") from exc
    private_file(target)


def systemctl(*arguments: str, check: bool = True) -> subprocess.CompletedProcess:
    command = os.environ.get("FM_TELEGRAM_SYSTEMCTL", "systemctl")
    result = subprocess.run([command, "--user", *arguments], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise TelegramError("systemd user service command failed")
    return result


def primary_running(home: Path) -> bool:
    lock = home / "state" / ".lock"
    try:
        value = lock.read_text(encoding="utf-8").strip()
        pid = int(value)
        if pid <= 0:
            return False
    except (OSError, ValueError):
        return False
    library = Path(__file__).resolve().parent / "fm-session-lock-lib.sh"
    result = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; fm_harness_pid_alive "$2"',
         "fm-telegram", str(library), str(pid)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def watcher_running(home: Path) -> bool:
    root = Path(__file__).resolve().parent
    library = root / "fm-wake-lib.sh"
    watcher = root / "fm-watch.sh"
    environment = os.environ.copy()
    environment["FM_HOME"] = str(home)
    environment["FM_STATE_OVERRIDE"] = str(home / "state")
    result = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; fm_watcher_healthy "$2" "$3" "${FM_GUARD_GRACE:-300}" "$4"',
         "fm-telegram", str(library), str(home / "state"), str(watcher), str(home)],
        env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def now() -> int:
    return int(time.time())


def strict_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def request_dirs(home: Path) -> Tuple[Path, Path]:
    root = state_dir(home)
    inbox = root / "inbox"
    handled = root / "handled"
    private_dir(inbox)
    private_dir(handled)
    return inbox, handled


def safe_id(value: str) -> bool:
    return bool(value) and all(ch.isalnum() or ch in "._-" for ch in value)


def request_path(home: Path, request_id: str) -> Optional[Path]:
    if not safe_id(request_id):
        return None
    inbox, handled = request_dirs(home)
    for directory in (inbox, handled):
        path = directory / f"{request_id}.json"
        if path.is_file() and not path.is_symlink():
            return path
    return None


def state_lock(home: Path) -> Path:
    path = state_dir(home) / ".lock"
    if not path.exists():
        atomic_bytes(path, b"", 0o600)
    private_file(path)
    return path


class FileLock:
    def __init__(self, path: Path):
        self.path = path
        self.stream = None

    def __enter__(self) -> "FileLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = self.path.open("a+")
        os.chmod(self.path, 0o600)
        fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        assert self.stream is not None
        fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
        self.stream.close()


def seen_path(home: Path) -> Path:
    return state_dir(home) / "seen.json"


def append_safe_wake(home: Path, request_id: str) -> None:
    root = Path(__file__).resolve().parent
    wake_lib = root / "fm-wake-lib.sh"
    script = '. "$1"; fm_wake_append check "telegram:$2" "telegram $2"'
    environment = os.environ.copy()
    environment["FM_HOME"] = str(home)
    environment["FM_STATE_OVERRIDE"] = str(home / "state")
    result = subprocess.run(["/bin/bash", "-c", script, "fm-telegram", str(wake_lib), request_id],
                            env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        raise TelegramError("safe Telegram wake could not be recorded")


def consume_safe_wakes(home: Path, request_ids: Optional[List[str]] = None) -> None:
    for request_id in request_ids or [""]:
        if request_id and not safe_id(request_id):
            continue
        library = Path(__file__).resolve().parent / "fm-wake-lib.sh"
        script = r'''
. "$1"
request_id=$2
fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
tmp=$(umask 077; mktemp "$STATE/.wake-queue.telegram.XXXXXX") || {
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"; exit 1;
}
if [ -f "$FM_WAKE_QUEUE" ]; then
  if [ -n "$request_id" ]; then
    awk -F '\t' -v key="telegram:$request_id" 'NF < 4 || $4 != key' "$FM_WAKE_QUEUE" > "$tmp"
  else
    awk -F '\t' 'NF < 4 || $4 !~ /^telegram:/' "$FM_WAKE_QUEUE" > "$tmp"
  fi
  status=$?
  if [ "$status" -eq 0 ]; then
    mv -f -- "$tmp" "$FM_WAKE_QUEUE" || status=$?
  fi
  if [ "$status" -ne 0 ]; then
    rm -f -- "$tmp"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    exit "$status"
  fi
else
  rm -f -- "$tmp"
fi
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
if [ -n "$request_id" ]; then
  rm -f -- "$STATE/.seen-telegram-$request_id"
else
  find "$STATE" -maxdepth 1 -name '.seen-telegram-*' -type f -delete 2>/dev/null || true
fi
'''
        environment = os.environ.copy()
        environment["FM_HOME"] = str(home)
        environment["FM_STATE_OVERRIDE"] = str(home / "state")
        result = subprocess.run(
            ["/bin/bash", "-c", script, "fm-telegram", str(library), request_id],
            env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            raise TelegramError("safe Telegram wakes could not be cleaned")


def active_path(home: Path) -> Path:
    return state_dir(home) / "active.json"


def active_record(home: Path) -> Optional[Dict[str, Any]]:
    active = read_json(active_path(home))
    if not isinstance(active, dict) or not isinstance(active.get("request_id"), str):
        return None
    if not safe_id(str(active["request_id"])):
        return None
    work_id = active.get("work_id")
    if work_id is not None and (not isinstance(work_id, str) or not safe_id(work_id)):
        return None
    return active


def active_request_id(home: Path) -> Optional[str]:
    active = active_record(home)
    return str(active["request_id"]) if active is not None else None


def closing_path(home: Path) -> Path:
    return state_dir(home) / "closing.json"


def request_order_key(path: Path) -> Tuple[int, int, int, str]:
    record = read_json(path, {})
    if not isinstance(record, dict):
        return (-1, -1, -1, path.stem)
    created = record.get("created_at")
    update_id = record.get("update_id")
    message_id = record.get("message_id")
    request_id = record.get("request_id")
    return (
        created if strict_int(created) else -1,
        update_id if strict_int(update_id) else -1,
        message_id if strict_int(message_id) else -1,
        request_id if isinstance(request_id, str) else path.stem,
    )


def _sync_request_wakes_locked(home: Path) -> None:
    inbox, _handled = request_dirs(home)
    paths = sorted(inbox.glob("*.json"), key=request_order_key)
    active = active_request_id(home)
    if active is not None:
        continuation_paths = []
        for path in paths:
            record = read_json(path, {})
            if isinstance(record, dict) and record.get("continuation_of") == active:
                continuation_paths.append(path)
        paths = continuation_paths
    consume_safe_wakes(home)
    if paths:
        append_safe_wake(home, paths[0].stem)


def sync_request_wakes(home: Path) -> None:
    with FileLock(state_lock(home)):
        _sync_request_wakes_locked(home)


def bounded_cleanup(home: Path) -> None:
    with FileLock(state_lock(home)):
        inbox, handled = request_dirs(home)
        active = active_request_id(home)
        cutoff = now() - INBOX_TTL
        inbox_files = sorted(inbox.glob("*.json"), key=request_order_key, reverse=True)
        for index, path in enumerate(inbox_files):
            record = read_json(path, {})
            created = record.get("created_at", 0) if isinstance(record, dict) else 0
            if index >= MAX_INBOX or not strict_int(created) or created < cutoff:
                try:
                    consume_safe_wakes(home, [path.stem])
                    path.unlink()
                except (OSError, TelegramError):
                    pass
        handled_files = sorted(
            (path for path in handled.glob("*.json") if path.stem != active),
            key=lambda p: p.stat().st_mtime, reverse=True,
        )
        for path in handled_files[MAX_HANDLED:]:
            try:
                path.unlink()
            except OSError:
                pass
        pending = state_dir(home) / "pending.json"
        data = read_json(pending)
        try:
            expired = (isinstance(data, dict)
                       and now() - int(data.get("created_at", 0)) >= PENDING_TTL)
        except (TypeError, ValueError):
            expired = True
        if expired:
            remove_pending(home, data if isinstance(data, dict) else None)
        _sync_request_wakes_locked(home)


def deterministic_request_id(source: str, update_id: int, message_id: int) -> str:
    if source not in {"text", "voice"} or update_id < 0 or message_id < 0:
        raise TelegramError("request identifiers are invalid")
    return f"tg-{source}-u{update_id}-m{message_id}"


def _queue_request_locked(home: Path, text: str, chat_id: int, message_id: int,
                          update_id: Optional[int], source: str, confirmed: bool,
                          attach_to_active: bool) -> str:
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
        raise TelegramError("request text is empty or too long")
    if not strict_int(update_id) or not strict_int(message_id):
        raise TelegramError("request identifiers are invalid")
    request_id = deterministic_request_id(source, update_id, message_id)
    inbox, handled = request_dirs(home)
    path = inbox / f"{request_id}.json"
    existing_path = path if path.is_file() else handled / path.name
    existing = read_json(existing_path)
    if isinstance(existing, dict):
        if existing.get("request_id") != request_id or existing.get("origin") != "telegram":
            raise TelegramError("request identifier collision")
        return request_id
    continuation_of = None
    if attach_to_active:
        active = active_record(home)
        closing = read_json(closing_path(home), {})
        if (active is not None
                and (not isinstance(closing, dict)
                     or closing.get("request_id") != active.get("request_id"))):
            continuation_of = str(active["request_id"])
    record = {
        "request_id": request_id,
        "origin": "telegram",
        "source": source,
        "confirmed": bool(confirmed),
        "text": text,
        "chat_id": chat_id,
        "message_id": message_id,
        "update_id": update_id,
        "created_at": now(),
        "status": "queued",
        "wake_recorded": False,
        "receipt_text": transport_reply(home),
        "receipt_status": "pending",
    }
    if continuation_of is not None:
        record["continuation_of"] = continuation_of
    atomic_json(path, record)
    return request_id


def queue_request(home: Path, text: str, chat_id: int, message_id: int,
                  update_id: Optional[int], source: str = "text",
                  confirmed: bool = False, attach_to_active: bool = False) -> str:
    with FileLock(state_lock(home)):
        return _queue_request_locked(
            home, text, chat_id, message_id, update_id, source, confirmed, attach_to_active
        )


def _update_request_record_locked(home: Path, request_id: str,
                                  **changes: Any) -> Dict[str, Any]:
    path = request_path(home, request_id)
    if path is None:
        raise TelegramError("request not found during reconciliation")
    record = read_json(path)
    if not isinstance(record, dict) or record.get("request_id") != request_id:
        raise TelegramError("request is malformed during reconciliation")
    record.update(changes)
    atomic_json(path, record)
    return record


def update_request_record(home: Path, request_id: str, **changes: Any) -> Dict[str, Any]:
    with FileLock(state_lock(home)):
        return _update_request_record_locked(home, request_id, **changes)


def reconcile_request(home: Path, request_id: str) -> bool:
    with FileLock(state_lock(home)):
        path = request_path(home, request_id)
        if path is None:
            return False
        record = read_json(path)
        if not isinstance(record, dict) or record.get("origin") != "telegram":
            return False
        if path.parent.name == "inbox":
            _sync_request_wakes_locked(home)
            if record.get("wake_recorded") is not True:
                record = _update_request_record_locked(home, request_id, wake_recorded=True)
        receipt_status = record.get("receipt_status")
        if receipt_status == "sent":
            return True
        receipt = record.get("receipt_text")
        chat_id = record.get("chat_id")
        attempts = record.get("receipt_attempts", 0)
        if (receipt_status not in {"pending", "delivery_unknown"}
                or not isinstance(receipt, str) or not strict_int(chat_id)
                or not strict_int(attempts) or attempts < 0):
            raise TelegramError("request receipt state is malformed")
        _update_request_record_locked(
            home,
            request_id,
            receipt_status="delivery_unknown",
            receipt_attempts=min(attempts + 1, 65535),
            receipt_attempted_at=now(),
        )
    try:
        send_text(home, chat_id, receipt)
    except TelegramError as exc:
        if not exc.delivery_unknown:
            update_request_record(home, request_id, receipt_status="pending")
        return False
    update_request_record(home, request_id, receipt_status="sent", receipt_sent_at=now())
    return True


def reconcile_requests(home: Path) -> None:
    inbox, handled = request_dirs(home)
    paths = list(inbox.glob("*.json")) + list(handled.glob("*.json"))
    for path in sorted(paths, key=request_order_key):
        record = read_json(path)
        if not isinstance(record, dict) or not isinstance(record.get("request_id"), str):
            continue
        try:
            reconcile_request(home, str(record["request_id"]))
        except TelegramError:
            continue


def transport_reply(home: Path) -> str:
    if primary_running(home):
        return "Message received."
    return "Message received and queued. It will be processed when Firstmate starts."


def send_text(home: Path, chat_id: int, text: str, markup: Optional[Dict[str, Any]] = None) -> Any:
    params: Dict[str, Any] = {"chat_id": chat_id, "text": text}
    if markup is not None:
        params["reply_markup"] = markup
    return api_call(home, "sendMessage", params)


def answer_callback(home: Path, callback_id: str) -> None:
    if isinstance(callback_id, str) and callback_id:
        try:
            api_call(home, "answerCallbackQuery", {"callback_query_id": callback_id})
        except TelegramError:
            pass


def pending_path(home: Path) -> Path:
    return state_dir(home) / "pending.json"


def callback_history_path(home: Path) -> Path:
    return state_dir(home) / "callback-actions.json"


def callback_completion_key(pending_id: str, token: str) -> str:
    return f"{pending_id}:{token}"


def completed_callback_locked(home: Path, pending_id: str, token: str) -> bool:
    history = read_json(callback_history_path(home), [])
    key = callback_completion_key(pending_id, token)
    return isinstance(history, list) and key in history


def remember_callback_locked(home: Path, pending_id: str, token: str) -> None:
    history = read_json(callback_history_path(home), [])
    values = [value for value in history if isinstance(value, str)] if isinstance(history, list) else []
    key = callback_completion_key(pending_id, token)
    if key not in values:
        values.append(key)
    atomic_json(callback_history_path(home), values[-MAX_SEEN:])


def remove_audio(data: Dict[str, Any]) -> None:
    value = data.get("audio_path")
    if not isinstance(value, str):
        return
    path = Path(value)
    try:
        path.resolve().relative_to(Path("/dev/shm").resolve())
    except (OSError, ValueError):
        return
    if path.name.startswith("firstmate-telegram-"):
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def remove_pending(home: Path, data: Optional[Dict[str, Any]] = None) -> None:
    if data is None:
        data = read_json(pending_path(home), {})
    if isinstance(data, dict):
        remove_audio(data)
    try:
        pending_path(home).unlink()
    except FileNotFoundError:
        pass


def save_pending(home: Path, data: Dict[str, Any]) -> None:
    atomic_json(pending_path(home), data)


def command_for(config: Dict[str, Any], kind: str) -> str:
    env_key = "FM_TELEGRAM_PARAKEET_CMD" if kind == "parakeet" else "FM_TELEGRAM_WHISPER_CMD"
    value = os.environ.get(env_key)
    if value is None:
        value = config.get("parakeet_command" if kind == "parakeet" else "whisper_command")
    if not value:
        value = "parakeet-tdt-0.6b-v3" if kind == "parakeet" else "whisper-small-q8"
    return str(value)


def transcribe(home: Path, config: Dict[str, Any], audio: Path, kind: str) -> str:
    parts = shlex.split(command_for(config, kind))
    if not parts:
        raise TelegramError("voice transcription command is empty")
    if any("{audio}" in part for part in parts):
        parts = [part.replace("{audio}", str(audio)) for part in parts]
    else:
        parts.append(str(audio))
    try:
        completed = subprocess.run(parts, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, timeout=180, check=True)
    except (OSError, subprocess.SubprocessError) as exc:
        raise TelegramError("voice transcription failed") from exc
    transcript = completed.stdout.strip()
    units = len(transcript.encode("utf-16-le")) // 2
    if not transcript or units > MAX_TRANSCRIPT_UNITS:
        raise TelegramError("voice transcription was empty or too long")
    return transcript


def confirmation_markup(request_id: str, revision: int) -> Dict[str, Any]:
    suffix = f"{request_id}:{revision}"
    return {"inline_keyboard": [[
        {"text": "Send to Firstmate", "callback_data": f"send:{suffix}"},
        {"text": "Edit", "callback_data": f"edit:{suffix}"},
    ], [
        {"text": "Retry with Whisper", "callback_data": f"retry:{suffix}"},
        {"text": "Cancel", "callback_data": f"cancel:{suffix}"},
    ]]}


def show_confirmation(home: Path, config: Dict[str, Any], pending: Dict[str, Any]) -> None:
    text = str(pending["text"])
    revision = pending.get("revision")
    if not strict_int(revision) or revision <= 0:
        raise TelegramError("voice confirmation revision is invalid")
    if len(text.encode("utf-16-le")) // 2 > MAX_TRANSCRIPT_UNITS:
        raise TelegramError("voice transcript exceeds Telegram's message limit")
    if pending.get("heading_sent") is not True:
        send_text(home, int(pending["chat_id"]), "I heard this:")
        pending["heading_sent"] = True
        save_pending(home, pending)
    if pending.get("transcript_sent") is not True:
        send_text(home, int(pending["chat_id"]), text,
                  confirmation_markup(str(pending["pending_id"]), revision))
        pending["transcript_sent"] = True
        save_pending(home, pending)


def complete_retry(home: Path, config: Dict[str, Any], pending: Dict[str, Any]) -> bool:
    try:
        transcript = transcribe(home, config, Path(str(pending["audio_path"])), "whisper")
        revision = pending.get("revision")
        if not strict_int(revision) or revision <= 0:
            raise TelegramError("voice confirmation revision is invalid")
        pending["text"] = transcript
        pending["mode"] = "confirm"
        pending["revision"] = revision + 1
        pending["heading_sent"] = False
        pending["transcript_sent"] = False
        retry_token = pending.pop("retry_token", None)
        save_pending(home, pending)
        if isinstance(retry_token, str) and isinstance(pending.get("pending_id"), str):
            remember_callback_locked(home, str(pending["pending_id"]), retry_token)
        show_confirmation(home, config, pending)
        return True
    except (TelegramError, OSError, KeyError, TypeError, ValueError):
        pending["mode"] = "confirm"
        completed = pending.get("completed_actions", [])
        token = pending.get("retry_token")
        if isinstance(completed, list) and isinstance(token, str):
            pending["completed_actions"] = [value for value in completed if value != token]
        pending.pop("retry_token", None)
        save_pending(home, pending)
        return False


def reconcile_pending(home: Path, config: Dict[str, Any]) -> None:
    pending = read_json(pending_path(home))
    if not isinstance(pending, dict):
        return
    try:
        if pending.get("mode") == "transcribing":
            remove_pending(home, pending)
        elif pending.get("mode") == "retry":
            complete_retry(home, config, pending)
        elif pending.get("mode") == "confirm":
            show_confirmation(home, config, pending)
        elif pending.get("mode") == "edit" and pending.get("edit_prompt_sent") is not True:
            send_text(home, int(config["chat_id"]), "Reply with the corrected text.")
            pending["edit_prompt_sent"] = True
            save_pending(home, pending)
    except (TelegramError, KeyError, TypeError, ValueError):
        return


def pinned_message(config: Dict[str, Any], message: Any) -> Optional[Tuple[Dict[str, Any], Dict[str, Any]]]:
    if not isinstance(message, dict):
        return None
    chat = message.get("chat")
    sender = message.get("from")
    if not isinstance(chat, dict) or not isinstance(sender, dict):
        return None
    chat_id = chat.get("id")
    sender_id = sender.get("id")
    if (chat.get("type") != "private" or not strict_int(chat_id)
            or chat_id != config.get("chat_id")):
        return None
    if not strict_int(sender_id) or sender_id != config.get("user_id"):
        return None
    if not strict_int(message.get("message_id")):
        return None
    return message, chat


def handle_text(home: Path, config: Dict[str, Any], message: Dict[str, Any], update_id: int) -> bool:
    text = message.get("text")
    message_id = message.get("message_id")
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
        return False
    pending = read_json(pending_path(home))
    if isinstance(pending, dict):
        edit_replay = (pending.get("edit_update_id") == update_id
                       and pending.get("edit_message_id") == message_id)
        if edit_replay:
            reconcile_pending(home, config)
            return True
        if pending.get("mode") == "edit":
            if len(text.encode("utf-16-le")) // 2 > MAX_TRANSCRIPT_UNITS:
                return False
            revision = pending.get("revision")
            if not strict_int(revision) or revision <= 0:
                return False
            pending["text"] = text
            pending["mode"] = "confirm"
            pending["revision"] = revision + 1
            pending["edit_update_id"] = update_id
            pending["edit_message_id"] = message_id
            pending["heading_sent"] = False
            pending["transcript_sent"] = False
            pending.pop("edit_prompt_sent", None)
            save_pending(home, pending)
            reconcile_pending(home, config)
            return True
    request_id = queue_request(home, text, int(config["chat_id"]),
                               int(message_id), update_id,
                               attach_to_active=True)
    reconcile_request(home, request_id)
    record = read_json(request_path(home, request_id))
    return isinstance(record, dict) and record.get("wake_recorded") is True


def handle_voice(home: Path, config: Dict[str, Any], message: Dict[str, Any], update_id: int) -> bool:
    voice = message.get("voice")
    if not isinstance(voice, dict):
        return False
    duration = voice.get("duration")
    size = voice.get("file_size", 0)
    file_id = voice.get("file_id")
    if not strict_int(duration) or not strict_int(size):
        return False
    if not isinstance(file_id, str) or not file_id.strip() or "\x00" in file_id:
        return False
    if duration < 0 or duration > MAX_VOICE_SECONDS or size < 0 or size > MAX_VOICE_BYTES:
        return False
    pending_id = f"voice-u{update_id}-m{int(message['message_id'])}"
    pending = read_json(pending_path(home))
    if isinstance(pending, dict) and pending.get("pending_id") == pending_id:
        reconcile_pending(home, config)
        return True
    if isinstance(pending, dict):
        remove_pending(home, pending)
    audio: Optional[Path] = None
    pending: Optional[Dict[str, Any]] = None
    journaled = False
    saved = False
    try:
        result = api_call(home, "getFile", {"file_id": file_id}, config)
        if not isinstance(result, dict) or not isinstance(result.get("file_path"), str):
            raise TelegramError("Telegram returned no voice file")
        audio = Path("/dev/shm") / f"firstmate-telegram-{secrets.token_hex(16)}.oga"
        pending = {
            "pending_id": pending_id,
            "mode": "transcribing",
            "audio_path": str(audio),
            "chat_id": int(config["chat_id"]),
            "message_id": int(message["message_id"]),
            "update_id": update_id,
            "created_at": now(),
            "revision": 1,
            "completed_actions": [],
        }
        save_pending(home, pending)
        journaled = True
        descriptor = os.open(audio, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        download_file(home, str(result["file_path"]), audio, config)
        transcript = transcribe(home, config, audio, "parakeet")
        pending.update({
            "mode": "confirm",
            "text": transcript,
            "heading_sent": False,
            "transcript_sent": False,
        })
        save_pending(home, pending)
        saved = True
        audio = None
        reconcile_pending(home, config)
        return True
    except (TelegramError, OSError):
        if not saved:
            if journaled and pending is not None:
                remove_pending(home, pending)
            elif audio is not None:
                remove_audio({"audio_path": str(audio)})
            try:
                send_text(home, int(config["chat_id"]), "I couldn't transcribe that voice note.")
            except TelegramError:
                pass
        return saved


def handle_callback(home: Path, config: Dict[str, Any], query: Dict[str, Any], update_id: int) -> bool:
    callback_id = query.get("id")
    sender = query.get("from")
    message = query.get("message")
    if not isinstance(callback_id, str) or not callback_id:
        return False
    if (not isinstance(sender, dict) or not strict_int(sender.get("id"))
            or sender.get("id") != config.get("user_id")):
        return False
    if not isinstance(message, dict) or not strict_int(message.get("message_id")):
        return False
    chat = message.get("chat")
    if (not isinstance(chat, dict) or chat.get("type") != "private"
            or not strict_int(chat.get("id")) or chat.get("id") != config.get("chat_id")):
        return False
    callback_data = query.get("data")
    if not isinstance(callback_data, str):
        return False
    parts = callback_data.split(":")
    if len(parts) != 3:
        return False
    action, pending_id, raw_revision = parts
    if action not in {"send", "edit", "retry", "cancel"} or not safe_id(pending_id):
        return False
    try:
        revision = int(raw_revision)
    except ValueError:
        return False
    if revision <= 0 or str(revision) != raw_revision:
        return False
    token = f"{action}:{revision}"
    with FileLock(state_lock(home)):
        pending = read_json(pending_path(home))
        if not isinstance(pending, dict) or pending.get("pending_id") != pending_id:
            if completed_callback_locked(home, pending_id, token):
                answer_callback(home, callback_id)
                return True
            return False
        try:
            expired = now() - int(pending.get("created_at", 0)) >= PENDING_TTL
        except (TypeError, ValueError):
            expired = True
        if expired:
            remove_pending(home, pending)
            answer_callback(home, callback_id)
            return True
        completed = pending.get("completed_actions", [])
        if not isinstance(completed, list):
            return False
        if token in completed or completed_callback_locked(home, pending_id, token):
            answer_callback(home, callback_id)
            return True
        if pending.get("revision") != revision:
            return False
        pending["completed_actions"] = [
            value for value in completed if isinstance(value, str)
        ][-31:] + [token]
        if action == "cancel":
            remove_pending(home, pending)
            remember_callback_locked(home, pending_id, token)
            answer_callback(home, callback_id)
            return True
        if action == "edit":
            pending["mode"] = "edit"
            pending["edit_prompt_sent"] = False
            save_pending(home, pending)
            remember_callback_locked(home, pending_id, token)
            answer_callback(home, callback_id)
            reconcile_pending(home, config)
            return True
        if action == "retry":
            pending["mode"] = "retry"
            pending["retry_token"] = token
            save_pending(home, pending)
            answer_callback(home, callback_id)
            return complete_retry(home, config, pending)
        if action == "send":
            try:
                request_id = _queue_request_locked(
                    home, str(pending["text"]), int(pending["chat_id"]),
                    int(pending["message_id"]), int(pending["update_id"]),
                    "voice", True, True,
                )
                remember_callback_locked(home, pending_id, token)
                answer_callback(home, callback_id)
            except (TelegramError, KeyError, TypeError, ValueError):
                return False
    if action == "send":
        try:
            reconcile_request(home, request_id)
            record = read_json(request_path(home, request_id))
            if not isinstance(record, dict) or record.get("wake_recorded") is not True:
                return False
            with FileLock(state_lock(home)):
                current = read_json(pending_path(home))
                if (isinstance(current, dict)
                        and current.get("pending_id") == pending_id
                        and current.get("revision") == revision):
                    remove_pending(home, current)
            return True
        except (TelegramError, KeyError, TypeError, ValueError):
            return False
    return False


def process_update(home: Path, config: Dict[str, Any], update: Any) -> None:
    if not isinstance(update, dict) or not strict_int(update.get("update_id")):
        return
    update_id = int(update["update_id"])
    if update_id < 0:
        return
    if isinstance(update.get("callback_query"), dict):
        query = update["callback_query"]
        with FileLock(state_lock(home)):
            if has_seen(home, update_id, None):
                return
        if handle_callback(home, config, query, update_id):
            with FileLock(state_lock(home)):
                seen_update(home, update_id, None)
        return
    if not isinstance(update.get("message"), dict):
        return
    message = update["message"]
    pinned = pinned_message(config, message)
    if pinned is None:
        return
    message_id = int(message["message_id"])
    if message_id < 0:
        return
    with FileLock(state_lock(home)):
        if has_seen(home, update_id, message_id):
            return
    handled = False
    if isinstance(message.get("text"), str):
        handled = handle_text(home, config, message, update_id)
    elif "voice" in message:
        handled = handle_voice(home, config, message, update_id)
    if handled:
        with FileLock(state_lock(home)):
            seen_update(home, update_id, message_id)


def has_seen(home: Path, update_id: int, message_id: Optional[int]) -> bool:
    current = read_json(seen_path(home), {})
    if not isinstance(current, dict):
        return False
    updates = current.get("updates", [])
    messages = current.get("messages", [])
    if not isinstance(updates, list) or not isinstance(messages, list):
        return False
    return update_id in updates or (message_id is not None and message_id in messages)


def seen_update(home: Path, update_id: Optional[int], message_id: Optional[int]) -> bool:
    path = seen_path(home)
    current = read_json(path, {"updates": [], "messages": []})
    if not isinstance(current, dict):
        current = {"updates": [], "messages": []}
    raw_updates = current.get("updates", [])
    raw_messages = current.get("messages", [])
    updates = [x for x in raw_updates if isinstance(x, int)] if isinstance(raw_updates, list) else []
    messages = [x for x in raw_messages if isinstance(x, int)] if isinstance(raw_messages, list) else []
    if (update_id is not None and update_id in updates) or (message_id is not None and message_id in messages):
        return False
    if update_id is not None:
        updates.append(update_id)
    if message_id is not None:
        messages.append(message_id)
    atomic_json(path, {"updates": updates[-MAX_SEEN:], "messages": messages[-MAX_SEEN:]})
    return True


def expire_pending(home: Path) -> None:
    pending = read_json(pending_path(home))
    if isinstance(pending, dict):
        try:
            expired = now() - int(pending.get("created_at", 0)) >= PENDING_TTL
        except (TypeError, ValueError):
            expired = True
        if expired:
            with FileLock(state_lock(home)):
                current = read_json(pending_path(home))
                if isinstance(current, dict):
                    remove_pending(home, current)


def serve(home: Path, once: bool = False, poll_timeout: int = POLL_TIMEOUT) -> int:
    config = load_config(home)
    offset = 0
    stop = False

    def stop_service(_signum: int, _frame: Any) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, stop_service)
    signal.signal(signal.SIGINT, stop_service)
    prepare_transport_activation(home)
    try:
        while not stop:
            reconcile_closing(home)
            expire_pending(home)
            bounded_cleanup(home)
            reconcile_requests(home)
            reconcile_pending(home, config)
            try:
                updates = api_call(home, "getUpdates", {"offset": offset, "timeout": poll_timeout,
                                                           "allowed_updates": ["message", "callback_query"]}, config)
                if not isinstance(updates, list):
                    updates = []
                for update in updates:
                    if isinstance(update, dict) and strict_int(update.get("update_id")):
                        offset = max(offset, int(update["update_id"]) + 1)
                    process_update(home, config, update)
                reconcile_requests(home)
            except TelegramError:
                if once:
                    return 1
                time.sleep(2)
            if once:
                break
        return 0
    finally:
        if stop:
            with FileLock(state_lock(home)):
                pending = read_json(pending_path(home))
                if isinstance(pending, dict):
                    remove_pending(home, pending)
        if stop or once:
            set_telegram_enabled(home, False)


def pair(home: Path, user_id: int, chat_id: int) -> int:
    config_existing = read_json(config_path(home), {})
    config = config_existing if isinstance(config_existing, dict) else {}
    result = api_call(home, "getMe", {}, config)
    if not isinstance(result, dict) or not strict_int(result.get("id")):
        raise TelegramError("bot identity could not be verified")
    chat = api_call(home, "getChat", {"chat_id": chat_id}, config)
    if (not isinstance(chat, dict) or chat.get("type") != "private"
            or not strict_int(chat.get("id")) or chat.get("id") != chat_id):
        raise TelegramError("pairing requires the pinned private bot DM")
    if user_id <= 0 or chat_id <= 0:
        raise TelegramError("user and chat ids must be positive integers")
    if user_id != chat_id:
        raise TelegramError("the pinned private chat must belong to the pinned user")
    config.update({"user_id": user_id, "chat_id": chat_id, "bot_id": int(result["id"]),
                   "api_base": api_base(home, config)})
    atomic_json(config_path(home), config)
    print("Telegram pairing verified.")
    return 0


def text_from_file(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text(encoding="utf-8")


def request_read(home: Path, request_id: str) -> int:
    path = request_path(home, request_id)
    if path is None:
        return die("request not found")
    record = read_json(path)
    if not isinstance(record, dict) or record.get("origin") != "telegram":
        return die("request is not a Telegram request")
    text = record.get("text")
    if not isinstance(text, str):
        return die("request is malformed")
    print(text)
    return 0


def request_handled(home: Path, request_id: str) -> int:
    reconcile_closing(home)
    inbox, handled = request_dirs(home)
    source = inbox / f"{request_id}.json"
    target = handled / f"{request_id}.json"
    with FileLock(state_lock(home)):
        active = active_request_id(home)
        record = read_json(source)
        if not source.is_file() or source.is_symlink():
            if target.is_file():
                target_record = read_json(target)
                if active == request_id or (isinstance(target_record, dict)
                                             and target_record.get("continuation_of") == active):
                    return 0
            return die("request not found")
        if not isinstance(record, dict) or record.get("request_id") != request_id:
            return die("request is malformed")
        continuation_of = record.get("continuation_of")
        if active is not None and active != request_id and continuation_of != active:
            return die("another Telegram conversation is active")
        if active is None:
            if isinstance(continuation_of, str):
                return die("continuation predecessor is no longer active")
            atomic_json(active_path(home), {"request_id": request_id, "claimed_at": now()})
        elif continuation_of == active:
            record["continuation_routing"] = "pending"
            atomic_json(source, record)
        os.replace(source, target)
        private_file(target)
        _sync_request_wakes_locked(home)
    bounded_cleanup(home)
    return 0


def request_bind(home: Path, request_id: str, work_id: str) -> int:
    if not safe_id(work_id):
        return die("work identifier is invalid")
    with FileLock(state_lock(home)):
        active = active_record(home)
        if active is None or active.get("request_id") != request_id:
            return die("request is not the active Telegram conversation")
        if request_path(home, request_id) is None:
            return die("request not found")
        bound = active.get("work_id")
        if bound is not None and bound != work_id:
            return die("active Telegram conversation is bound to different work")
        if bound is None:
            active["work_id"] = work_id
            active["bound_at"] = now()
            atomic_json(active_path(home), active)
    print("Telegram work binding recorded.")
    return 0


def request_active(home: Path, work_id: Optional[str] = None,
                   claimed_request: Optional[str] = None) -> int:
    reconcile_closing(home)
    active = active_record(home)
    if active is None:
        return 1
    request_id = str(active["request_id"])
    if request_path(home, request_id) is None:
        return 1
    if work_id is not None and active.get("work_id") != work_id:
        return 1
    claimed_record: Optional[Dict[str, Any]] = None
    if claimed_request is not None:
        claimed_path = request_path(home, claimed_request)
        if claimed_path is None or claimed_path.parent.name != "handled":
            return 1
        value = read_json(claimed_path)
        if not isinstance(value, dict) or value.get("request_id") != claimed_request:
            return 1
        if claimed_request != request_id:
            if (value.get("continuation_of") != request_id
                    or value.get("continuation_routing") != "pending"):
                return 1
            claimed_record = value
    print(request_id, flush=True)
    if claimed_record is not None and claimed_request is not None:
        with FileLock(state_lock(home)):
            path = request_path(home, claimed_request)
            current = read_json(path) if path is not None else None
            if (isinstance(current, dict)
                    and current.get("continuation_of") == request_id
                    and current.get("continuation_routing") == "pending"):
                current["continuation_routing"] = "routed"
                current["continuation_routed_at"] = now()
                atomic_json(path, current)
        reconcile_closing(home)
    return 0


def wake_next_request(home: Path) -> None:
    sync_request_wakes(home)


def reconcile_closing(home: Path) -> None:
    with FileLock(state_lock(home)):
        closing = read_json(closing_path(home))
        if not isinstance(closing, dict):
            return
        request_id = closing.get("request_id")
        if not isinstance(request_id, str) or not safe_id(request_id):
            raise TelegramError("Telegram closing transition is malformed")
        active = active_record(home)
        if active is not None and active.get("request_id") != request_id:
            raise TelegramError("Telegram closing transition conflicts with active work")
        inbox, handled = request_dirs(home)
        continuation_paths = list(inbox.glob("*.json")) + list(handled.glob("*.json"))
        for path in continuation_paths:
            record = read_json(path, {})
            if (isinstance(record, dict) and record.get("continuation_of") == request_id
                    and (path.parent == inbox or record.get("continuation_routing") == "pending")):
                _sync_request_wakes_locked(home)
                return
        if active is not None:
            active_path(home).unlink()
        _sync_request_wakes_locked(home)
        try:
            closing_path(home).unlink()
        except FileNotFoundError:
            pass


def send_command(home: Path, text: str, request_id: Optional[str] = None,
                 final: bool = False) -> int:
    config = load_config(home)
    chat_id = int(config["chat_id"])
    if final and request_id is None:
        raise TelegramError("only a request reply can be final")
    record: Optional[Dict[str, Any]] = None
    if request_id is not None:
        path = request_path(home, request_id)
        if path is None:
            return die("request not found")
        value = read_json(path)
        if not isinstance(value, dict) or value.get("origin") != "telegram":
            return die("request is not a Telegram request")
        record = value
        if active_request_id(home) != request_id:
            if final and record.get("final_sent") is True:
                reconcile_closing(home)
                print("Telegram reply sent.")
                return 0
            return die("request is not the active Telegram conversation")
        chat_id = int(record["chat_id"])
    final_already_sent = bool(final and record is not None and record.get("final_sent") is True)
    if not final_already_sent:
        send_text(home, chat_id, text)
    if final and request_id is not None:
        with FileLock(state_lock(home)):
            current = active_record(home)
            if current is None or current.get("request_id") != request_id:
                raise TelegramError("active Telegram conversation changed during final reply")
            _update_request_record_locked(home, request_id, final_sent=True, final_sent_at=now())
            atomic_json(closing_path(home), {"request_id": request_id, "created_at": now()})
        reconcile_closing(home)
    print("Telegram reply sent.")
    return 0


def telegram_enabled_path(home: Path) -> Path:
    return state_dir(home) / "enabled"


def set_telegram_enabled(home: Path, enabled: bool) -> None:
    path = telegram_enabled_path(home)
    if enabled:
        atomic_bytes(path, b"enabled\n")
    else:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def prepare_transport_activation(home: Path) -> None:
    set_telegram_enabled(home, True)
    if primary_running(home) and not watcher_running(home):
        raise TelegramError(
            "a running primary must establish its harness-owned watcher before Telegram starts; retry after supervision is healthy"
        )


def unit_path() -> Path:
    override = os.environ.get("FM_TELEGRAM_UNIT_DIR")
    if override:
        return Path(override).expanduser() / SERVICE_NAME
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "systemd" / "user" / SERVICE_NAME


def systemd_quote(value: str) -> str:
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise TelegramError("service paths contain unsupported control characters")
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    return f'"{escaped}"'


def unit_contents(home: Path) -> str:
    script = Path(__file__).resolve()
    arguments = " ".join(systemd_quote(value) for value in (str(script), "--home", str(home), "serve"))
    return ("[Unit]\nDescription=Firstmate Telegram transport\nAfter=network-online.target\n\n"
            "[Service]\nType=simple\n"
            f"Environment={systemd_quote('FM_HOME=' + str(home))}\n"
            f"ExecStart=:/usr/bin/python3 {arguments}\n"
            "Restart=on-failure\nRestartSec=3\n\n[Install]\nWantedBy=default.target\n")


def unit_owned_by(home: Path) -> bool:
    path = unit_path()
    if not path.is_file() or path.is_symlink():
        return False
    try:
        return path.read_text(encoding="utf-8") == unit_contents(home)
    except OSError:
        return False


def require_unit_owner(home: Path) -> None:
    if not unit_owned_by(home):
        raise TelegramError("Telegram service is not installed for this home")


def verify_service(active: Optional[bool] = None, enabled: Optional[bool] = None) -> None:
    if active is not None:
        result = systemctl("is-active", SERVICE_NAME, check=False)
        observed = result.returncode == 0 and result.stdout.strip() == "active"
        if observed != active:
            raise TelegramError("Telegram service active state did not converge")
    if enabled is not None:
        result = systemctl("is-enabled", SERVICE_NAME, check=False)
        observed = result.returncode == 0 and result.stdout.strip() == "enabled"
        if observed != enabled:
            raise TelegramError("Telegram service enabled state did not converge")


def verify_transport_marker(home: Path, expected: bool) -> None:
    deadline = time.monotonic() + 3
    while telegram_enabled_path(home).is_file() != expected and time.monotonic() < deadline:
        time.sleep(0.02)
    if telegram_enabled_path(home).is_file() != expected:
        raise TelegramError("Telegram supervision state did not converge")


def install(home: Path) -> int:
    load_config(home)
    token_for(home)
    path = unit_path()
    if (path.exists() or path.is_symlink()) and not unit_owned_by(home):
        raise TelegramError("Telegram service unit belongs to another home or installation")
    atomic_bytes(path, unit_contents(home).encode())
    systemctl("daemon-reload")
    systemctl("enable", SERVICE_NAME)
    prepare_transport_activation(home)
    systemctl("start", SERVICE_NAME)
    verify_service(active=True, enabled=True)
    verify_transport_marker(home, True)
    print("Telegram service installed and active.")
    return 0


def start_service(home: Path) -> int:
    load_config(home)
    require_unit_owner(home)
    prepare_transport_activation(home)
    systemctl("start", SERVICE_NAME)
    verify_service(active=True)
    verify_transport_marker(home, True)
    print("Telegram service active.")
    return 0


def stop_service(home: Path) -> int:
    require_unit_owner(home)
    systemctl("stop", SERVICE_NAME)
    verify_service(active=False)
    with FileLock(state_lock(home)):
        pending = read_json(pending_path(home))
        if isinstance(pending, dict):
            remove_pending(home, pending)
    set_telegram_enabled(home, False)
    verify_transport_marker(home, False)
    print("Telegram service stopped.")
    return 0


def status_service(home: Path) -> int:
    require_unit_owner(home)
    result = systemctl("is-active", SERVICE_NAME, check=False)
    print(result.stdout.strip() or "inactive")
    return 0 if result.returncode == 0 and result.stdout.strip() == "active" else 1


def disable_service(home: Path) -> int:
    require_unit_owner(home)
    systemctl("disable", "--now", SERVICE_NAME)
    verify_service(active=False, enabled=False)
    with FileLock(state_lock(home)):
        pending = read_json(pending_path(home))
        if isinstance(pending, dict):
            remove_pending(home, pending)
    set_telegram_enabled(home, False)
    verify_transport_marker(home, False)
    print("Telegram service disabled.")
    return 0


def cleanup(home: Path) -> int:
    path = unit_path()
    active_result = systemctl("is-active", SERVICE_NAME, check=False)
    enabled_result = systemctl("is-enabled", SERVICE_NAME, check=False)
    active_state = active_result.stdout.strip()
    enabled_state = enabled_result.stdout.strip()
    safely_inactive = active_state in {"inactive", "failed", "unknown"}
    safely_disabled = enabled_state in {"disabled", "not-found"}
    owned = unit_owned_by(home)
    unit_present = path.exists() or path.is_symlink()
    if not owned and (unit_present or not safely_inactive or not safely_disabled):
        raise TelegramError("Telegram service ownership could not be verified")
    telegram_state = home / "state" / "telegram"
    pending_records = []
    if telegram_state.is_dir() and not telegram_state.is_symlink():
        pending = read_json(telegram_state / "pending.json")
        if isinstance(pending, dict):
            pending_records.append(pending)
    if owned:
        systemctl("disable", "--now", SERVICE_NAME)
        verify_service(active=False, enabled=False)
        path.unlink()
        systemctl("daemon-reload")
    if telegram_state.is_dir() and not telegram_state.is_symlink():
        pending = read_json(telegram_state / "pending.json")
        if isinstance(pending, dict):
            pending_records.append(pending)
    for pending in pending_records:
        remove_audio(pending)
    consume_safe_wakes(home)
    if telegram_state.is_symlink() or telegram_state.is_file():
        telegram_state.unlink()
    elif telegram_state.is_dir():
        shutil.rmtree(telegram_state)
    config = config_path(home)
    if config.is_symlink() or config.is_file():
        config.unlink()
    print("Telegram service and private Telegram state cleaned up.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Private one-home Telegram transport for Firstmate.",
        epilog=("Commands: pair, serve, request-read, request-handled, request-bind, active-request, send, reply, install, start, stop, status, disable, cleanup.\n"
                "Retention limits: 256 queued requests for 7 days and 4096 handled requests.\n"
                "Voice limits: 10 MiB, 120 seconds, and a 4096-unit transcript. Temporary audio is restricted to /dev/shm.\n"
                "FM_TELEGRAM_PARAKEET_CMD and FM_TELEGRAM_WHISPER_CMD override the local transcription commands.\n"
                "Text for send and reply is read with --text-file or stdin (-); no recipient argument is accepted."),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--home", help="the one Firstmate home to use")
    sub = parser.add_subparsers(dest="command", required=True)
    def add_home(command: argparse.ArgumentParser) -> None:
        command.add_argument("--home", default=argparse.SUPPRESS, help=argparse.SUPPRESS)
    pair_parser = sub.add_parser("pair", help="verify and save one private Telegram pairing")
    add_home(pair_parser)
    pair_parser.add_argument("--user-id", type=int, required=True)
    pair_parser.add_argument("--chat-id", type=int, required=True)
    serve_parser = sub.add_parser("serve", help="run the outbound Bot API long-poll service")
    add_home(serve_parser)
    serve_parser.add_argument("--once", action="store_true")
    serve_parser.add_argument("--poll-timeout", type=int, default=POLL_TIMEOUT)
    read_parser = sub.add_parser("request-read", help="print one queued Telegram request")
    add_home(read_parser)
    read_parser.add_argument("request_id")
    handled_parser = sub.add_parser("request-handled", help="claim and mark one Telegram request handled")
    add_home(handled_parser)
    handled_parser.add_argument("request_id")
    bind_parser = sub.add_parser("request-bind", help="bind the active request to one lifecycle work id")
    add_home(bind_parser)
    bind_parser.add_argument("request_id")
    bind_parser.add_argument("work_id")
    active_parser = sub.add_parser("active-request", help="print the active Telegram request id")
    add_home(active_parser)
    active_group = active_parser.add_mutually_exclusive_group()
    active_group.add_argument("--work-id", help="require an exact lifecycle work binding")
    active_group.add_argument("--claimed-request", help="consume routing for this handled request")
    for name, help_text in (("send", "send to the paired private chat"), ("reply", "reply to one Telegram request")):
        command = sub.add_parser(name, help=help_text)
        add_home(command)
        if name == "reply":
            command.add_argument("request_id")
            command.add_argument("--final", action="store_true", help="close this conversation after delivery")
        command.add_argument("--text-file", required=True, help="UTF-8 text file, or - for stdin")
    for name, help_text in (("install", "install and start the user service"), ("start", "start the user service"),
                            ("stop", "stop the user service"), ("status", "show user service status"),
                            ("disable", "disable the user service"), ("cleanup", "remove this service and private state")):
        command = sub.add_parser(name, help=help_text)
        add_home(command)
    return parser


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        home = home_from(args)
        if args.command == "pair":
            return pair(home, args.user_id, args.chat_id)
        if args.command == "serve":
            return serve(home, args.once, max(0, min(args.poll_timeout, 50)))
        if args.command == "request-read":
            return request_read(home, args.request_id)
        if args.command == "request-handled":
            return request_handled(home, args.request_id)
        if args.command == "request-bind":
            return request_bind(home, args.request_id, args.work_id)
        if args.command == "active-request":
            return request_active(home, args.work_id, args.claimed_request)
        if args.command == "send":
            return send_command(home, text_from_file(args.text_file))
        if args.command == "reply":
            return send_command(home, text_from_file(args.text_file), args.request_id, args.final)
        if args.command == "install":
            return install(home)
        if args.command == "start":
            return start_service(home)
        if args.command == "stop":
            return stop_service(home)
        if args.command == "status":
            return status_service(home)
        if args.command == "disable":
            return disable_service(home)
        if args.command == "cleanup":
            return cleanup(home)
        return 2
    except (TelegramError, OSError, ValueError) as exc:
        return die(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
