#!/usr/bin/env python3
"""Small, private Telegram transport for one Firstmate home.

The service deliberately owns transport, private queue and delivery-record
durability, and origin binding only.  It does not interpret requests, choose
actions, or authorize Firstmate operations.
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import hashlib
import json
import os
import secrets
import shlex
import shutil
import signal
import stat
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
MAX_PENDING_VOICES = 64
MAX_MIRROR_DELIVERIES = 256
MAX_MIRROR_DELIVERY_BYTES = 256 * 1024
MAX_MIRROR_DELIVERY_CHUNKS = 64
MAX_MIRROR_DELIVERY_ATTEMPTS = 3
MAX_TELEGRAM_TEXT_UNITS = 4096
MAX_MIRROR_CAPABILITY_BYTES = 128
MAX_ATOMIC_TEMPS = 256
MAX_TEXT = 12000
MAX_TRANSCRIPT_UNITS = 4096
MAX_TELEGRAM_NUMERIC_ID = (1 << 52) - 1
MAX_CALLBACK_ID_BYTES = 256
MAX_VOICE_BYTES = 10 * 1024 * 1024
MAX_VOICE_SECONDS = 120
INBOX_TTL = 7 * 24 * 60 * 60
PENDING_TTL = 10 * 60
ATOMIC_TEMP_TTL = 10 * 60
MIRROR_DELIVERY_TTL = INBOX_TTL
POLL_TIMEOUT = 30
RECEIPT_RETRY_DELAYS = (30, 120, 300)
CALLBACK_DELIVERY_ATTEMPTS = 3
TELEGRAM_API_BASE = "https://api.telegram.org"
PERMANENT_CONFIG_EXIT = 78
FINAL_CONTINUATION_PENDING_EXIT = 2
DELIVERY_UNKNOWN_EXIT = 3
FIRSTMATE_REPLY_LABEL = "Firstmate · "
QUEUED_RECEIPT = "Bot · Queued for Firstmate."
PI_DELIVERED_RECEIPT = "Pi · Delivered to Firstmate."
VOICE_PROGRESS_NOTICE = "Bot · Transcribing…"
VOICE_QUEUED_NOTICE = "Bot · Voice note queued."
EMPTY_INLINE_MARKUP = {"inline_keyboard": []}
MIRROR_OFF_REFUSAL = (
    "Bot · Telegram mirror mode is off, so this message was not processed. "
    "Send /telegram on to mirror this chat into the Firstmate terminal."
)
MIRROR_COMMANDS = {"/telegram on": "on", "/telegram off": "off", "/telegram status": "status"}
MIRROR_MODE_NAME = "telegram-mirror"
MIRROR_OWNER_NAME = "mirror-owner.json"
MESSAGE_ENVELOPE_FIELDS = frozenset({
    "author_signature", "business_connection_id", "chat", "date", "direct_messages_topic",
    "edit_date", "effect_id", "external_reply", "forward_origin", "from",
    "has_protected_content", "is_automatic_forward", "is_from_offline", "is_paid_post",
    "is_topic_message", "media_group_id", "message_id", "message_thread_id", "paid_star_count",
    "quote", "reply_markup", "reply_to_checklist_task_id", "reply_to_message", "reply_to_story",
    "sender_boost_count", "sender_business_bot", "sender_chat", "via_bot",
})
TEXT_MESSAGE_FIELDS = MESSAGE_ENVELOPE_FIELDS | frozenset({
    "entities", "link_preview_options", "suggested_post_info", "text",
})
VOICE_MESSAGE_FIELDS = MESSAGE_ENVELOPE_FIELDS | frozenset({"voice"})
CALLBACK_QUERY_FIELDS = frozenset({"chat_instance", "data", "from", "id", "message"})
CALLBACK_MESSAGE_FIELDS = TEXT_MESSAGE_FIELDS
ATOMIC_STATE_TARGETS = frozenset({
    "active.json", "admission-sequence.json", "callback-actions.json", "closing.json",
    "enabled", "mirror-owner.json", "pending.json", "pending-voice-queue.json", "reply-journal.json", "seen.json",
})
_PROCESS_TOKENS: Dict[Path, str] = {}
_VERIFIED_BOT_IDS: Dict[Path, int] = {}
_TEST_API_BASES: Dict[Path, str] = {}


class TelegramError(RuntimeError):
    def __init__(self, message: str, delivery_unknown: bool = False,
                 http_status: Optional[int] = None):
        super().__init__(message)
        self.delivery_unknown = delivery_unknown
        self.http_status = http_status


class PermanentConfigurationError(TelegramError):
    pass


class ServiceRuntimeOwnedError(TelegramError):
    pass


def die(message: str, exit_status: int = 1) -> int:
    print("fm-telegram: " + message, file=sys.stderr)
    return exit_status


def home_from(args: argparse.Namespace) -> Path:
    value = getattr(args, "home", None) or os.environ.get("FM_HOME")
    if not value:
        raise TelegramError("FM_HOME or --home is required")
    return Path(value).expanduser().resolve()


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def fsync_file(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def private_dir(path: Path) -> None:
    missing = []
    cursor = path
    while not cursor.exists():
        missing.append(cursor)
        parent = cursor.parent
        if parent == cursor:
            break
        cursor = parent
    path.mkdir(parents=True, exist_ok=True)
    for created in reversed(missing):
        os.chmod(created, 0o700)
        fsync_directory(created.parent)
    os.chmod(path, 0o700)


def private_file(path: Path) -> None:
    os.chmod(path, 0o600)


def require_path_kind(path: Path, expected: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return
    if stat.S_ISLNK(mode):
        raise TelegramError(f"Telegram home component must not be a symlink: {path}")
    valid = stat.S_ISDIR(mode) if expected == "directory" else stat.S_ISREG(mode)
    if not valid:
        raise TelegramError(f"Telegram home component must be a {expected}: {path}")


def validate_home_storage(home: Path) -> None:
    if not home.is_dir() or home.is_symlink():
        raise TelegramError(f"Telegram home must be an existing directory: {home}")
    try:
        (home / ".fm-secondmate-home").lstat()
    except FileNotFoundError:
        pass
    else:
        raise TelegramError("Telegram is available only for the primary Firstmate home")
    state = home / "state"
    config = home / "config"
    telegram = state / "telegram"
    for path in (
            state, config, telegram, telegram / "inbox", telegram / "handled",
            telegram / "responses", telegram / "deliveries"):
        require_path_kind(path, "directory")
    for path in (
        config / CONFIG_NAME,
        config / MIRROR_MODE_NAME,
        state / ".telegram-cleaned",
        state / ".telegram-lifecycle.lock",
        state / ".telegram-service-activation",
        state / ".telegram-service.lock",
        state / ".telegram-state.lock",
    ):
        require_path_kind(path, "regular file")
    if telegram.is_dir():
        for child in telegram.iterdir():
            if child.name in {"inbox", "handled", "responses", "deliveries"}:
                continue
            require_path_kind(child, "regular file")
        for directory in (
                telegram / "inbox", telegram / "handled", telegram / "responses",
                telegram / "deliveries"):
            if directory.is_dir():
                for child in directory.iterdir():
                    require_path_kind(child, "regular file")


def durable_replace(source: Path, target: Path) -> None:
    os.replace(source, target)
    fsync_directory(target.parent)
    if source.parent != target.parent:
        fsync_directory(source.parent)


def durable_unlink(path: Path, missing_ok: bool = True) -> bool:
    try:
        path.unlink()
    except FileNotFoundError:
        if missing_ok:
            return False
        raise
    fsync_directory(path.parent)
    return True


def durable_rmtree(path: Path) -> None:
    shutil.rmtree(path)
    fsync_directory(path.parent)


def atomic_bytes(path: Path, data: bytes, mode: int = 0o600) -> None:
    private_dir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        durable_replace(Path(temporary), path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def atomic_json(path: Path, value: Any) -> None:
    atomic_bytes(path, (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode())


def file_sha256(path: Path) -> Tuple[int, str]:
    size = 0
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            block = stream.read(64 * 1024)
            if not block:
                break
            size += len(block)
            digest.update(block)
    return size, digest.hexdigest()


def read_json(path: Path, default: Any = None) -> Any:
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def env_value(home: Path, key: str) -> Optional[str]:
    dotenv = home / ".env"
    descriptor = -1
    try:
        descriptor = os.open(dotenv, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise TelegramError("Telegram .env must be a readable regular non-symlink file") from exc
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise TelegramError("Telegram .env must be a regular non-symlink file")
        with os.fdopen(descriptor, encoding="utf-8") as stream:
            descriptor = -1
            lines = stream.read().splitlines()
    except (OSError, UnicodeError) as exc:
        raise TelegramError("Telegram .env must be a readable UTF-8 regular file") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
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
    key = home.resolve()
    pinned = _PROCESS_TOKENS.get(key)
    if pinned is not None:
        return pinned
    token = env_value(home, "FM_TELEGRAM_BOT_TOKEN")
    if not token:
        raise TelegramError("FM_TELEGRAM_BOT_TOKEN is not configured in this home")
    _PROCESS_TOKENS[key] = token
    return token


def config_path(home: Path) -> Path:
    return home / "config" / CONFIG_NAME


def state_dir(home: Path) -> Path:
    return home / "state" / "telegram"


def normalize_transcriber_command(value: Any, kind: str) -> str:
    label = "Parakeet" if kind == "parakeet" else "Whisper"
    if not isinstance(value, str) or not value.strip():
        raise TelegramError(f"configured {label} command is missing or unsafe")
    try:
        parts = ([value] if value.startswith("/") else shlex.split(value))
    except ValueError as exc:
        raise TelegramError(f"configured {label} command is missing or unsafe") from exc
    if len(parts) != 1:
        raise TelegramError(f"configured {label} command is missing or unsafe")
    command = parts[0]
    path = Path(command)
    if (not path.is_absolute()
            or any(ord(character) < 32 or ord(character) == 127 for character in command)):
        raise TelegramError(f"configured {label} command is missing or unsafe")
    try:
        details = path.lstat()
    except OSError as exc:
        raise TelegramError(f"configured {label} command is missing or unsafe") from exc
    if (stat.S_ISLNK(details.st_mode) or not stat.S_ISREG(details.st_mode)
            or not os.access(path, os.X_OK)):
        raise TelegramError(f"configured {label} command is missing or unsafe")
    return command


def validate_transcriber_config(config: Dict[str, Any]) -> Dict[str, Any]:
    validated = dict(config)
    for kind, key in (("parakeet", "parakeet_command"), ("whisper", "whisper_command")):
        if key in validated:
            validated[key] = normalize_transcriber_command(validated[key], kind)
    return validated


def load_config(home: Path) -> Dict[str, Any]:
    path = config_path(home)
    config = read_json(path)
    if not isinstance(config, dict):
        raise TelegramError("Telegram pairing is not configured")
    config = validate_transcriber_config(config)
    for key in ("user_id", "chat_id", "bot_id"):
        if not telegram_numeric_id(config.get(key), positive=True):
            raise TelegramError("Telegram pairing is incomplete")
    try:
        mode = path.stat().st_mode & 0o777
        if mode != 0o600:
            raise TelegramError("Telegram pairing config must be mode 0600")
    except FileNotFoundError as exc:
        raise TelegramError("Telegram pairing is not configured") from exc
    return config


def configure_test_api_base(home: Path, value: Optional[str]) -> None:
    if value is None:
        return
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "::1", "localhost"}
            or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment or parsed.path not in {"", "/"}
            or parsed.port is None):
        raise TelegramError("test Telegram API endpoint must be an explicit loopback HTTP URL")
    _TEST_API_BASES[home.resolve()] = value.rstrip("/")


def api_base(home: Path, _config: Optional[Dict[str, Any]] = None) -> str:
    return _TEST_API_BASES.get(home.resolve(), TELEGRAM_API_BASE)


def raw_api_call(home: Path, token: str, method: str,
                 params: Optional[Dict[str, Any]] = None,
                 config: Optional[Dict[str, Any]] = None) -> Any:
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
        raise TelegramError(f"Telegram request failed for {method}",
                            http_status=exc.code) from exc
    except (OSError, urllib.error.URLError) as exc:
        raise TelegramError(f"Telegram request failed for {method}", delivery_unknown=True) from exc
    try:
        envelope = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise TelegramError(f"Telegram returned invalid data for {method}", delivery_unknown=True) from exc
    if not isinstance(envelope, dict) or envelope.get("ok") is not True:
        error_code = envelope.get("error_code") if isinstance(envelope, dict) else None
        raise TelegramError(
            f"Telegram rejected {method}",
            http_status=error_code if strict_int(error_code) else None,
        )
    return envelope.get("result")


def permanent_auth_failure(error: TelegramError) -> bool:
    return error.http_status in {401, 404}


def verified_token_for(home: Path, config: Optional[Dict[str, Any]] = None) -> str:
    pairing = config if isinstance(config, dict) else load_config(home)
    expected = pairing.get("bot_id")
    if not strict_int(expected):
        raise TelegramError("Telegram pairing is incomplete")
    key = home.resolve()
    token = token_for(home)
    if _VERIFIED_BOT_IDS.get(key) == expected:
        return token
    try:
        result = raw_api_call(home, token, "getMe", {}, pairing)
    except TelegramError as exc:
        if permanent_auth_failure(exc):
            raise PermanentConfigurationError(
                "Telegram bot token could not authenticate; pair again"
            ) from exc
        raise
    if (not isinstance(result, dict) or result.get("is_bot") is not True
            or not telegram_numeric_id(result.get("id"), positive=True)
            or result.get("id") != expected):
        raise PermanentConfigurationError(
            "Telegram bot token does not match the verified pairing; pair again"
        )
    _VERIFIED_BOT_IDS[key] = expected
    return token


def api_call(home: Path, method: str, params: Optional[Dict[str, Any]] = None,
             config: Optional[Dict[str, Any]] = None) -> Any:
    token = verified_token_for(home, config)
    return raw_api_call(home, token, method, params, config)


def download_file(home: Path, file_path: str, target: Path, config: Dict[str, Any]) -> None:
    if not isinstance(file_path, str) or not file_path or "\x00" in file_path:
        raise TelegramError("Telegram returned an invalid audio path")
    token = verified_token_for(home, config)
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


def now() -> int:
    return int(time.time())


def strict_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def telegram_numeric_id(value: Any, positive: bool = False) -> bool:
    minimum = 1 if positive else 0
    return strict_int(value) and minimum <= value <= MAX_TELEGRAM_NUMERIC_ID


def callback_query_id(value: Any) -> bool:
    if not isinstance(value, str) or not value or "\x00" in value:
        return False
    try:
        return len(value.encode("utf-8")) <= MAX_CALLBACK_ID_BYTES
    except UnicodeEncodeError:
        return False


def request_dirs(home: Path, create: bool = True) -> Tuple[Path, Path]:
    root = state_dir(home)
    inbox = root / "inbox"
    handled = root / "handled"
    if create:
        private_dir(inbox)
        private_dir(handled)
    return inbox, handled


def safe_id(value: str) -> bool:
    return bool(value) and all(ch.isalnum() or ch in "._-" for ch in value)


def unicode_text_units(value: str) -> Optional[int]:
    try:
        return len(value.encode("utf-16-le")) // 2
    except UnicodeEncodeError:
        return None


def request_path(home: Path, request_id: str) -> Optional[Path]:
    if not safe_id(request_id):
        return None
    inbox, handled = request_dirs(home, create=False)
    for directory in (inbox, handled):
        path = directory / f"{request_id}.json"
        if path.is_file() and not path.is_symlink():
            return path
    return None


def state_lock(home: Path) -> Path:
    return home / "state" / ".telegram-state.lock"


def lifecycle_lock(home: Path) -> Path:
    return home / "state" / ".telegram-lifecycle.lock"


def service_lock(home: Path) -> Path:
    return home / "state" / ".telegram-service.lock"


def global_service_lock() -> Path:
    return unit_path().parent / ".firstmate-telegram-service.lock"


def service_activation_path(home: Path) -> Path:
    return home / "state" / ".telegram-service-activation"


def state_tombstone(home: Path) -> Path:
    return home / "state" / ".telegram-cleaned"


def require_state_available_locked(home: Path) -> None:
    if state_tombstone(home).is_file() or not config_path(home).is_file():
        raise TelegramError("Telegram private state is not initialized; pair this home first")


def unit_lock() -> Path:
    return unit_path().parent / ".firstmate-telegram-unit.lock"


class FileLock:
    def __init__(self, path: Path, blocking: bool = True, timeout: float = 0):
        self.path = path
        self.blocking = blocking
        self.timeout = timeout
        self.stream = None

    def __enter__(self) -> "FileLock":
        private_dir(self.path.parent)
        self.stream = self.path.open("a+")
        os.chmod(self.path, 0o600)
        if self.blocking:
            fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX)
            return self
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError as exc:
                if time.monotonic() >= deadline:
                    self.stream.close()
                    self.stream = None
                    raise ServiceRuntimeOwnedError("Telegram service is already running") from exc
                time.sleep(0.02)

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        assert self.stream is not None
        fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
        self.stream.close()


def lock_owned(path: Path) -> bool:
    try:
        with FileLock(path, blocking=False):
            return False
    except ServiceRuntimeOwnedError:
        return True


def service_runtime_owned(home: Path) -> bool:
    return lock_owned(service_lock(home))


def require_service_runtime_inactive(home: Path) -> None:
    if lock_owned(global_service_lock()) or service_runtime_owned(home):
        raise ServiceRuntimeOwnedError("Telegram service is already running")


def systemd_runtime_reserved(home: Path) -> bool:
    path = unit_path()
    if (path.exists() or path.is_symlink()) and not unit_owned_by(home):
        return True
    if not unit_owned_by(home):
        return False
    result = systemctl("is-enabled", SERVICE_NAME, check=False)
    return result.stdout.strip() not in {"disabled", "not-found"}


def seen_path(home: Path) -> Path:
    return state_dir(home) / "seen.json"


def effective_wake_state(home: Path) -> Path:
    override = os.environ.get("FM_STATE_OVERRIDE")
    return Path(override).expanduser().resolve() if override else home / "state"


def consume_safe_wakes(home: Path, wake_state: Path,
                       request_ids: Optional[List[str]] = None) -> None:
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
        environment["FM_STATE_OVERRIDE"] = str(wake_state)
        result = subprocess.run(
            ["/bin/bash", "-c", script, "fm-telegram", str(library), request_id],
            env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            raise TelegramError("safe Telegram wakes could not be cleaned")
        queue = wake_state / ".wake-queue"
        if queue.is_file() and not queue.is_symlink():
            fsync_file(queue)
        fsync_directory(wake_state)


def migrate_wakes(home: Path) -> int:
    consume_safe_wakes(home, effective_wake_state(home))
    return 0


def active_path(home: Path) -> Path:
    return state_dir(home) / "active.json"


def closing_path(home: Path) -> Path:
    return state_dir(home) / "closing.json"


def split_telegram_response(body: bytes) -> List[Dict[str, Any]]:
    text = body.decode("utf-8")
    chunks = []
    current = []
    current_units = 0
    offset = 0
    for character in text:
        units = unicode_text_units(character)
        if units is None:
            raise UnicodeError("response contains invalid Unicode")
        if current and current_units + units > MAX_TELEGRAM_TEXT_UNITS:
            chunk_body = "".join(current).encode("utf-8")
            chunks.append({
                "index": len(chunks),
                "start": offset,
                "end": offset + len(chunk_body),
                "body_sha256": hashlib.sha256(chunk_body).hexdigest(),
                "telegram_status": "pending",
                "telegram_attempts": 0,
            })
            offset += len(chunk_body)
            current = []
            current_units = 0
        current.append(character)
        current_units += units
    if current:
        chunk_body = "".join(current).encode("utf-8")
        chunks.append({
            "index": len(chunks),
            "start": offset,
            "end": offset + len(chunk_body),
            "body_sha256": hashlib.sha256(chunk_body).hexdigest(),
            "telegram_status": "pending",
            "telegram_attempts": 0,
        })
    return chunks


def aggregate_response_delivery(chunks: List[Dict[str, Any]]) -> str:
    statuses = [chunk.get("telegram_status") for chunk in chunks]
    if statuses and all(status == "sent" for status in statuses):
        return "sent"
    if "delivery_unknown" in statuses or "sending" in statuses:
        return "delivery_unknown"
    if "rejected" in statuses:
        return "rejected"
    return "pending"


def request_order_key(path: Path) -> Tuple[int, int, int, int, str]:
    record = read_json(path, {})
    if not isinstance(record, dict):
        return (0, -1, -1, -1, path.stem)
    admission_sequence = record.get("admission_sequence")
    created = record.get("created_at")
    update_id = record.get("update_id")
    message_id = record.get("message_id")
    request_id = record.get("request_id")
    if strict_int(admission_sequence) and admission_sequence > 0:
        return (
            1,
            admission_sequence,
            update_id if strict_int(update_id) else -1,
            message_id if strict_int(message_id) else -1,
            request_id if isinstance(request_id, str) else path.stem,
        )
    return (
        0,
        created if strict_int(created) else -1,
        update_id if strict_int(update_id) else -1,
        message_id if strict_int(message_id) else -1,
        request_id if isinstance(request_id, str) else path.stem,
    )


def next_admission_sequence_locked(home: Path) -> int:
    path = state_dir(home) / "admission-sequence.json"
    value = read_json(path, {})
    last = value.get("last") if isinstance(value, dict) else None
    if not strict_int(last) or last < 0:
        inbox, handled = request_dirs(home)
        last = 0
        for request in list(inbox.glob("*.json")) + list(handled.glob("*.json")):
            record = read_json(request, {})
            sequence = record.get("admission_sequence") if isinstance(record, dict) else None
            if strict_int(sequence) and sequence > last:
                last = sequence
    sequence = last + 1
    atomic_json(path, {"last": sequence})
    return sequence


def owned_atomic_temp(home: Path, path: Path) -> bool:
    name = path.name
    if not name.startswith(".") or "." not in name[1:]:
        return False
    target, suffix = name[1:].rsplit(".", 1)
    if (len(suffix) != 8
            or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789_"
                   for character in suffix)):
        return False
    root = state_dir(home)
    if path.parent == root:
        return target in ATOMIC_STATE_TARGETS
    if path.parent in {root / "responses", root / "deliveries"}:
        if target.endswith(".json"):
            record_id = target[:-5]
        elif target.endswith(".txt"):
            record_id = target[:-4]
        else:
            return False
        return safe_id(record_id)
    if path.parent not in {root / "inbox", root / "handled"} or not target.endswith(".json"):
        return False
    request_id = target[:-5]
    for source in ("text", "voice"):
        prefix = f"tg-{source}-u"
        if not request_id.startswith(prefix):
            continue
        identifiers = request_id[len(prefix):].split("-m", 1)
        if len(identifiers) != 2 or not all(value.isdigit() for value in identifiers):
            return False
        update_id, message_id = (int(value) for value in identifiers)
        return (telegram_numeric_id(update_id)
                and telegram_numeric_id(message_id, positive=True)
                and request_id == deterministic_request_id(source, update_id, message_id))
    return False


def cleanup_atomic_temps_locked(home: Path) -> None:
    root = state_dir(home)
    paths = []
    for directory in (root, root / "inbox", root / "handled", root / "responses", root / "deliveries"):
        if not directory.is_dir() or directory.is_symlink():
            continue
        for path in directory.iterdir():
            if not owned_atomic_temp(home, path):
                continue
            try:
                details = path.lstat()
            except FileNotFoundError:
                continue
            if stat.S_ISREG(details.st_mode):
                paths.append((details.st_mtime, path))
    paths.sort(key=lambda item: item[0], reverse=True)
    cutoff = time.time() - ATOMIC_TEMP_TTL
    for index, (modified, path) in enumerate(paths):
        try:
            if index >= MAX_ATOMIC_TEMPS or modified < cutoff:
                durable_unlink(path)
            else:
                private_file(path)
        except OSError:
            pass


def cleanup_failed_completion_request_locked(home: Path, record: Dict[str, Any]) -> None:
    if record.get("status") not in {"rejected", "delivery_unknown"}:
        return
    request_id = record.get("completion_request_id")
    path = request_path(home, request_id) if isinstance(request_id, str) else None
    request = read_json(path) if path is not None else None
    if (path is None or path.parent.name != "inbox" or not isinstance(request, dict)
            or request.get("request_id") != request_id or request.get("status") != "claimed"):
        return
    root = mirror_delivery_dir(home)
    for candidate_path in root.glob("*.json"):
        candidate = read_json(candidate_path)
        if (not isinstance(candidate, dict)
                or candidate.get("delivery_id") == record.get("delivery_id")
                or candidate.get("completion_request_id") != request_id):
            continue
        delivery_pid = candidate.get("delivery_owner_pid")
        delivery_identity = candidate.get("delivery_owner_identity")
        delivery_live = bool(
            strict_int(delivery_pid)
            and isinstance(delivery_identity, str)
            and process_identity(delivery_pid) == delivery_identity
        )
        if candidate.get("status") == "sent" or delivery_live:
            return
    consume_safe_wakes(home, effective_wake_state(home), [request_id])
    durable_unlink(path)


def retire_superseded_completion_deliveries_locked(
        home: Path, request_id: str, delivery_id: str) -> None:
    root = mirror_delivery_dir(home)
    for metadata_path in root.glob("*.json"):
        if metadata_path.stem == delivery_id:
            continue
        record = read_json(metadata_path)
        if (not isinstance(record, dict)
                or record.get("completion_request_id") != request_id
                or record.get("status") not in {"rejected", "delivery_unknown"}):
            continue
        durable_unlink(metadata_path)
        durable_unlink(root / f"{metadata_path.stem}.txt")


def cleanup_mirror_deliveries_locked(home: Path, reserve_slots: int = 0) -> bool:
    root = state_dir(home) / "deliveries"
    private_dir(root)
    records = []
    bodies = set()
    cutoff = now() - MIRROR_DELIVERY_TTL
    for metadata_path in root.glob("*.json"):
        body_path = root / f"{metadata_path.stem}.txt"
        record = read_json(metadata_path)
        created = record.get("created_at") if isinstance(record, dict) else None
        if (not isinstance(record, dict) or record.get("delivery_id") != metadata_path.stem
                or not strict_int(created) or not body_path.is_file() or body_path.is_symlink()):
            durable_unlink(metadata_path)
            durable_unlink(body_path)
            continue
        bodies.add(body_path.name)
        delivery_pid = record.get("delivery_owner_pid")
        delivery_identity = record.get("delivery_owner_identity")
        reservation_pid = record.get("reservation_owner_pid")
        reservation_identity = record.get("reservation_owner_identity")
        delivery_live = bool(
            strict_int(delivery_pid)
            and isinstance(delivery_identity, str)
            and process_identity(delivery_pid) == delivery_identity
        )
        reservation_live = bool(
            strict_int(reservation_pid)
            and isinstance(reservation_identity, str)
            and process_identity(reservation_pid) == reservation_identity
        )
        completion_request = record.get("completion_request_id")
        completion_path = (request_path(home, completion_request)
                           if isinstance(completion_request, str) else None)
        completion_record = read_json(completion_path) if completion_path is not None else None
        completion_pending = bool(
            record.get("status") == "sent"
            and isinstance(completion_record, dict)
            and completion_record.get("request_id") == completion_request
            and completion_record.get("status") == "claimed"
        )
        protected = delivery_live or reservation_live or completion_pending
        if record.get("status") == "reserved" and not reservation_live:
            durable_unlink(metadata_path)
            durable_unlink(body_path)
            bodies.discard(body_path.name)
            continue
        if created < cutoff and not protected:
            cleanup_failed_completion_request_locked(home, record)
            durable_unlink(metadata_path)
            durable_unlink(body_path)
            bodies.discard(body_path.name)
            continue
        records.append((created, metadata_path, body_path, protected))
    for body_path in root.glob("*.txt"):
        if body_path.name not in bodies:
            durable_unlink(body_path)
    records.sort(key=lambda item: item[0], reverse=True)
    keep = max(0, MAX_MIRROR_DELIVERIES - reserve_slots)
    retained = len(records)
    for _created, metadata_path, body_path, protected in reversed(records):
        if retained <= keep:
            break
        if protected:
            continue
        record = read_json(metadata_path, {})
        if isinstance(record, dict):
            cleanup_failed_completion_request_locked(home, record)
        durable_unlink(metadata_path)
        durable_unlink(body_path)
        retained -= 1
    return retained <= keep


def _bounded_cleanup_locked(home: Path, preserve_requests: Iterable[str] = ()) -> None:
    del preserve_requests
    inbox, handled = request_dirs(home)
    cleanup_atomic_temps_locked(home)
    cutoff = now() - INBOX_TTL
    inbox_files = sorted(inbox.glob("*.json"), key=request_order_key, reverse=True)
    queued_index = 0
    for path in inbox_files:
        record = read_json(path, {})
        if isinstance(record, dict) and record.get("status") == "claimed":
            owner_pid = record.get("claim_owner_pid")
            owner_identity = record.get("claim_owner_identity")
            if (strict_int(owner_pid) and isinstance(owner_identity, str)
                    and process_identity(owner_pid) == owner_identity):
                continue
        created = record.get("created_at", 0) if isinstance(record, dict) else 0
        should_remove = (queued_index >= MAX_INBOX or not strict_int(created)
                         or created < cutoff)
        queued_index += 1
        if should_remove:
            try:
                consume_safe_wakes(home, effective_wake_state(home), [path.stem])
                durable_unlink(path)
            except (OSError, TelegramError):
                pass
    handled_files = sorted(handled.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in handled_files[MAX_HANDLED:]:
        try:
            durable_unlink(path)
        except OSError:
            pass
    cleanup_mirror_deliveries_locked(home)
    pending = state_dir(home) / "pending.json"
    data = read_json(pending)
    try:
        expired = (isinstance(data, dict)
                   and now() - int(data.get("created_at", 0)) >= PENDING_TTL)
    except (TypeError, ValueError):
        expired = True
    if expired:
        if isinstance(data, dict):
            pending_id = data.get("pending_id")
            finalize_pending_cleanup_locked(home, data)
            if isinstance(pending_id, str):
                remove_pending_voice_locked(home, pending_id)
        else:
            remove_pending(home)
    queued_voices, queue_changed = load_pending_voice_queue_locked(home)
    if queue_changed:
        save_pending_voice_queue_locked(home, queued_voices)


def bounded_cleanup(home: Path) -> None:
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        _bounded_cleanup_locked(home)


def deterministic_request_id(source: str, update_id: int, message_id: int) -> str:
    if (source not in {"text", "voice"}
            or not telegram_numeric_id(update_id)
            or not telegram_numeric_id(message_id, positive=True)):
        raise TelegramError("request identifiers are invalid")
    return f"tg-{source}-u{update_id}-m{message_id}"


def _queue_request_locked(home: Path, text: str, chat_id: int, message_id: int,
                          update_id: Optional[int], source: str, confirmed: bool) -> str:
    if (not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT
            or unicode_text_units(text) is None):
        raise TelegramError("request text is empty, too long, or malformed")
    if (not telegram_numeric_id(update_id)
            or not telegram_numeric_id(message_id, positive=True)):
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
        "admission_sequence": next_admission_sequence_locked(home),
        "status": "queued",
        "receipt_text": transport_reply(home),
        "receipt_status": "pending",
    }
    queued_files = []
    for candidate in sorted(inbox.glob("*.json"), key=request_order_key):
        candidate_record = read_json(candidate, {})
        if not isinstance(candidate_record, dict) or candidate_record.get("status") != "claimed":
            queued_files.append(candidate)
    while len(queued_files) >= MAX_INBOX:
        oldest = queued_files.pop(0)
        consume_safe_wakes(home, effective_wake_state(home), [oldest.stem])
        durable_unlink(oldest)
    atomic_json(path, record)
    return request_id


def queue_request(home: Path, text: str, chat_id: int, message_id: int,
                  update_id: Optional[int], source: str = "text",
                  confirmed: bool = False) -> str:
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        return _queue_request_locked(
            home, text, chat_id, message_id, update_id, source, confirmed
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
        require_state_available_locked(home)
        return _update_request_record_locked(home, request_id, **changes)


def reconcile_request(home: Path, request_id: str) -> bool:
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        path = request_path(home, request_id)
        if path is None:
            return False
        record = read_json(path)
        if not isinstance(record, dict) or record.get("origin") != "telegram":
            return False
        receipt_status = record.get("receipt_status")
        if receipt_status == "sent":
            return True
        if receipt_status in {"delivery_unknown_terminal", "rejected_terminal"}:
            return False
        receipt = record.get("receipt_text")
        chat_id = record.get("chat_id")
        attempts = record.get("receipt_attempts", 0)
        unknown_attempts = record.get("receipt_unknown_attempts", 0)
        if (receipt_status not in {"pending", "delivery_unknown", "rejected"}
                or not isinstance(receipt, str) or not strict_int(chat_id)
                or not strict_int(attempts) or attempts < 0
                or not strict_int(unknown_attempts) or unknown_attempts < 0):
            raise TelegramError("request receipt state is malformed")
        if receipt_status != "pending":
            if attempts >= len(RECEIPT_RETRY_DELAYS):
                _update_request_record_locked(
                    home, request_id,
                    receipt_status=("delivery_unknown_terminal"
                                    if receipt_status == "delivery_unknown"
                                    else "rejected_terminal"),
                    receipt_terminal_at=now(),
                )
                return False
            retry_at = record.get("receipt_retry_at", 0)
            if not strict_int(retry_at) or retry_at < 0:
                raise TelegramError("request receipt retry state is malformed")
            if now() < retry_at:
                return False
        if attempts >= len(RECEIPT_RETRY_DELAYS):
            _update_request_record_locked(
                home, request_id, receipt_status="rejected_terminal", receipt_terminal_at=now()
            )
            return False
        attempted_at = now()
        next_attempts = attempts + 1
        next_unknown_attempts = unknown_attempts + 1
        _update_request_record_locked(
            home,
            request_id,
            receipt_status="delivery_unknown",
            receipt_attempts=next_attempts,
            receipt_unknown_attempts=next_unknown_attempts,
            receipt_attempted_at=attempted_at,
            receipt_retry_at=attempted_at + RECEIPT_RETRY_DELAYS[next_attempts - 1],
        )
    try:
        result = send_text(
            home, chat_id, receipt, reply_to=int(record["message_id"]),
            fallback_to=int(record["message_id"]), journal_key=f"{request_id}:queued",
        )
    except TelegramError as exc:
        if next_attempts >= len(RECEIPT_RETRY_DELAYS):
            status = "delivery_unknown_terminal" if exc.delivery_unknown else "rejected_terminal"
            update_request_record(
                home, request_id, receipt_status=status,
                receipt_unknown_attempts=(next_unknown_attempts
                                          if exc.delivery_unknown else unknown_attempts),
                receipt_terminal_at=now(),
            )
        elif not exc.delivery_unknown:
            update_request_record(
                home, request_id, receipt_status="rejected",
                receipt_unknown_attempts=unknown_attempts,
            )
        return False
    update_request_record(
        home, request_id, receipt_status="sent", receipt_unknown_attempts=unknown_attempts,
        receipt_sent_at=now(), receipt_retry_at=None,
        receipt_message_id=outbound_message_id(result),
    )
    return True


def reconcile_requests(home: Path) -> None:
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        inbox, handled = request_dirs(home)
        paths = list(inbox.glob("*.json")) + list(handled.glob("*.json"))
        request_ids = []
        for path in sorted(paths, key=request_order_key):
            record = read_json(path)
            if isinstance(record, dict) and isinstance(record.get("request_id"), str):
                request_ids.append(str(record["request_id"]))
    for request_id in request_ids:
        try:
            reconcile_request(home, request_id)
        except TelegramError:
            continue


def mirror_mode_path(home: Path) -> Path:
    return home / "config" / MIRROR_MODE_NAME


def mirror_mode_enabled(home: Path) -> bool:
    try:
        return mirror_mode_path(home).read_text(encoding="ascii").strip() == "on"
    except (OSError, UnicodeError):
        return False


def set_mirror_mode(home: Path, enabled: bool) -> None:
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        atomic_bytes(mirror_mode_path(home), b"on\n" if enabled else b"off\n")


def mirror_command(text: Any) -> Optional[str]:
    return MIRROR_COMMANDS.get(text) if isinstance(text, str) else None


def mirror_mode_reply(home: Path, action: str) -> str:
    if action == "on":
        set_mirror_mode(home, True)
        return "Pi · Telegram mirror mode is on."
    if action == "off":
        set_mirror_mode(home, False)
        return "Pi · Telegram mirror mode is off."
    return f"Pi · Telegram mirror mode is {'on' if mirror_mode_enabled(home) else 'off'}."


def mirror_owner_path(home: Path) -> Path:
    return state_dir(home) / MIRROR_OWNER_NAME


def process_identity(pid: int) -> Optional[str]:
    if pid <= 0:
        return None
    proc_stat = Path(f"/proc/{pid}/stat")
    try:
        fields = proc_stat.read_text(encoding="ascii").rsplit(")", 1)[1].split()
        if len(fields) > 19:
            return f"proc:{pid}:{fields[19]}"
    except (OSError, UnicodeError, IndexError):
        pass
    result = subprocess.run(
        ["ps", "-o", "lstart=", "-p", str(pid)], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    started = result.stdout.strip()
    return f"ps:{pid}:{started}" if result.returncode == 0 and started else None


def process_parent(pid: int) -> Optional[int]:
    try:
        fields = Path(f"/proc/{pid}/stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()
        return int(fields[1])
    except (OSError, UnicodeError, ValueError, IndexError):
        result = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        try:
            return int(result.stdout.strip()) if result.returncode == 0 else None
        except ValueError:
            return None


def mirror_owner_holds_lock(home: Path, owner_pid: int) -> bool:
    try:
        lock_pid = int((home / "state" / ".lock").read_text(encoding="ascii").strip())
    except (OSError, UnicodeError, ValueError):
        return False
    current = owner_pid
    for _ in range(32):
        if current == lock_pid:
            return process_identity(lock_pid) is not None
        parent = process_parent(current)
        if parent is None or parent <= 1 or parent == current:
            return False
        current = parent
    return False


def mirror_capability(capability_fd: int) -> Optional[str]:
    if capability_fd < 3:
        return None
    try:
        value = os.read(capability_fd, MAX_MIRROR_CAPABILITY_BYTES + 1).strip()
    except OSError:
        return None
    if not 32 <= len(value) <= MAX_MIRROR_CAPABILITY_BYTES:
        return None
    try:
        text = value.decode("ascii")
    except UnicodeError:
        return None
    return text if all(character in "0123456789abcdef" for character in text) else None


def mirror_open(home: Path, owner_pid: int, capability_fd: int) -> int:
    capability = mirror_capability(capability_fd)
    identity = process_identity(owner_pid)
    if (owner_pid != os.getppid() or capability is None or identity is None
            or not mirror_owner_holds_lock(home, owner_pid)):
        return die("Telegram mirror capability was not opened by the lock-owning extension")
    digest = hashlib.sha256(capability.encode("ascii")).hexdigest()
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        existing = read_json(mirror_owner_path(home), {})
        existing_pid = existing.get("owner_pid") if isinstance(existing, dict) else None
        existing_identity = existing.get("owner_identity") if isinstance(existing, dict) else None
        existing_digest = existing.get("capability_sha256") if isinstance(existing, dict) else None
        if existing_pid == owner_pid and existing_identity == identity:
            if existing_digest != digest:
                return die("Telegram mirror capability is already owned by this Pi process")
            return 0
        if (strict_int(existing_pid) and isinstance(existing_identity, str)
                and process_identity(existing_pid) == existing_identity
                and mirror_owner_holds_lock(home, existing_pid)):
            return die("Telegram mirror capability is already owned by the live primary Pi process")
        atomic_json(mirror_owner_path(home), {
            "owner_pid": owner_pid,
            "owner_identity": identity,
            "capability_sha256": digest,
            "opened_at": now(),
        })
    return 0


def mirror_authorized(home: Path, owner_pid: int, capability_fd: int) -> bool:
    capability = mirror_capability(capability_fd)
    identity = process_identity(owner_pid)
    if (owner_pid != os.getppid() or capability is None or identity is None
            or not mirror_owner_holds_lock(home, owner_pid)):
        return False
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        record = read_json(mirror_owner_path(home), {})
    return bool(
        isinstance(record, dict)
        and record.get("owner_pid") == owner_pid
        and record.get("owner_identity") == identity
        and record.get("capability_sha256")
        == hashlib.sha256(capability.encode("ascii")).hexdigest()
    )


def transport_reply(_home: Path) -> str:
    return QUEUED_RECEIPT


def reply_journal_path(home: Path) -> Path:
    return state_dir(home) / "reply-journal.json"


def _reply_journal_key(value: Optional[str]) -> Optional[str]:
    if value is None or not isinstance(value, str) or not value or len(value) > 256:
        return None
    return value


def _reply_message_id(value: Any) -> Optional[int]:
    return value if telegram_numeric_id(value, positive=True) else None


def _reply_target(config: Optional[Dict[str, Any]], chat_id: int,
                  message_id: Optional[int]) -> Optional[int]:
    if not strict_int(chat_id) or (config is not None and chat_id != config.get("chat_id")):
        raise TelegramError("Telegram reply chat is not the pinned private chat")
    if message_id is None:
        return None
    if _reply_message_id(message_id) is None:
        raise TelegramError("Telegram reply target is not a valid message id")
    return message_id


def _reply_journal_update(home: Path, key: Optional[str], **fields: Any) -> None:
    if key is None:
        return
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        current = read_json(reply_journal_path(home), {})
        values = current if isinstance(current, dict) else {}
        record = values.get(key)
        record = dict(record) if isinstance(record, dict) else {}
        record.update(fields)
        record["updated_at"] = now()
        values[key] = record
        if len(values) > MAX_SEEN:
            keep = sorted(values.items(), key=lambda item: item[1].get("updated_at", 0))[-MAX_SEEN:]
            values = dict(keep)
        atomic_json(reply_journal_path(home), values)


def _reply_journal_existing(home: Path, key: Optional[str]) -> Optional[Dict[str, Any]]:
    if key is None:
        return None
    with FileLock(state_lock(home)):
        current = read_json(reply_journal_path(home), {})
        record = current.get(key) if isinstance(current, dict) else None
        return dict(record) if isinstance(record, dict) else None


def outbound_message_id(result: Any) -> Optional[int]:
    return _reply_message_id(result.get("message_id")) if isinstance(result, dict) else None


def send_text(home: Path, chat_id: int, text: str,
              markup: Optional[Dict[str, Any]] = None,
              reply_to: Optional[int] = None,
              fallback_to: Optional[int] = None,
              journal_key: Optional[str] = None) -> Any:
    config = load_config(home)
    chat_id = int(chat_id)
    reply_to = _reply_target(config, chat_id, reply_to)
    fallback_to = _reply_target(config, chat_id, fallback_to)
    key = _reply_journal_key(journal_key)
    existing = _reply_journal_existing(home, key)
    if existing is not None:
        if existing.get("status") == "sent":
            return {"message_id": existing.get("outbound_message_id")}
        if existing.get("status") in {"sending", "delivery_unknown"}:
            raise TelegramError("Telegram reply delivery is unknown", delivery_unknown=True)
    targets: List[Optional[int]] = []
    for target in (reply_to, fallback_to, None):
        if target not in targets:
            targets.append(target)
    last_error: Optional[TelegramError] = None
    for target in targets:
        params: Dict[str, Any] = {"chat_id": chat_id, "text": text}
        if markup is not None:
            params["reply_markup"] = markup
        if target is not None:
            params["reply_parameters"] = {"message_id": target}
        _reply_journal_update(
            home, key, status="sending", chat_id=chat_id,
            target_message_id=target, outbound_message_id=None,
        )
        try:
            result = api_call(home, "sendMessage", params, config)
        except TelegramError as exc:
            last_error = exc
            if exc.delivery_unknown:
                _reply_journal_update(home, key, status="delivery_unknown")
                raise
            _reply_journal_update(home, key, status="rejected")
            continue
        message_id = outbound_message_id(result)
        _reply_journal_update(
            home, key, status="sent", chat_id=chat_id,
            target_message_id=target, outbound_message_id=message_id,
        )
        return result
    if last_error is not None:
        raise last_error
    raise TelegramError("Telegram reply could not be delivered")


def edit_message(home: Path, chat_id: int, message_id: int, text: str,
                  markup: Optional[Dict[str, Any]] = None,
                  journal_key: Optional[str] = None) -> Any:
    config = load_config(home)
    chat_id = int(chat_id)
    message_id = _reply_target(config, chat_id, message_id)
    if message_id is None:
        raise TelegramError("Telegram edit target is missing")
    key = _reply_journal_key(journal_key)
    existing = _reply_journal_existing(home, key)
    if existing is not None:
        if existing.get("status") == "sent":
            return {"message_id": message_id}
        if existing.get("status") in {"sending", "delivery_unknown"}:
            raise TelegramError("Telegram edit delivery is unknown", delivery_unknown=True)
    params: Dict[str, Any] = {"chat_id": chat_id, "message_id": message_id, "text": text}
    if markup is not None:
        params["reply_markup"] = markup
    _reply_journal_update(home, key, status="sending", chat_id=chat_id,
                          target_message_id=message_id)
    try:
        result = api_call(home, "editMessageText", params, config)
    except TelegramError as exc:
        _reply_journal_update(home, key, status=("delivery_unknown" if exc.delivery_unknown else "rejected"))
        raise
    _reply_journal_update(home, key, status="sent", chat_id=chat_id,
                          target_message_id=message_id, outbound_message_id=message_id)
    return result


def edit_reply_markup(home: Path, chat_id: int, message_id: int,
                      markup: Optional[Dict[str, Any]], journal_key: Optional[str] = None) -> Any:
    config = load_config(home)
    chat_id = int(chat_id)
    message_id = _reply_target(config, chat_id, message_id)
    if message_id is None:
        raise TelegramError("Telegram markup target is missing")
    key = _reply_journal_key(journal_key)
    existing = _reply_journal_existing(home, key)
    if existing is not None:
        if existing.get("status") == "sent":
            return {"message_id": message_id}
        if existing.get("status") in {"sending", "delivery_unknown"}:
            raise TelegramError("Telegram markup delivery is unknown", delivery_unknown=True)
    params = {"chat_id": chat_id, "message_id": message_id,
              "reply_markup": markup if markup is not None else EMPTY_INLINE_MARKUP}
    _reply_journal_update(home, key, status="sending", chat_id=chat_id,
                          target_message_id=message_id)
    try:
        result = api_call(home, "editMessageReplyMarkup", params, config)
    except TelegramError as exc:
        _reply_journal_update(home, key, status=("delivery_unknown" if exc.delivery_unknown else "rejected"))
        raise
    _reply_journal_update(home, key, status="sent", chat_id=chat_id,
                          target_message_id=message_id, outbound_message_id=message_id)
    return result


def mirror_owner_is_child(owner_pid: int) -> bool:
    return owner_pid == os.getppid()


def claim_owner_identity(owner_pid: int) -> Optional[str]:
    return process_identity(owner_pid) if mirror_owner_is_child(owner_pid) else None


def claim_owned_by(record: Dict[str, Any], owner_pid: int) -> bool:
    identity = claim_owner_identity(owner_pid)
    return bool(
        identity is not None
        and record.get("claim_owner_pid") == owner_pid
        and record.get("claim_owner_identity") == identity
    )


def bind_claim_owner(record: Dict[str, Any], owner_pid: int, identity: str) -> None:
    record["claim_owner_pid"] = owner_pid
    record["claim_owner_identity"] = identity
    record["claimed_at"] = now()


def clear_claim_owner(record: Dict[str, Any]) -> None:
    record.pop("claim_owner_pid", None)
    record.pop("claim_owner_identity", None)
    record.pop("claimed_at", None)


def mirror_queue_paths_locked(home: Path) -> List[Path]:
    inbox, _handled = request_dirs(home)
    return sorted(inbox.glob("*.json"), key=request_order_key)


def mirror_reconcile(home: Path, replacing_owner_pid: Optional[int] = None,
                     preserve_requests: Iterable[str] = (), report_held: bool = False,
                     report_deliveries: Iterable[str] = ()) -> int:
    marker = state_dir(home) / ".mirror-migration-v2"
    replacement_identity = None
    if replacing_owner_pid is not None:
        replacement_identity = claim_owner_identity(replacing_owner_pid)
        if replacement_identity is None:
            return die("Telegram mirror owner is not the invoking extension")
    preserved = {request_id for request_id in preserve_requests if safe_id(request_id)}
    reported_delivery_ids = {
        delivery_id for delivery_id in report_deliveries
        if safe_id(delivery_id) and len(delivery_id) <= 160
    }
    held_records: List[Tuple[str, str]] = []
    owned_records: List[str] = []
    delivery_records: List[Tuple[str, Optional[str], Optional[str]]] = []
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        if not marker.is_file():
            inbox, handled = request_dirs(home)
            for path in list(handled.glob("*.json")):
                record = read_json(path)
                if (not isinstance(record, dict) or record.get("origin") != "telegram"
                        or record.get("final_sent") is True or record.get("status") == "handled"):
                    continue
                target = inbox / path.name
                if not target.exists():
                    durable_replace(path, target)
            for legacy in (active_path(home), closing_path(home)):
                durable_unlink(legacy)
            legacy_responses = state_dir(home) / "responses"
            if legacy_responses.is_dir() and not legacy_responses.is_symlink():
                durable_rmtree(legacy_responses)
            for path in mirror_queue_paths_locked(home):
                record = read_json(path)
                if not isinstance(record, dict):
                    continue
                for field in ("continuation_of", "continuation_routing", "work_id",
                              "work_published", "initial_routing_consumed", "wake_recorded"):
                    record.pop(field, None)
                record["status"] = "queued"
                clear_claim_owner(record)
                atomic_json(path, record)
            atomic_bytes(marker, b"v2\n")
        _bounded_cleanup_locked(home, preserved)
        consume_safe_wakes(home, effective_wake_state(home))
        for path in mirror_queue_paths_locked(home):
            record = read_json(path)
            if not isinstance(record, dict):
                continue
            status = record.get("status")
            if status == "held":
                turn_id = record.get("held_turn_id")
                if isinstance(turn_id, str) and safe_id(turn_id):
                    held_records.append((path.stem, turn_id))
                continue
            owner = record.get("claim_owner_pid")
            owner_identity = record.get("claim_owner_identity")
            owner_alive = bool(
                strict_int(owner)
                and isinstance(owner_identity, str)
                and process_identity(owner) == owner_identity
            )
            if (path.stem in preserved and replacing_owner_pid is not None
                    and replacement_identity is not None and status in {"queued", "claimed"}):
                record["status"] = "claimed"
                bind_claim_owner(record, replacing_owner_pid, replacement_identity)
                atomic_json(path, record)
                owned_records.append(path.stem)
            elif status == "claimed" and (
                    not owner_alive
                    or (owner == replacing_owner_pid and owner_identity == replacement_identity)):
                record["status"] = "queued"
                clear_claim_owner(record)
                atomic_json(path, record)
        delivery_root = mirror_delivery_dir(home)
        for delivery_id in sorted(reported_delivery_ids):
            record = read_json(delivery_root / f"{delivery_id}.json")
            status = record.get("status") if isinstance(record, dict) else None
            completion_request = (record.get("completion_request_id")
                                  if isinstance(record, dict) else None)
            completion_path = (request_path(home, completion_request)
                               if isinstance(completion_request, str) else None)
            completion_record = read_json(completion_path) if completion_path is not None else None
            request_missing = completion_request if (
                isinstance(completion_request, str)
                and (not isinstance(completion_record, dict)
                     or completion_record.get("request_id") != completion_request
                     or completion_record.get("status") != "claimed")
            ) else None
            delivery_records.append((
                delivery_id,
                status if isinstance(status, str) else None,
                request_missing,
            ))
    if report_held:
        for request_id in owned_records:
            print(f"owned\t{request_id}")
        for request_id, turn_id in held_records[:1]:
            print(f"held\t{request_id}\t{turn_id}")
        for delivery_id, status, request_missing in delivery_records:
            if status is None:
                print(f"delivery-missing\t{delivery_id}")
            elif request_missing is not None:
                print(f"request-missing\t{delivery_id}\t{request_missing}")
            else:
                print(f"delivery\t{delivery_id}\t{status}")
    return 0


def mirror_list(home: Path) -> int:
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        paths = mirror_queue_paths_locked(home)
        for path in paths:
            record = read_json(path)
            if isinstance(record, dict) and record.get("status", "queued") == "queued":
                print(path.stem)
                return 0
    return 1


def mirror_claim(home: Path, request_id: str, owner_pid: int) -> int:
    identity = claim_owner_identity(owner_pid)
    if identity is None:
        return die("Telegram mirror owner is not the invoking extension")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        if not mirror_mode_enabled(home):
            return die("Telegram mirror mode is off")
        path = request_path(home, request_id)
        if path is None or path.parent.name != "inbox":
            return die("Telegram request is not queued")
        record = read_json(path)
        if not isinstance(record, dict) or record.get("origin") != "telegram":
            return die("Telegram request is malformed")
        status = record.get("status", "queued")
        if status == "claimed":
            if claim_owned_by(record, owner_pid):
                return 0
            current_owner = record.get("claim_owner_pid")
            current_identity = record.get("claim_owner_identity")
            if (strict_int(current_owner) and isinstance(current_identity, str)
                    and process_identity(current_owner) == current_identity):
                return die("Telegram request is already being processed")
        elif status != "queued":
            return die("Telegram request is not queued")
        record["status"] = "claimed"
        bind_claim_owner(record, owner_pid, identity)
        atomic_json(path, record)
    return 0


def mirror_read(home: Path, request_id: str, owner_pid: int) -> int:
    if not mirror_owner_is_child(owner_pid):
        return die("Telegram mirror owner is not the invoking extension")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        path = request_path(home, request_id)
        record = read_json(path) if path is not None else None
        if (path is None or path.parent.name != "inbox" or not isinstance(record, dict)
                or record.get("status") != "claimed" or not claim_owned_by(record, owner_pid)):
            return die("Telegram request is not owned by this extension")
        text = record.get("text")
        if not isinstance(text, str):
            return die("Telegram request is malformed")
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0


def mirror_release(home: Path, request_id: str, owner_pid: int) -> int:
    if not mirror_owner_is_child(owner_pid):
        return die("Telegram mirror owner is not the invoking extension")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        path = request_path(home, request_id)
        record = read_json(path) if path is not None else None
        if (path is None or path.parent.name != "inbox" or not isinstance(record, dict)
                or not claim_owned_by(record, owner_pid)):
            return 1
        record["status"] = "queued"
        clear_claim_owner(record)
        atomic_json(path, record)
    return 0


def mirror_hold(home: Path, request_id: str, turn_id: str, owner_pid: int) -> int:
    if not safe_id(turn_id) or not mirror_owner_is_child(owner_pid):
        return die("Telegram interrupted admission identity is invalid")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        path = request_path(home, request_id)
        record = read_json(path) if path is not None else None
        if path is None or path.parent.name != "inbox" or not isinstance(record, dict):
            return die("Telegram interrupted admission was not found")
        if record.get("status") == "held":
            return 0 if record.get("held_turn_id") == turn_id else 1
        if record.get("status") != "claimed" or not claim_owned_by(record, owner_pid):
            return die("Telegram interrupted admission is not owned by this extension")
        record["status"] = "held"
        record["held_at"] = now()
        record["held_turn_id"] = turn_id
        clear_claim_owner(record)
        atomic_json(path, record)
    return 0


def mirror_recover(home: Path, request_id: str, owner_pid: int) -> int:
    if not mirror_owner_is_child(owner_pid):
        return die("Telegram mirror owner is not the invoking extension")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        path = request_path(home, request_id)
        record = read_json(path) if path is not None else None
        if path is None:
            return 0
        if (path.parent.name != "inbox" or not isinstance(record, dict)
                or record.get("status") != "held"):
            return die("Telegram interrupted admission is not held")
        record["status"] = "queued"
        record.pop("held_at", None)
        record.pop("held_turn_id", None)
        atomic_json(path, record)
    return 0


def mirror_delivered(home: Path, request_id: str, owner_pid: int) -> int:
    if not mirror_owner_is_child(owner_pid):
        return die("Telegram mirror owner is not the invoking extension")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        path = request_path(home, request_id)
        record = read_json(path) if path is not None else None
        if (path is None or path.parent.name != "inbox" or not isinstance(record, dict)
                or record.get("status") != "claimed" or not claim_owned_by(record, owner_pid)):
            return die("Telegram request is not owned by this extension")
        if record.get("delivery_status") == "sent":
            return 0
        record["delivery_status"] = "sending"
        atomic_json(path, record)
        chat_id = record.get("chat_id")
        source_message_id = record.get("message_id")
    try:
        result = send_text(
            home, int(chat_id), PI_DELIVERED_RECEIPT,
            reply_to=int(source_message_id), fallback_to=int(source_message_id),
            journal_key=f"{request_id}:pi-delivered",
        )
    except TelegramError:
        with FileLock(state_lock(home)):
            current = read_json(path)
            if isinstance(current, dict) and claim_owned_by(current, owner_pid):
                current["delivery_status"] = "delivery_unknown"
                atomic_json(path, current)
        return 1
    with FileLock(state_lock(home)):
        current = read_json(path)
        if isinstance(current, dict) and claim_owned_by(current, owner_pid):
            current["delivery_status"] = "sent"
            current["delivery_message_id"] = outbound_message_id(result)
            atomic_json(path, current)
    return 0


def mirror_delivery_dir(home: Path) -> Path:
    path = state_dir(home) / "deliveries"
    private_dir(path)
    return path


def mirror_delivery_body(text_file: str) -> Tuple[bytes, List[Dict[str, Any]]]:
    try:
        body = text_from_file(text_file).encode("utf-8")
        chunks = split_telegram_response(body)
    except (OSError, UnicodeError) as exc:
        raise TelegramError("Telegram delivery body is not valid UTF-8") from exc
    if len(body) > MAX_MIRROR_DELIVERY_BYTES:
        raise TelegramError("Telegram delivery exceeds the response limit")
    if not chunks or len(chunks) > MAX_MIRROR_DELIVERY_CHUNKS:
        raise TelegramError("Telegram delivery exceeds the chunk limit")
    return body, chunks


def mirror_validate(text_file: str) -> int:
    try:
        mirror_delivery_body(text_file)
    except TelegramError as exc:
        return die(str(exc))
    return 0


def mirror_reserve(home: Path, delivery_id: str, owner_pid: int, text_file: str,
                   accepted_input: bool = False) -> int:
    identity = claim_owner_identity(owner_pid)
    if identity is None:
        return die("Telegram mirror owner is not the invoking extension")
    if not safe_id(delivery_id) or len(delivery_id) > 160:
        return die("Telegram delivery identity is invalid")
    try:
        body, chunks = mirror_delivery_body(text_file)
    except TelegramError as exc:
        return die(str(exc))
    root = mirror_delivery_dir(home)
    body_path = root / f"{delivery_id}.txt"
    metadata_path = root / f"{delivery_id}.json"
    digest = hashlib.sha256(body).hexdigest()
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        if not accepted_input and not mirror_mode_enabled(home):
            return die("Telegram mirror mode is off")
        existing = read_json(metadata_path)
        if isinstance(existing, dict):
            if existing.get("sha256") != digest:
                return die("Telegram delivery identity is already bound to different content")
            if (existing.get("status") == "reserved"
                    and existing.get("reservation_owner_pid") == owner_pid
                    and existing.get("reservation_owner_identity") == identity):
                return 0
            return die("Telegram delivery identity is already in use")
        if not cleanup_mirror_deliveries_locked(home, reserve_slots=1):
            return die("Telegram delivery journal has no bounded free slot")
        atomic_bytes(body_path, body)
        atomic_json(metadata_path, {
            "delivery_id": delivery_id,
            "sha256": digest,
            "status": "reserved",
            "created_at": now(),
            "chunks": chunks,
            "reservation_owner_pid": owner_pid,
            "reservation_owner_identity": identity,
        })
    return 0


def mirror_cancel(home: Path, delivery_id: str, owner_pid: int) -> int:
    identity = claim_owner_identity(owner_pid)
    if identity is None or not safe_id(delivery_id) or len(delivery_id) > 160:
        return die("Telegram delivery reservation identity is invalid")
    root = mirror_delivery_dir(home)
    body_path = root / f"{delivery_id}.txt"
    metadata_path = root / f"{delivery_id}.json"
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        record = read_json(metadata_path)
        if record is None:
            return 0
        if (not isinstance(record, dict) or record.get("status") != "reserved"
                or record.get("reservation_owner_pid") != owner_pid
                or record.get("reservation_owner_identity") != identity):
            return die("Telegram delivery reservation is not owned by this extension")
        durable_unlink(metadata_path)
        durable_unlink(body_path)
    return 0


def mirror_reply(home: Path, delivery_id: str, owner_pid: int, text_file: str,
                 request_id: Optional[str] = None) -> int:
    if not mirror_owner_is_child(owner_pid):
        return die("Telegram mirror owner is not the invoking extension")
    if (not safe_id(delivery_id) or len(delivery_id) > 160
            or (request_id is not None and not safe_id(request_id))):
        return die("Telegram delivery identity is invalid")
    try:
        body, chunks = mirror_delivery_body(text_file)
    except TelegramError as exc:
        return die(str(exc))
    root = mirror_delivery_dir(home)
    body_path = root / f"{delivery_id}.txt"
    metadata_path = root / f"{delivery_id}.json"
    digest = hashlib.sha256(body).hexdigest()
    delivery_pid = os.getpid()
    delivery_identity = process_identity(delivery_pid)
    if delivery_identity is None:
        return die("Telegram delivery process identity is unavailable")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        if request_id is not None:
            retire_superseded_completion_deliveries_locked(home, request_id, delivery_id)
        existing = read_json(metadata_path)
        if isinstance(existing, dict):
            if existing.get("sha256") != digest:
                return die("Telegram delivery identity is already bound to different content")
            existing_request = existing.get("completion_request_id")
            if request_id is not None and existing_request not in {None, request_id}:
                return die("Telegram delivery identity is already bound to another request")
            if request_id is not None and existing_request is None:
                existing["completion_request_id"] = request_id
                atomic_json(metadata_path, existing)
            if existing.get("status") == "sent":
                return 0
            if existing.get("status") == "delivery_unknown":
                return DELIVERY_UNKNOWN_EXIT
            record = existing
            if record.get("status") == "reserved":
                reservation_identity = claim_owner_identity(owner_pid)
                if (reservation_identity is None
                        or record.get("reservation_owner_pid") != owner_pid
                        or record.get("reservation_owner_identity") != reservation_identity):
                    return die("Telegram delivery reservation is not owned by this extension")
                record.pop("reservation_owner_pid", None)
                record.pop("reservation_owner_identity", None)
                record["status"] = "pending"
            if not isinstance(record.get("chunks"), list):
                record["chunks"] = chunks
            previous_pid = record.get("delivery_owner_pid")
            previous_identity = record.get("delivery_owner_identity")
            previous_owner_live = bool(
                strict_int(previous_pid)
                and isinstance(previous_identity, str)
                and process_identity(previous_pid) == previous_identity
            )
            if previous_owner_live:
                return die("Telegram delivery is already in flight")
            if any(chunk.get("telegram_status") == "sending" for chunk in record["chunks"]):
                for chunk in record["chunks"]:
                    if chunk.get("telegram_status") == "sending":
                        chunk["telegram_status"] = "delivery_unknown"
                record["status"] = "delivery_unknown"
                record.pop("delivery_owner_pid", None)
                record.pop("delivery_owner_identity", None)
                atomic_json(metadata_path, record)
                return DELIVERY_UNKNOWN_EXIT
        else:
            if not cleanup_mirror_deliveries_locked(home, reserve_slots=1):
                return die("Telegram delivery journal has no bounded free slot")
            atomic_bytes(body_path, body)
            record = {"delivery_id": delivery_id, "sha256": digest, "status": "pending",
                      "created_at": now(), "chunks": chunks}
        if request_id is not None:
            record["completion_request_id"] = request_id
        record["delivery_owner_pid"] = delivery_pid
        record["delivery_owner_identity"] = delivery_identity
        atomic_json(metadata_path, record)
        config = load_config(home)
        chat_id = int(config["chat_id"])
        source_message_id: Optional[int] = None
        if request_id is not None:
            request_path_value = request_path(home, request_id)
            request_record = read_json(request_path_value) if request_path_value is not None else None
            if isinstance(request_record, dict) and request_record.get("chat_id") == chat_id:
                source_message_id = _reply_message_id(request_record.get("message_id"))
    try:
        while True:
            with FileLock(state_lock(home)):
                record = read_json(metadata_path)
                if (not isinstance(record, dict) or record.get("sha256") != digest
                        or record.get("delivery_owner_pid") != delivery_pid
                        or record.get("delivery_owner_identity") != delivery_identity):
                    return die("Telegram delivery record changed during delivery")
                current_chunks = record.get("chunks")
                if not isinstance(current_chunks, list):
                    return die("Telegram delivery record is malformed")
                index = next((position for position, chunk in enumerate(current_chunks)
                              if chunk.get("telegram_status") in {"pending", "rejected"}), None)
                if index is None:
                    record["status"] = aggregate_response_delivery(current_chunks)
                    atomic_json(metadata_path, record)
                    return 0 if record["status"] == "sent" else DELIVERY_UNKNOWN_EXIT
                chunk = current_chunks[index]
                attempts = chunk.get("telegram_attempts", 0)
                if not strict_int(attempts) or attempts < 0:
                    return die("Telegram delivery record is malformed")
                if attempts >= MAX_MIRROR_DELIVERY_ATTEMPTS:
                    record["status"] = "rejected"
                    atomic_json(metadata_path, record)
                    print("delivery-rejected")
                    return 1
                chunk["telegram_attempts"] = attempts + 1
                chunk["telegram_status"] = "sending"
                chunk["telegram_attempted_at"] = now()
                record["status"] = "sending"
                atomic_json(metadata_path, record)
                start = chunk.get("start")
                end = chunk.get("end")
                if not strict_int(start) or not strict_int(end) or start < 0 or end <= start:
                    return die("Telegram delivery record is malformed")
                chunk_text = body[start:end].decode("utf-8")
            previous_message_id = None
            for prior in current_chunks[:index]:
                candidate = _reply_message_id(prior.get("outbound_message_id"))
                if candidate is not None:
                    previous_message_id = candidate
            reply_target = previous_message_id or source_message_id
            try:
                result = send_text(
                    home, chat_id, chunk_text,
                    reply_to=reply_target, fallback_to=source_message_id,
                    journal_key=f"delivery:{delivery_id}:chunk:{index}",
                )
            except TelegramError as exc:
                with FileLock(state_lock(home)):
                    record = read_json(metadata_path)
                    if isinstance(record, dict) and isinstance(record.get("chunks"), list):
                        chunk = record["chunks"][index]
                        chunk["telegram_status"] = ("delivery_unknown"
                                                    if exc.delivery_unknown else "rejected")
                        record["status"] = aggregate_response_delivery(record["chunks"])
                        atomic_json(metadata_path, record)
                if exc.delivery_unknown:
                    return DELIVERY_UNKNOWN_EXIT
                if attempts + 1 >= MAX_MIRROR_DELIVERY_ATTEMPTS:
                    print("delivery-rejected")
                    return 1
                continue
            with FileLock(state_lock(home)):
                record = read_json(metadata_path)
                if (not isinstance(record, dict) or not isinstance(record.get("chunks"), list)
                        or record.get("delivery_owner_pid") != delivery_pid
                        or record.get("delivery_owner_identity") != delivery_identity):
                    return die("Telegram delivery record changed during delivery")
                record["chunks"][index]["telegram_status"] = "sent"
                record["chunks"][index]["telegram_sent_at"] = now()
                record["chunks"][index]["reply_to_message_id"] = reply_target
                record["chunks"][index]["outbound_message_id"] = outbound_message_id(result)
                record["status"] = aggregate_response_delivery(record["chunks"])
                atomic_json(metadata_path, record)
    finally:
        with FileLock(state_lock(home)):
            record = read_json(metadata_path)
            if (isinstance(record, dict)
                    and record.get("delivery_owner_pid") == delivery_pid
                    and record.get("delivery_owner_identity") == delivery_identity):
                record.pop("delivery_owner_pid", None)
                record.pop("delivery_owner_identity", None)
                atomic_json(metadata_path, record)


def mirror_abandon(home: Path, request_id: str, delivery_id: str, owner_pid: int) -> int:
    if not mirror_owner_is_child(owner_pid):
        return die("Telegram mirror owner is not the invoking extension")
    if not safe_id(request_id) or not safe_id(delivery_id):
        return die("Telegram abandonment identity is invalid")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        inbox, handled = request_dirs(home)
        source = inbox / f"{request_id}.json"
        target = handled / source.name
        if target.is_file() and not target.is_symlink():
            record = read_json(target)
            return 0 if isinstance(record, dict) and record.get("request_id") == request_id else 1
        record = read_json(source)
        if record is None:
            return 0
        status = record.get("status") if isinstance(record, dict) else None
        owned_claim = status == "claimed" and claim_owned_by(record, owner_pid)
        if (not isinstance(record, dict) or record.get("request_id") != request_id
                or not (owned_claim or status == "held")):
            return die("Telegram request is not owned by this extension")
        record["status"] = "abandoned"
        record["failure_delivery_id"] = delivery_id
        record["abandoned_at"] = now()
        record.pop("held_at", None)
        record.pop("held_turn_id", None)
        clear_claim_owner(record)
        atomic_json(source, record)
        durable_replace(source, target)
        private_file(target)
        delivery_path = mirror_delivery_dir(home) / f"{delivery_id}.json"
        delivery = read_json(delivery_path)
        if (isinstance(delivery, dict)
                and delivery.get("completion_request_id") == request_id
                and delivery.get("status") != "sent"):
            delivery.pop("completion_request_id", None)
            atomic_json(delivery_path, delivery)
    return 0


def mirror_complete(home: Path, request_id: str, delivery_id: str, owner_pid: int) -> int:
    if not mirror_owner_is_child(owner_pid):
        return die("Telegram mirror owner is not the invoking extension")
    if not safe_id(request_id) or not safe_id(delivery_id):
        return die("Telegram completion identity is invalid")
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        inbox, handled = request_dirs(home)
        source = inbox / f"{request_id}.json"
        target = handled / source.name
        if target.is_file() and not target.is_symlink():
            record = read_json(target)
            return 0 if isinstance(record, dict) and record.get("delivery_id") == delivery_id else 1
        record = read_json(source)
        delivery = read_json(mirror_delivery_dir(home) / f"{delivery_id}.json")
        if (not isinstance(record, dict) or record.get("request_id") != request_id
                or record.get("status") != "claimed" or not claim_owned_by(record, owner_pid)):
            return die("Telegram request is not owned by this extension")
        if (not isinstance(delivery, dict) or delivery.get("delivery_id") != delivery_id
                or delivery.get("status") != "sent"
                or delivery.get("completion_request_id") != request_id):
            return die("Telegram assistant delivery is not definitively settled")
        record["status"] = "handled"
        record["delivery_id"] = delivery_id
        record["completed_at"] = now()
        clear_claim_owner(record)
        atomic_json(source, record)
        durable_replace(source, target)
        private_file(target)
        delivery.pop("completion_request_id", None)
        atomic_json(mirror_delivery_dir(home) / f"{delivery_id}.json", delivery)
    return 0


def answer_callback(home: Path, callback_id: str) -> None:
    if isinstance(callback_id, str) and callback_id:
        key = "callback:" + hashlib.sha256(callback_id.encode("utf-8")).hexdigest()
        existing = _reply_journal_existing(home, key)
        if existing is not None and existing.get("status") == "sent":
            return
        _reply_journal_update(home, key, status="sending")
        try:
            api_call(home, "answerCallbackQuery", {"callback_query_id": callback_id})
        except TelegramError as exc:
            _reply_journal_update(
                home, key, status=("delivery_unknown" if exc.delivery_unknown else "rejected")
            )
            return
        _reply_journal_update(home, key, status="sent")


def pending_path(home: Path) -> Path:
    return state_dir(home) / "pending.json"


def pending_voice_queue_path(home: Path) -> Path:
    return state_dir(home) / "pending-voice-queue.json"


def valid_pending_voice_record(value: Any) -> bool:
    required = {
        "pending_id", "file_id", "duration", "size", "chat_id",
        "message_id", "update_id", "queued_at",
    }
    optional = {
        "queued_notice_status", "queued_notice_attempts", "queued_notice_attempted_at",
        "queued_notice_message_id",
    }
    if (not isinstance(value, dict) or not required.issubset(value)
            or not set(value).issubset(required | optional)):
        return False
    pending_id = value.get("pending_id")
    file_id = value.get("file_id")
    duration = value.get("duration")
    size = value.get("size")
    chat_id = value.get("chat_id")
    message_id = value.get("message_id")
    update_id = value.get("update_id")
    queued_at = value.get("queued_at")
    if (not isinstance(file_id, str) or not file_id.strip() or "\x00" in file_id
            or unicode_text_units(file_id) is None):
        return False
    if (not strict_int(duration) or duration < 0 or duration > MAX_VOICE_SECONDS
            or not strict_int(size) or size < 0 or size > MAX_VOICE_BYTES
            or not telegram_numeric_id(chat_id, positive=True)
            or not telegram_numeric_id(message_id, positive=True)
            or not telegram_numeric_id(update_id)
            or not strict_int(queued_at) or queued_at <= 0):
        return False
    status = value.get("queued_notice_status", "pending")
    attempts = value.get("queued_notice_attempts", 0)
    if status not in {
            "not_required", "pending", "sending", "delivery_unknown", "rejected",
            "sent", "delivery_unknown_terminal", "rejected_terminal",
    }:
        return False
    if not strict_int(attempts) or attempts < 0 or attempts > CALLBACK_DELIVERY_ATTEMPTS:
        return False
    attempted_at = value.get("queued_notice_attempted_at")
    if attempted_at is not None and (not strict_int(attempted_at) or attempted_at <= 0):
        return False
    outbound_id = value.get("queued_notice_message_id")
    if outbound_id is not None and _reply_message_id(outbound_id) is None:
        return False
    return pending_id == f"voice-u{update_id}-m{message_id}"


def load_pending_voice_queue_locked(home: Path) -> Tuple[List[Dict[str, Any]], bool]:
    raw = read_json(pending_voice_queue_path(home), [])
    values = raw if isinstance(raw, list) else []
    cutoff = now() - INBOX_TTL
    records: List[Dict[str, Any]] = []
    identifiers = set()
    for value in values:
        if (not valid_pending_voice_record(value)
                or int(value["queued_at"]) < cutoff
                or value["pending_id"] in identifiers):
            continue
        identifiers.add(value["pending_id"])
        record = dict(value)
        record.setdefault("queued_notice_status", "pending")
        record.setdefault("queued_notice_attempts", 0)
        records.append(record)
        if len(records) >= MAX_PENDING_VOICES:
            break
    return records, raw != records


def save_pending_voice_queue_locked(home: Path, records: List[Dict[str, Any]]) -> None:
    if records:
        atomic_json(pending_voice_queue_path(home), records[:MAX_PENDING_VOICES])
    else:
        durable_unlink(pending_voice_queue_path(home))


def remove_pending_voice_locked(home: Path, pending_id: str) -> None:
    records, _ = load_pending_voice_queue_locked(home)
    retained = [record for record in records if record.get("pending_id") != pending_id]
    save_pending_voice_queue_locked(home, retained)


def queued_voice_notice_settled(record: Dict[str, Any]) -> bool:
    return record.get("queued_notice_status") in {
        "not_required", "sent", "delivery_unknown_terminal", "rejected_terminal",
    }


def reconcile_queued_voice_notice(home: Path, pending_id: str) -> bool:
    with FileLock(state_lock(home)):
        records, changed = load_pending_voice_queue_locked(home)
        index = next(
            (position for position, record in enumerate(records)
             if record.get("pending_id") == pending_id),
            None,
        )
        if index is None:
            if changed:
                save_pending_voice_queue_locked(home, records)
            return True
        record = records[index]
        if queued_voice_notice_settled(record):
            seen_update(home, int(record["update_id"]), int(record["message_id"]))
            if changed:
                save_pending_voice_queue_locked(home, records)
            return True
        attempts = int(record.get("queued_notice_attempts", 0))
        if attempts >= CALLBACK_DELIVERY_ATTEMPTS:
            record["queued_notice_status"] = (
                "delivery_unknown_terminal"
                if record.get("queued_notice_status") in {"sending", "delivery_unknown"}
                else "rejected_terminal"
            )
            records[index] = record
            save_pending_voice_queue_locked(home, records)
            seen_update(home, int(record["update_id"]), int(record["message_id"]))
            return True
        attempts += 1
        record["queued_notice_attempts"] = attempts
        record["queued_notice_status"] = "sending"
        record["queued_notice_attempted_at"] = now()
        records[index] = record
        save_pending_voice_queue_locked(home, records)
        chat_id = int(record["chat_id"])
        message_id = int(record["message_id"])
    try:
        result = send_text(
            home, chat_id, VOICE_QUEUED_NOTICE,
            reply_to=message_id, fallback_to=message_id,
            journal_key=f"voice:{pending_id}:queued",
        )
    except TelegramError as exc:
        with FileLock(state_lock(home)):
            records, _ = load_pending_voice_queue_locked(home)
            for index, current in enumerate(records):
                if (current.get("pending_id") == pending_id
                        and current.get("queued_notice_attempts") == attempts):
                    terminal = attempts >= CALLBACK_DELIVERY_ATTEMPTS
                    if exc.delivery_unknown:
                        current["queued_notice_status"] = (
                            "delivery_unknown_terminal" if terminal else "delivery_unknown"
                        )
                    else:
                        current["queued_notice_status"] = (
                            "rejected_terminal" if terminal else "rejected"
                        )
                    records[index] = current
                    save_pending_voice_queue_locked(home, records)
                    if terminal:
                        seen_update(
                            home, int(current["update_id"]), int(current["message_id"])
                        )
                    return terminal
        return False
    with FileLock(state_lock(home)):
        records, _ = load_pending_voice_queue_locked(home)
        for index, current in enumerate(records):
            if (current.get("pending_id") == pending_id
                    and current.get("queued_notice_attempts") == attempts):
                current["queued_notice_status"] = "sent"
                outbound_id = outbound_message_id(result)
                if outbound_id is not None:
                    current["queued_notice_message_id"] = outbound_id
                records[index] = current
                save_pending_voice_queue_locked(home, records)
                seen_update(home, int(current["update_id"]), int(current["message_id"]))
                return True
    return False


def reconcile_queued_voice_notices(home: Path) -> None:
    with FileLock(state_lock(home)):
        records, changed = load_pending_voice_queue_locked(home)
        if changed:
            save_pending_voice_queue_locked(home, records)
        pending_ids = [record["pending_id"] for record in records]
    for pending_id in pending_ids:
        try:
            reconcile_queued_voice_notice(home, pending_id)
        except (TelegramError, KeyError, TypeError, ValueError):
            continue


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
        durable_unlink(path)


def remove_pending(home: Path, data: Optional[Dict[str, Any]] = None) -> None:
    if data is None:
        data = read_json(pending_path(home), {})
    if isinstance(data, dict):
        remove_audio(data)
    durable_unlink(pending_path(home))


def finalize_pending_cleanup_locked(home: Path, data: Dict[str, Any],
                                    accepted_token: Optional[str] = None) -> None:
    pending_id = data.get("pending_id")
    if isinstance(pending_id, str) and safe_id(pending_id):
        tokens = data.get("completed_actions", [])
        values = ([value for value in tokens if isinstance(value, str)]
                  if isinstance(tokens, list) else [])
        for key in ("send_token", "cancel_token", "retry_token"):
            value = data.get(key)
            if isinstance(value, str):
                values.append(value)
        if isinstance(accepted_token, str):
            values.append(accepted_token)
        for token in dict.fromkeys(values):
            remember_callback_locked(home, pending_id, token)
    remove_pending(home, data)


def save_pending(home: Path, data: Dict[str, Any]) -> None:
    atomic_json(pending_path(home), data)


def command_for(config: Dict[str, Any], kind: str) -> Tuple[str, bool]:
    env_key = "FM_TELEGRAM_PARAKEET_CMD" if kind == "parakeet" else "FM_TELEGRAM_WHISPER_CMD"
    value = os.environ.get(env_key)
    environment_override = value is not None
    if value is None:
        value = config.get("parakeet_command" if kind == "parakeet" else "whisper_command")
    if not value:
        value = "parakeet-tdt-0.6b-v3" if kind == "parakeet" else "whisper-small-q8"
    return str(value), environment_override


def transcribe(home: Path, config: Dict[str, Any], audio: Path, kind: str) -> str:
    command, environment_override = command_for(config, kind)
    parts = shlex.split(command) if environment_override else (
        [command] if command.startswith("/") else shlex.split(command)
    )
    if not parts:
        raise TelegramError("voice transcription command is empty")
    if any("{audio}" in part for part in parts):
        parts = [part.replace("{audio}", str(audio)) for part in parts]
    else:
        parts.append(str(audio))
    try:
        completed = subprocess.run(parts, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, timeout=180, check=True)
    except (OSError, subprocess.SubprocessError, UnicodeError) as exc:
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


def deliver_pending_message(home: Path, pending_id: str, revision: int,
                            mode: str, field: str, text: str,
                            markup: Optional[Dict[str, Any]] = None) -> bool:
    status_field = f"{field}_delivery"
    attempts_field = f"{field}_attempts"
    legacy_field = f"{field}_sent"
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                or current.get("mode") != mode or current.get("revision") != revision):
            return False
        if current.get(legacy_field) is True or current.get(status_field) == "sent":
            return True
        attempts = current.get(attempts_field, 0)
        if not strict_int(attempts) or attempts < 0:
            attempts = 0
        if attempts >= CALLBACK_DELIVERY_ATTEMPTS:
            current[status_field] = "delivery_unknown_terminal"
            save_pending(home, current)
            return False
        attempts += 1
        current[attempts_field] = attempts
        current[status_field] = "sending"
        current[f"{field}_attempted_at"] = now()
        save_pending(home, current)
        chat_id = int(current["chat_id"])
    reply_to = current.get("message_id")
    if field == "edit_prompt":
        reply_to = current.get("transcript_message_id") or current.get("message_id")
    try:
        result = send_text(
            home, chat_id, text, markup,
            reply_to=int(reply_to), fallback_to=int(current["message_id"]),
            journal_key=f"voice:{pending_id}:{revision}:{field}",
        )
    except TelegramError as exc:
        with FileLock(state_lock(home)):
            current = read_json(pending_path(home))
            if (isinstance(current, dict) and current.get("pending_id") == pending_id
                    and current.get("mode") == mode and current.get("revision") == revision
                    and current.get(attempts_field) == attempts
                    and current.get(status_field) == "sending"):
                terminal = attempts >= CALLBACK_DELIVERY_ATTEMPTS
                if exc.delivery_unknown:
                    current[status_field] = (
                        "delivery_unknown_terminal" if terminal else "delivery_unknown"
                    )
                else:
                    current[status_field] = "rejected_terminal" if terminal else "rejected"
                save_pending(home, current)
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                or current.get("mode") != mode or current.get("revision") != revision
                or current.get(attempts_field) != attempts):
            return False
        current[status_field] = "sent"
        current[legacy_field] = True
        sent_message_id = outbound_message_id(result)
        if sent_message_id is not None:
            current[f"{field}_message_id"] = sent_message_id
        save_pending(home, current)
    return True


def show_confirmation(home: Path, config: Dict[str, Any], pending: Dict[str, Any]) -> None:
    pending_id = pending.get("pending_id")
    revision = pending.get("revision")
    if not isinstance(pending_id, str) or not strict_int(revision) or revision <= 0:
        raise TelegramError("voice confirmation revision is invalid")
    text = pending.get("text")
    if not isinstance(text, str):
        raise TelegramError("voice transcript is malformed")
    text_units = unicode_text_units(text)
    if text_units is None or text_units > MAX_TRANSCRIPT_UNITS:
        raise TelegramError("voice transcript is malformed or exceeds Telegram's message limit")
    if not deliver_pending_message(
            home, pending_id, revision, "confirm", "heading", "I heard this:"):
        return
    transcript_message_id = pending.get("transcript_message_id")
    markup = confirmation_markup(pending_id, revision)
    if strict_int(transcript_message_id) and transcript_message_id > 0:
        try:
            edit_message(
                home, int(pending["chat_id"]), transcript_message_id, text, markup,
                journal_key=f"voice:{pending_id}:{revision}:transcript-edit",
            )
            with FileLock(state_lock(home)):
                current = read_json(pending_path(home))
                if (isinstance(current, dict) and current.get("pending_id") == pending_id
                        and current.get("revision") == revision):
                    current["transcript_delivery"] = "sent"
                    current["transcript_sent"] = True
                    save_pending(home, current)
            return
        except TelegramError as exc:
            if exc.delivery_unknown:
                return
    deliver_pending_message(
        home, pending_id, revision, "confirm", "transcript", text, markup,
    )


def pending_confirmation_update(home: Path, pending: Dict[str, Any], text: str,
                                markup: Optional[Dict[str, Any]], key_suffix: str) -> bool:
    pending_id = pending.get("pending_id")
    message_id = pending.get("transcript_message_id")
    chat_id = pending.get("chat_id")
    source_message_id = pending.get("message_id")
    if (not isinstance(pending_id, str) or not strict_int(chat_id)
            or not strict_int(source_message_id)):
        return False
    if strict_int(message_id) and message_id > 0:
        try:
            edit_message(
                home, chat_id, message_id, text, markup,
                journal_key=f"voice:{pending_id}:{pending.get('revision')}:{key_suffix}",
            )
            return True
        except TelegramError as exc:
            if exc.delivery_unknown:
                return False
    try:
        result = send_text(
            home, chat_id, text, markup,
            reply_to=source_message_id, fallback_to=source_message_id,
            journal_key=f"voice:{pending_id}:{pending.get('revision')}:{key_suffix}-fallback",
        )
    except TelegramError:
        return False
    new_message_id = outbound_message_id(result)
    if new_message_id is not None:
        with FileLock(state_lock(home)):
            current = read_json(pending_path(home))
            if isinstance(current, dict) and current.get("pending_id") == pending_id:
                current["transcript_message_id"] = new_message_id
                save_pending(home, current)
    return True


def complete_initial_transcription(home: Path, config: Dict[str, Any],
                                   pending: Dict[str, Any]) -> bool:
    pending_id = pending.get("pending_id")
    audio_value = pending.get("audio_path")
    file_id = pending.get("file_id")
    if (not isinstance(pending_id, str) or not isinstance(audio_value, str)
            or not isinstance(file_id, str)):
        with FileLock(state_lock(home)):
            current = read_json(pending_path(home))
            if isinstance(current, dict) and current.get("pending_id") == pending_id:
                finalize_pending_cleanup_locked(home, current)
                if isinstance(pending_id, str):
                    remove_pending_voice_locked(home, pending_id)
        return False
    if not send_voice_progress(home, pending):
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                or current.get("mode") != "transcribing"
                or current.get("progress_status") not in {
                    "sent", "delivery_unknown_terminal", "rejected_terminal",
                }):
            return False
        pending = dict(current)
    audio = Path(audio_value)
    try:
        remove_audio(pending)
        result = api_call(home, "getFile", {"file_id": file_id}, config)
        if not isinstance(result, dict) or not isinstance(result.get("file_path"), str):
            raise TelegramError("Telegram returned no voice file")
        descriptor = os.open(audio, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        download_file(home, str(result["file_path"]), audio, config)
        transcript = transcribe(home, config, audio, "parakeet")
        with FileLock(state_lock(home)):
            current = read_json(pending_path(home))
            if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                    or current.get("mode") != "transcribing"):
                remove_audio(pending)
                return False
            current.update({
                "mode": "confirm",
                "text": transcript,
                "heading_sent": False,
                "transcript_sent": False,
            })
            current.pop("file_id", None)
            remove_pending_voice_locked(home, pending_id)
            save_pending(home, current)
            confirmed = dict(current)
    except (TelegramError, OSError):
        with FileLock(state_lock(home)):
            current = read_json(pending_path(home))
            if (isinstance(current, dict) and current.get("pending_id") == pending_id
                    and current.get("mode") == "transcribing"):
                finalize_pending_cleanup_locked(home, current)
                remove_pending_voice_locked(home, pending_id)
            else:
                remove_audio(pending)
        try:
            send_text(
                home, int(config["chat_id"]), "I couldn't transcribe that voice note.",
                reply_to=int(pending.get("message_id")),
                fallback_to=int(pending.get("message_id")),
                journal_key=f"voice:{pending_id}:transcription-failed",
            )
        except (TelegramError, TypeError, ValueError):
            pass
        return False
    try:
        show_confirmation(home, config, confirmed)
    except (TelegramError, OSError, KeyError, TypeError, ValueError):
        pass
    return True


def complete_retry(home: Path, config: Dict[str, Any], pending: Dict[str, Any]) -> bool:
    pending_id = pending.get("pending_id")
    retry_token = pending.get("retry_token")
    revision = pending.get("revision")
    if (not isinstance(pending_id, str) or not isinstance(retry_token, str)
            or not strict_int(revision) or revision <= 0):
        return False
    try:
        transcript = transcribe(home, config, Path(str(pending["audio_path"])), "whisper")
    except (TelegramError, OSError, KeyError, TypeError, ValueError):
        with FileLock(state_lock(home)):
            current = read_json(pending_path(home))
            if (isinstance(current, dict) and current.get("pending_id") == pending_id
                    and current.get("mode") == "retry"
                    and current.get("retry_token") == retry_token
                    and current.get("revision") == revision):
                current["mode"] = "confirm"
                current["revision"] = revision + 1
                current["retry_failed"] = True
                current.pop("retry_token", None)
                save_pending(home, current)
                failed = dict(current)
            else:
                failed = None
        if failed is not None:
            pending_confirmation_update(
                home, failed,
                "Whisper retry failed. Choose Retry with Whisper to try again, or edit the transcript.",
                confirmation_markup(pending_id, int(failed["revision"])), "retry-failed",
            )
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                or current.get("mode") != "retry"
                or current.get("retry_token") != retry_token
                or current.get("revision") != revision):
            return False
        current["text"] = transcript
        current["mode"] = "confirm"
        current["revision"] = revision + 1
        current["heading_sent"] = False
        current["transcript_sent"] = False
        for field in ("heading_delivery", "heading_attempts", "heading_attempted_at",
                      "transcript_delivery", "transcript_attempts", "transcript_attempted_at"):
            current.pop(field, None)
        current.pop("retry_token", None)
        save_pending(home, current)
        remember_callback_locked(home, pending_id, retry_token)
        confirmed = dict(current)
    try:
        show_confirmation(home, config, confirmed)
    except (TelegramError, OSError, KeyError, TypeError, ValueError):
        pass
    return True


def complete_cancel(home: Path, pending: Dict[str, Any]) -> bool:
    pending_id = pending.get("pending_id")
    cancel_token = pending.get("cancel_token")
    revision = pending.get("revision")
    if (not isinstance(pending_id, str) or not isinstance(cancel_token, str)
            or not strict_int(revision)):
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if not isinstance(current, dict):
            return completed_callback_locked(home, pending_id, cancel_token)
        if (current.get("pending_id") != pending_id or current.get("mode") != "canceling"
                or current.get("cancel_token") != cancel_token
                or current.get("revision") != revision):
            return False
        snapshot = dict(current)
    if not pending_confirmation_update(home, snapshot, "Cancelled", EMPTY_INLINE_MARKUP, "cancelled"):
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                or current.get("mode") != "canceling" or current.get("cancel_token") != cancel_token
                or current.get("revision") != revision):
            return completed_callback_locked(home, pending_id, cancel_token)
        remember_callback_locked(home, pending_id, cancel_token)
        remove_pending(home, current)
    return True


def complete_send(home: Path, pending: Dict[str, Any]) -> bool:
    pending_id = pending.get("pending_id")
    send_token = pending.get("send_token")
    request_id = pending.get("request_id")
    revision = pending.get("revision")
    if (not isinstance(pending_id, str) or not isinstance(send_token, str)
            or not isinstance(request_id, str) or not strict_int(revision)):
        return False
    try:
        reconcile_request(home, request_id)
        path = request_path(home, request_id)
        record = read_json(path) if path is not None else None
        if not isinstance(record, dict) or record.get("status") not in {"queued", "claimed"}:
            return False
    except (TelegramError, OSError, KeyError, TypeError, ValueError):
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                or current.get("mode") != "sending"
                or current.get("send_token") != send_token
                or current.get("request_id") != request_id
                or current.get("revision") != revision):
            return completed_callback_locked(home, pending_id, send_token)
        snapshot = dict(current)
    if not pending_confirmation_update(home, snapshot, "Sent to Firstmate", EMPTY_INLINE_MARKUP, "sent"):
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                or current.get("mode") != "sending" or current.get("send_token") != send_token
                or current.get("revision") != revision):
            return completed_callback_locked(home, pending_id, send_token)
        remove_audio(current)
        remember_callback_locked(home, pending_id, send_token)
        remove_pending(home, current)
    return True


def reconcile_pending(home: Path, config: Dict[str, Any]) -> None:
    pending = read_json(pending_path(home))
    if not isinstance(pending, dict):
        return
    if (not mirror_mode_enabled(home)
            and pending.get("mode") not in {"canceling", "sending"}):
        return
    try:
        if pending.get("mode") == "transcribing":
            complete_initial_transcription(home, config, pending)
        elif pending.get("mode") == "retry":
            complete_retry(home, config, pending)
        elif pending.get("mode") == "sending":
            complete_send(home, pending)
        elif pending.get("mode") == "canceling":
            complete_cancel(home, pending)
        elif pending.get("mode") == "confirm":
            show_confirmation(home, config, pending)
        elif pending.get("mode") == "edit":
            pending_id = pending.get("pending_id")
            revision = pending.get("revision")
            text = pending.get("text")
            if (not isinstance(pending_id, str) or not strict_int(revision)
                    or not isinstance(text, str)):
                return
            copy_markup = {"inline_keyboard": [[
                {"text": "Copy transcript", "copy_text": {"text": text}},
            ], [
                {"text": "Cancel edit", "callback_data": f"cancel:{pending_id}:{revision}"},
            ]]}
            snapshot = dict(pending)
            pending_confirmation_update(
                home, snapshot, "Editing transcript…", copy_markup, "editing",
            )
            deliver_pending_message(
                home, pending_id, revision, "edit", "edit_copy", text,
            )
            prompt_markup = {"force_reply": True,
                             "input_field_placeholder": "Paste and edit the transcript"}
            deliver_pending_message(
                home, pending_id, revision, "edit", "edit_prompt",
                "Paste and edit the transcript, then send it.", prompt_markup,
            )
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
    if (chat.get("type") != "private" or not telegram_numeric_id(chat_id, positive=True)
            or chat_id != config.get("chat_id")):
        return None
    if not telegram_numeric_id(sender_id, positive=True) or sender_id != config.get("user_id"):
        return None
    if (not telegram_numeric_id(message.get("message_id"), positive=True)
            or not telegram_numeric_id(message.get("date"))):
        return None
    return message, chat


def handle_text(home: Path, config: Dict[str, Any], message: Dict[str, Any], update_id: int) -> bool:
    text = message.get("text")
    message_id = message.get("message_id")
    if (not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT
            or unicode_text_units(text) is None):
        return False
    action = mirror_command(text)
    if action is not None:
        try:
            send_text(
                home, int(config["chat_id"]), mirror_mode_reply(home, action),
                reply_to=int(message_id), fallback_to=int(message_id),
                journal_key=f"command:u{update_id}-m{message_id}",
            )
        except TelegramError:
            return False
        return True
    operation = ""
    request_id = ""
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        if not mirror_mode_enabled(home):
            operation = "refuse"
        else:
            pending = read_json(pending_path(home))
            if isinstance(pending, dict):
                edit_replay = (pending.get("edit_update_id") == update_id
                               and pending.get("edit_message_id") == message_id)
                if edit_replay:
                    operation = "reconcile"
                elif pending.get("mode") == "edit":
                    reply_to = message.get("reply_to_message")
                    prompt_id = pending.get("edit_prompt_message_id")
                    tied_to_prompt = (
                        isinstance(reply_to, dict)
                        and reply_to.get("chat", {}).get("id") == config.get("chat_id")
                        and reply_to.get("message_id") == prompt_id
                    )
                    if not tied_to_prompt:
                        return False
                    text_units = unicode_text_units(text)
                    if text_units is None or text_units > MAX_TRANSCRIPT_UNITS:
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
                    for field in ("heading_delivery", "heading_attempts", "heading_attempted_at",
                                  "transcript_delivery", "transcript_attempts", "transcript_attempted_at",
                                  "edit_prompt_delivery", "edit_prompt_attempts", "edit_prompt_attempted_at"):
                        pending.pop(field, None)
                    pending.pop("edit_prompt_sent", None)
                    save_pending(home, pending)
                    operation = "reconcile"
            if not operation:
                request_id = _queue_request_locked(
                    home, text, int(config["chat_id"]), int(message_id), update_id,
                    "text", False,
                )
    if operation == "refuse":
        try:
            send_text(
                home, int(config["chat_id"]), MIRROR_OFF_REFUSAL,
                reply_to=int(message_id), fallback_to=int(message_id),
                journal_key=f"refuse:u{update_id}-m{message_id}",
            )
        except TelegramError:
            return False
        return True
    if operation == "reconcile":
        reconcile_pending(home, config)
        return True
    reconcile_request(home, request_id)
    record = read_json(request_path(home, request_id))
    return isinstance(record, dict) and record.get("status") in {"queued", "claimed"}


def handle_voice(home: Path, config: Dict[str, Any], message: Dict[str, Any],
                 update_id: int) -> Optional[bool]:
    voice = message.get("voice")
    if not isinstance(voice, dict):
        return False
    duration = voice.get("duration")
    size = voice.get("file_size", 0)
    file_id = voice.get("file_id")
    if not strict_int(duration) or not strict_int(size):
        return False
    if (not isinstance(file_id, str) or not file_id.strip() or "\x00" in file_id
            or unicode_text_units(file_id) is None):
        return False
    if duration < 0 or duration > MAX_VOICE_SECONDS or size < 0 or size > MAX_VOICE_BYTES:
        return False
    message_id = int(message["message_id"])
    pending_id = f"voice-u{update_id}-m{message_id}"
    refuse = False
    queued_notice = False
    with FileLock(state_lock(home)):
        require_state_available_locked(home)
        if not mirror_mode_enabled(home):
            refuse = True
        else:
            pending = read_json(pending_path(home))
            if isinstance(pending, dict) and pending.get("pending_id") == pending_id:
                return True
            records, changed = load_pending_voice_queue_locked(home)
            existing = next(
                (record for record in records if record.get("pending_id") == pending_id),
                None,
            )
            if existing is not None:
                queued_notice = existing.get("queued_notice_status") != "not_required"
                if changed:
                    save_pending_voice_queue_locked(home, records)
            else:
                if len(records) >= MAX_PENDING_VOICES:
                    return None
                queued_notice = bool(records or isinstance(pending, dict))
                records.append({
                    "pending_id": pending_id,
                    "file_id": file_id,
                    "duration": duration,
                    "size": size,
                    "chat_id": int(config["chat_id"]),
                    "message_id": message_id,
                    "update_id": update_id,
                    "queued_at": now(),
                    "queued_notice_status": "pending" if queued_notice else "not_required",
                    "queued_notice_attempts": 0,
                })
                save_pending_voice_queue_locked(home, records)
    if refuse:
        try:
            send_text(
                home, int(config["chat_id"]), MIRROR_OFF_REFUSAL,
                reply_to=message_id, fallback_to=message_id,
                journal_key=f"voice:{pending_id}:refused",
            )
        except TelegramError:
            return False
    elif queued_notice:
        return True if reconcile_queued_voice_notice(home, pending_id) else None
    return True


def advance_pending_voice(home: Path, config: Dict[str, Any]) -> None:
    while True:
        with FileLock(state_lock(home)):
            pending = read_json(pending_path(home))
            records, changed = load_pending_voice_queue_locked(home)
            if isinstance(pending, dict):
                retained = [
                    record for record in records
                    if record.get("pending_id") != pending.get("pending_id")
                ]
                if retained != records:
                    records = retained
                    changed = True
                if changed:
                    save_pending_voice_queue_locked(home, records)
                return
            if not records:
                if changed:
                    save_pending_voice_queue_locked(home, records)
                return
            record = records[0]
            if not queued_voice_notice_settled(record):
                if changed:
                    save_pending_voice_queue_locked(home, records)
                return
            pending = {
                "pending_id": record["pending_id"],
                "mode": "transcribing",
                "audio_path": str(
                    Path("/dev/shm") / f"firstmate-telegram-{secrets.token_hex(16)}.oga"
                ),
                "file_id": record["file_id"],
                "chat_id": record["chat_id"],
                "message_id": record["message_id"],
                "update_id": record["update_id"],
                "created_at": now(),
                "queued_at": record["queued_at"],
                "revision": 1,
                "completed_actions": [],
            }
            save_pending(home, pending)
            save_pending_voice_queue_locked(home, records[1:])
        if complete_initial_transcription(home, config, pending):
            return
        return


def send_voice_progress(home: Path, pending: Dict[str, Any]) -> bool:
    pending_id = pending.get("pending_id")
    if not isinstance(pending_id, str):
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (not isinstance(current, dict) or current.get("pending_id") != pending_id
                or current.get("mode") != "transcribing"):
            return False
        if current.get("progress_status") in {
                "sent", "delivery_unknown_terminal", "rejected_terminal"}:
            return True
        attempts = current.get("progress_attempts", 0)
        if not strict_int(attempts) or attempts < 0:
            attempts = 0
        if attempts >= CALLBACK_DELIVERY_ATTEMPTS:
            current["progress_status"] = (
                "delivery_unknown_terminal"
                if current.get("progress_status") in {"sending", "delivery_unknown"}
                else "rejected_terminal"
            )
            save_pending(home, current)
            return True
        attempts += 1
        current["progress_attempts"] = attempts
        current["progress_status"] = "sending"
        current["progress_attempted_at"] = now()
        save_pending(home, current)
        chat_id = int(current["chat_id"])
    try:
        result = send_text(
            home, chat_id, VOICE_PROGRESS_NOTICE,
            reply_to=int(current["message_id"]), fallback_to=int(current["message_id"]),
            journal_key=f"voice:{pending_id}:transcribing",
        )
    except TelegramError as exc:
        with FileLock(state_lock(home)):
            current = read_json(pending_path(home))
            if (isinstance(current, dict) and current.get("pending_id") == pending_id
                    and current.get("progress_attempts") == attempts):
                terminal = attempts >= CALLBACK_DELIVERY_ATTEMPTS
                if exc.delivery_unknown:
                    current["progress_status"] = (
                        "delivery_unknown_terminal" if terminal else "delivery_unknown"
                    )
                else:
                    current["progress_status"] = (
                        "rejected_terminal" if terminal else "rejected"
                    )
                save_pending(home, current)
                return terminal
        return False
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (isinstance(current, dict) and current.get("pending_id") == pending_id
                and current.get("progress_attempts") == attempts):
            current["progress_status"] = "sent"
            current["progress_message_id"] = outbound_message_id(result)
            save_pending(home, current)
            return True
    return False


def refuse_callback(home: Path, config: Dict[str, Any], callback_id: str,
                    pending_id: str, action: str, revision: int,
                    callback_message_id: int,
                    pending: Optional[Dict[str, Any]] = None) -> None:
    answer_callback(home, callback_id)
    source_message_id: Any = callback_message_id
    current = pending if isinstance(pending, dict) else read_json(pending_path(home))
    if isinstance(current, dict) and current.get("pending_id") == pending_id:
        source_message_id = current.get("message_id", source_message_id)
    try:
        send_text(
            home, int(config["chat_id"]), MIRROR_OFF_REFUSAL,
            reply_to=int(source_message_id), fallback_to=int(source_message_id),
            journal_key=f"callback:{pending_id}:{action}:{revision}:off",
        )
    except (TelegramError, TypeError, ValueError):
        pass


def handle_callback(home: Path, config: Dict[str, Any], query: Dict[str, Any], update_id: int) -> bool:
    required_fields = {"id", "from", "message", "data"}
    if not required_fields.issubset(query) or not set(query).issubset(CALLBACK_QUERY_FIELDS):
        return False
    chat_instance = query.get("chat_instance")
    if chat_instance is not None and not isinstance(chat_instance, str):
        return False
    callback_id = query.get("id")
    sender = query.get("from")
    message = query.get("message")
    if not callback_query_id(callback_id):
        return False
    if (not isinstance(sender, dict)
            or not telegram_numeric_id(sender.get("id"), positive=True)
            or sender.get("id") != config.get("user_id")):
        return False
    if (not isinstance(message, dict)
            or not telegram_numeric_id(message.get("message_id"), positive=True)
            or not telegram_numeric_id(message.get("date"))
            or not set(message).issubset(CALLBACK_MESSAGE_FIELDS)):
        return False
    chat = message.get("chat")
    if (not isinstance(chat, dict) or chat.get("type") != "private"
            or not telegram_numeric_id(chat.get("id"), positive=True)
            or chat.get("id") != config.get("chat_id")):
        return False
    callback_data = query.get("data")
    if (not isinstance(callback_data, str)
            or len(callback_data.encode("utf-8", errors="surrogatepass")) > 64):
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
    if action != "cancel" and not mirror_mode_enabled(home):
        refuse_callback(
            home, config, callback_id, pending_id, action, revision,
            int(message["message_id"]),
        )
        return True
    operation = ""
    pending_snapshot: Optional[Dict[str, Any]] = None
    with FileLock(state_lock(home)):
        pending = read_json(pending_path(home))
        if not isinstance(pending, dict) or pending.get("pending_id") != pending_id:
            if completed_callback_locked(home, pending_id, token):
                operation = "acknowledge"
            else:
                return False
        else:
            completed = pending.get("completed_actions", [])
            if not isinstance(completed, list):
                return False
            callback_completed = completed_callback_locked(home, pending_id, token)
            sending = (pending.get("mode") == "sending"
                       and pending.get("send_token") == token
                       and pending.get("revision") == revision)
            canceling = (pending.get("mode") == "canceling"
                         and pending.get("cancel_token") == token
                         and pending.get("revision") == revision)
            already_completed = token in completed or callback_completed
            if not sending and not canceling and not already_completed:
                if pending.get("revision") != revision:
                    already_completed = True
                mode = pending.get("mode")
                if action == "cancel":
                    if mode not in {"confirm", "edit"}:
                        return False
                elif mode != "confirm":
                    return False
            try:
                expired = now() - int(pending.get("created_at", 0)) >= PENDING_TTL
            except (TypeError, ValueError):
                expired = True
            if canceling:
                operation = "cancel"
                pending_snapshot = dict(pending)
            elif expired:
                finalize_pending_cleanup_locked(home, pending, token)
                operation = "acknowledge"
            elif sending:
                operation = "send"
                pending_snapshot = dict(pending)
            elif already_completed:
                operation = "acknowledge"
            else:
                if action != "cancel" and not mirror_mode_enabled(home):
                    operation = "refuse"
                    pending_snapshot = dict(pending)
                elif action == "cancel":
                    pending["mode"] = "canceling"
                    pending["cancel_token"] = token
                    save_pending(home, pending)
                    operation = "cancel"
                    pending_snapshot = dict(pending)
                else:
                    pending["completed_actions"] = [
                        value for value in completed if isinstance(value, str)
                    ][-31:] + [token]
                    if action == "edit":
                        pending["mode"] = "edit"
                        pending["edit_copy_sent"] = False
                        pending["edit_copy_delivery"] = "pending"
                        pending["edit_copy_attempts"] = 0
                        pending["edit_prompt_sent"] = False
                        pending["edit_prompt_delivery"] = "pending"
                        pending["edit_prompt_attempts"] = 0
                        save_pending(home, pending)
                        remember_callback_locked(home, pending_id, token)
                        operation = "edit"
                    elif action == "retry":
                        pending["mode"] = "retry"
                        pending["retry_token"] = token
                        save_pending(home, pending)
                        operation = "retry"
                        pending_snapshot = dict(pending)
                    else:
                        try:
                            request_id = _queue_request_locked(
                                home, str(pending["text"]), int(pending["chat_id"]),
                                int(pending["message_id"]), int(pending["update_id"]),
                                "voice", True,
                            )
                        except (TelegramError, KeyError, TypeError, ValueError):
                            return False
                        pending["mode"] = "sending"
                        pending["send_token"] = token
                        pending["request_id"] = request_id
                        save_pending(home, pending)
                        operation = "send"
                        pending_snapshot = dict(pending)
    if operation == "refuse":
        refuse_callback(
            home, config, callback_id, pending_id, action, revision,
            int(message["message_id"]), pending_snapshot,
        )
        return True
    if operation == "acknowledge":
        answer_callback(home, callback_id)
        return True
    if operation == "cancel" and pending_snapshot is not None:
        if not complete_cancel(home, pending_snapshot):
            return False
        answer_callback(home, callback_id)
        return True
    if operation == "edit":
        answer_callback(home, callback_id)
        reconcile_pending(home, config)
        return True
    if operation == "retry" and pending_snapshot is not None:
        answer_callback(home, callback_id)
        pending_confirmation_update(
            home, pending_snapshot, "Retrying with Whisper…", EMPTY_INLINE_MARKUP, "retrying",
        )
        return complete_retry(home, config, pending_snapshot)
    if operation == "send" and pending_snapshot is not None:
        if not complete_send(home, pending_snapshot):
            return False
        answer_callback(home, callback_id)
        return True
    return False


def process_update(home: Path, config: Dict[str, Any], update: Any) -> bool:
    if not isinstance(update, dict) or not telegram_numeric_id(update.get("update_id")):
        return True
    update_id = int(update["update_id"])
    has_callback = "callback_query" in update
    has_message = "message" in update
    if has_callback == has_message:
        return True
    expected_update_fields = {
        "update_id", "callback_query" if has_callback else "message"
    }
    if set(update) != expected_update_fields:
        return True
    if has_callback:
        query = update.get("callback_query")
        if not isinstance(query, dict):
            return True
        with FileLock(state_lock(home)):
            if has_seen(home, update_id, None):
                return True
        if handle_callback(home, config, query, update_id):
            with FileLock(state_lock(home)):
                seen_update(home, update_id, None)
        return True
    if not isinstance(update.get("message"), dict):
        return True
    message = update["message"]
    has_text = "text" in message
    has_voice = "voice" in message
    if has_text == has_voice:
        return True
    allowed_message_fields = TEXT_MESSAGE_FIELDS if has_text else VOICE_MESSAGE_FIELDS
    if not set(message).issubset(allowed_message_fields):
        return True
    pinned = pinned_message(config, message)
    if pinned is None:
        return True
    message_id = int(message["message_id"])
    with FileLock(state_lock(home)):
        if has_seen(home, update_id, message_id):
            return True
    handled = False
    if has_text:
        handled = handle_text(home, config, message, update_id)
    else:
        handled = handle_voice(home, config, message, update_id)
        if handled is None:
            return False
    if handled:
        with FileLock(state_lock(home)):
            seen_update(home, update_id, message_id)
    return True


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
    if not isinstance(pending, dict):
        return
    try:
        expired = now() - int(pending.get("created_at", 0)) >= PENDING_TTL
    except (TypeError, ValueError):
        expired = True
    if not expired:
        return
    if pending.get("mode") == "sending":
        complete_send(home, pending)
    elif pending.get("mode") == "canceling":
        complete_cancel(home, pending)
    with FileLock(state_lock(home)):
        current = read_json(pending_path(home))
        if (isinstance(current, dict)
                and current.get("pending_id") == pending.get("pending_id")):
            try:
                still_expired = now() - int(current.get("created_at", 0)) >= PENDING_TTL
            except (TypeError, ValueError):
                still_expired = True
            if still_expired:
                pending_id = current.get("pending_id")
                finalize_pending_cleanup_locked(home, current)
                if isinstance(pending_id, str):
                    remove_pending_voice_locked(home, pending_id)


def clear_stopped_transport_state(home: Path) -> None:
    with FileLock(state_lock(home)):
        pending = read_json(pending_path(home))
        if isinstance(pending, dict):
            finalize_pending_cleanup_locked(home, pending)
        durable_unlink(pending_voice_queue_path(home))
    set_telegram_enabled(home, False)


def serve(home: Path, once: bool = False, poll_timeout: int = POLL_TIMEOUT,
          systemd_service: bool = False) -> int:
    with contextlib.ExitStack() as runtime:
        unit_guard = contextlib.nullcontext() if systemd_service else FileLock(unit_lock())
        with unit_guard:
            with FileLock(lifecycle_lock(home)):
                if systemd_service:
                    require_unit_owner(home)
                elif systemd_runtime_reserved(home):
                    raise ServiceRuntimeOwnedError("Telegram systemd service owns the singleton transport")
                if service_activation_path(home).is_file() and not systemd_service:
                    raise ServiceRuntimeOwnedError("Telegram systemd service activation is in progress")
                runtime.enter_context(FileLock(global_service_lock(), blocking=False))
                runtime.enter_context(FileLock(service_lock(home), blocking=False))
                try:
                    config = load_config(home)
                    token_for(home)
                except TelegramError as exc:
                    clear_stopped_transport_state(home)
                    raise PermanentConfigurationError(str(exc)) from exc
                try:
                    verified_token_for(home, config)
                except PermanentConfigurationError:
                    clear_stopped_transport_state(home)
                    raise
                prepare_transport_activation(home)
                if systemd_service:
                    durable_unlink(service_activation_path(home))
        offset = 0
        stop = False
        permanent_failure = False

        def stop_service(_signum: int, _frame: Any) -> None:
            nonlocal stop
            stop = True

        signal.signal(signal.SIGTERM, stop_service)
        signal.signal(signal.SIGINT, stop_service)
        try:
            while not stop:
                expire_pending(home)
                bounded_cleanup(home)
                reconcile_requests(home)
                reconcile_pending(home, config)
                reconcile_queued_voice_notices(home)
                advance_pending_voice(home, config)
                try:
                    updates = api_call(home, "getUpdates", {"offset": offset, "timeout": poll_timeout,
                                                               "allowed_updates": ["message", "callback_query"]}, config)
                    if not isinstance(updates, list):
                        updates = []
                    for update in updates:
                        if not process_update(home, config, update):
                            break
                        if isinstance(update, dict) and telegram_numeric_id(update.get("update_id")):
                            offset = max(offset, int(update["update_id"]) + 1)
                        reconcile_queued_voice_notices(home)
                        advance_pending_voice(home, config)
                    reconcile_requests(home)
                except TelegramError as exc:
                    if permanent_auth_failure(exc):
                        permanent_failure = True
                        raise PermanentConfigurationError(
                            "Telegram bot token could not authenticate; pair again"
                        ) from exc
                    if once:
                        return 1
                    time.sleep(2)
                if once:
                    break
            return 0
        finally:
            if stop or permanent_failure:
                clear_stopped_transport_state(home)
            elif once:
                set_telegram_enabled(home, False)


def require_pairing_service_inactive(home: Path) -> None:
    if telegram_enabled_path(home).is_file():
        raise TelegramError("stop the Telegram service before changing its pairing")
    if not unit_owned_by(home):
        return
    result = systemctl("is-active", SERVICE_NAME, check=False)
    if result.stdout.strip() not in {"inactive", "failed"}:
        raise TelegramError("stop the Telegram service before changing its pairing")


def identity_bound_state_exists(home: Path) -> bool:
    root = home / "state" / "telegram"
    for name in ("active.json", "callback-actions.json", "closing.json", "pending.json",
                 "pending-voice-queue.json", "reply-journal.json", "seen.json"):
        path = root / name
        if path.exists() or path.is_symlink():
            return True
    for name in ("inbox", "handled", "responses", "deliveries"):
        path = root / name
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            return True
        if path.is_dir():
            try:
                if next(path.iterdir(), None) is not None:
                    return True
            except OSError:
                return True
    return False


def pair(home: Path, user_id: int, chat_id: int,
         parakeet_command: Optional[str] = None,
         whisper_command: Optional[str] = None) -> int:
    if (not telegram_numeric_id(user_id, positive=True)
            or not telegram_numeric_id(chat_id, positive=True)):
        raise TelegramError("user and chat ids must be positive Telegram identifiers")
    if (parakeet_command is None) != (whisper_command is None):
        raise TelegramError("configure both voice transcription commands together")
    configured_commands = None
    if parakeet_command is not None and whisper_command is not None:
        configured_commands = {
            "parakeet_command": normalize_transcriber_command(parakeet_command, "parakeet"),
            "whisper_command": normalize_transcriber_command(whisper_command, "whisper"),
        }
    with FileLock(lifecycle_lock(home)):
        require_pairing_service_inactive(home)
        config_existing = read_json(config_path(home), {})
        config = dict(config_existing) if isinstance(config_existing, dict) else {}
        if configured_commands is not None:
            config.update(configured_commands)
        config = validate_transcriber_config(config)
        token = token_for(home)
        result = raw_api_call(home, token, "getMe", {}, config)
        if (not isinstance(result, dict) or result.get("is_bot") is not True
                or not telegram_numeric_id(result.get("id"), positive=True)):
            raise TelegramError("bot identity could not be verified")
        chat = raw_api_call(home, token, "getChat", {"chat_id": chat_id}, config)
        if (not isinstance(chat, dict) or chat.get("type") != "private"
                or not telegram_numeric_id(chat.get("id"), positive=True)
                or chat.get("id") != chat_id):
            raise TelegramError("pairing requires the pinned private bot DM")
        if user_id != chat_id:
            raise TelegramError("the pinned private chat must belong to the pinned user")
        new_identity = (user_id, chat_id, int(result["id"]))
        with FileLock(state_lock(home)):
            current = read_json(config_path(home), {})
            config = dict(current) if isinstance(current, dict) else {}
            if configured_commands is not None:
                config.update(configured_commands)
            config = validate_transcriber_config(config)
            identity_values = (
                config.get("user_id"), config.get("chat_id"), config.get("bot_id")
            )
            current_identity = (
                identity_values if all(strict_int(value) for value in identity_values) else None
            )
            if current_identity != new_identity and identity_bound_state_exists(home):
                raise TelegramError(
                    "clean up private Telegram state before changing its pairing"
                )
            config.pop("api_base", None)
            config.update({"user_id": user_id, "chat_id": chat_id,
                           "bot_id": int(result["id"])})
            atomic_json(config_path(home), config)
            durable_unlink(state_tombstone(home))
    print("Telegram pairing verified.")
    return 0


def text_from_file(path: str) -> str:
    if path == "-":
        return sys.stdin.buffer.read().decode("utf-8")
    return Path(path).read_bytes().decode("utf-8")


def telegram_enabled_path(home: Path) -> Path:
    return state_dir(home) / "enabled"


def set_telegram_enabled(home: Path, enabled: bool) -> None:
    path = telegram_enabled_path(home)
    if enabled:
        atomic_bytes(path, b"enabled\n")
    else:
        durable_unlink(path)


def prepare_transport_activation(home: Path) -> None:
    # The transport is allowed to queue while no primary exists. The project-local
    # Pi extension, not a watcher or a second route, owns live delivery.
    set_telegram_enabled(home, True)


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
    arguments = " ".join(systemd_quote(value) for value in (
        str(script), "--home", str(home), "serve", "--systemd-service"
    ))
    return ("[Unit]\nDescription=Firstmate Telegram transport\nAfter=network-online.target\n\n"
            "[Service]\nType=simple\n"
            f"Environment={systemd_quote('FM_HOME=' + str(home))}\n"
            f"ExecStart=:/usr/bin/python3 {arguments}\n"
            "Restart=on-failure\nRestartPreventExitStatus=78\nRestartSec=3\n\n"
            "[Install]\nWantedBy=default.target\n")


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
        raise TelegramError("Telegram transport state did not converge")


def wait_for_systemd_runtime_ready(home: Path) -> None:
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if (not service_activation_path(home).is_file()
                and telegram_enabled_path(home).is_file()):
            return
        time.sleep(0.02)
    raise TelegramError("Telegram systemd service did not become ready")


def reconcile_failed_activation(home: Path, disable_new_install: bool = False,
                                activation_reserved: bool = False) -> None:
    if activation_reserved:
        systemctl("stop", SERVICE_NAME, check=False)
        verify_service(active=False)
    with FileLock(lifecycle_lock(home)):
        if not activation_reserved and service_runtime_owned(home):
            return
        runtime_guard = (FileLock(service_lock(home), blocking=False, timeout=3)
                         if activation_reserved else contextlib.nullcontext())
        with runtime_guard:
            active_result = systemctl("is-active", SERVICE_NAME, check=False)
            if active_result.stdout.strip() not in {"inactive", "failed", "unknown", "not-found"}:
                return
            durable_unlink(service_activation_path(home))
            set_telegram_enabled(home, False)
            verify_transport_marker(home, False)
            if disable_new_install:
                systemctl("disable", SERVICE_NAME)
                verify_service(enabled=False)


def install(home: Path) -> int:
    with FileLock(unit_lock()):
        enabled_by_install = False
        activation_reserved = False
        try:
            with FileLock(lifecycle_lock(home)):
                if unit_owned_by(home):
                    active_result = systemctl("is-active", SERVICE_NAME, check=False)
                    enabled_result = systemctl("is-enabled", SERVICE_NAME, check=False)
                    if (active_result.returncode == 0 and active_result.stdout.strip() == "active"
                            and enabled_result.returncode == 0
                            and enabled_result.stdout.strip() == "enabled"):
                        verify_transport_marker(home, True)
                        print("Telegram service installed and active.")
                        return 0
                require_service_runtime_inactive(home)
                config = load_config(home)
                verified_token_for(home, config)
                path = unit_path()
                if (path.exists() or path.is_symlink()) and not unit_owned_by(home):
                    raise TelegramError("Telegram service unit belongs to another home or installation")
                atomic_bytes(path, unit_contents(home).encode())
                systemctl("daemon-reload")
                enabled_result = systemctl("is-enabled", SERVICE_NAME, check=False)
                was_enabled = (enabled_result.returncode == 0
                               and enabled_result.stdout.strip() == "enabled")
                systemctl("enable", SERVICE_NAME)
                enabled_by_install = not was_enabled
                prepare_transport_activation(home)
                atomic_bytes(service_activation_path(home), b"systemd\n")
                activation_reserved = True
            systemctl("start", SERVICE_NAME)
            wait_for_systemd_runtime_ready(home)
            with FileLock(lifecycle_lock(home)):
                require_unit_owner(home)
                verify_service(active=True, enabled=True)
                verify_transport_marker(home, True)
        except (TelegramError, OSError, ValueError) as exc:
            reconcile_failed_activation(
                home, enabled_by_install, activation_reserved=activation_reserved,
            )
            raise
    print("Telegram service installed and active.")
    return 0


def start_service(home: Path) -> int:
    with FileLock(unit_lock()):
        activation_reserved = False
        try:
            with FileLock(lifecycle_lock(home)):
                require_service_runtime_inactive(home)
                config = load_config(home)
                verified_token_for(home, config)
                require_unit_owner(home)
                prepare_transport_activation(home)
                atomic_bytes(service_activation_path(home), b"systemd\n")
                activation_reserved = True
            systemctl("start", SERVICE_NAME)
            wait_for_systemd_runtime_ready(home)
            with FileLock(lifecycle_lock(home)):
                require_unit_owner(home)
                verify_service(active=True)
                verify_transport_marker(home, True)
        except (TelegramError, OSError, ValueError) as exc:
            reconcile_failed_activation(home, activation_reserved=activation_reserved)
            raise
    print("Telegram service active.")
    return 0


def stop_service(home: Path) -> int:
    with FileLock(unit_lock()):
        with FileLock(lifecycle_lock(home)):
            require_unit_owner(home)
            systemctl("stop", SERVICE_NAME)
            verify_service(active=False)
            with FileLock(service_lock(home), blocking=False, timeout=1):
                with FileLock(state_lock(home)):
                    pending = read_json(pending_path(home))
                    if isinstance(pending, dict):
                        finalize_pending_cleanup_locked(home, pending)
                    durable_unlink(pending_voice_queue_path(home))
                durable_unlink(service_activation_path(home))
                set_telegram_enabled(home, False)
                verify_transport_marker(home, False)
    print("Telegram service stopped.")
    return 0


def status_service(home: Path) -> int:
    with FileLock(unit_lock()):
        require_unit_owner(home)
        result = systemctl("is-active", SERVICE_NAME, check=False)
    print(result.stdout.strip() or "inactive")
    return 0 if result.returncode == 0 and result.stdout.strip() == "active" else 1


def disable_service(home: Path) -> int:
    with FileLock(unit_lock()):
        with FileLock(lifecycle_lock(home)):
            require_unit_owner(home)
            systemctl("disable", "--now", SERVICE_NAME)
            verify_service(active=False, enabled=False)
            with FileLock(service_lock(home), blocking=False, timeout=1):
                with FileLock(state_lock(home)):
                    pending = read_json(pending_path(home))
                    if isinstance(pending, dict):
                        finalize_pending_cleanup_locked(home, pending)
                    durable_unlink(pending_voice_queue_path(home))
                durable_unlink(service_activation_path(home))
                set_telegram_enabled(home, False)
                verify_transport_marker(home, False)
    print("Telegram service disabled.")
    return 0


def _cleanup_locked(home: Path) -> int:
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
    if owned:
        systemctl("disable", "--now", SERVICE_NAME)
        verify_service(active=False, enabled=False)
    with FileLock(service_lock(home), blocking=False, timeout=1):
        durable_unlink(service_activation_path(home))
        if owned:
            durable_unlink(path)
            systemctl("daemon-reload")
        with FileLock(state_lock(home)):
            atomic_bytes(state_tombstone(home), b"cleaned\n")
            if telegram_state.is_dir() and not telegram_state.is_symlink():
                pending = read_json(telegram_state / "pending.json")
                if isinstance(pending, dict):
                    remove_audio(pending)
            consume_safe_wakes(home, effective_wake_state(home))
            if telegram_state.is_symlink() or telegram_state.is_file():
                durable_unlink(telegram_state)
            elif telegram_state.is_dir():
                durable_rmtree(telegram_state)
            config = config_path(home)
            if config.is_symlink() or config.is_file():
                durable_unlink(config)
            durable_unlink(mirror_mode_path(home))
    print("Telegram service and private Telegram state cleaned up.")
    return 0


def cleanup(home: Path) -> int:
    with FileLock(unit_lock()):
        with FileLock(lifecycle_lock(home)):
            return _cleanup_locked(home)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Private one-home Telegram transport for Firstmate.",
        epilog=("Commands: pair, serve, migrate-wakes, mirror-open, mirror-mode, mirror-next, mirror-claim, mirror-read, mirror-delivered, mirror-release, mirror-hold, mirror-recover, mirror-validate, mirror-reserve, mirror-cancel, mirror-reply, mirror-abandon, mirror-complete, mirror-reconcile, install, start, stop, status, disable, cleanup.\n"
                "Private mirror commands require the lock-owning extension capability on an inherited file descriptor.\n"
                f"Retention limits: {MAX_INBOX} queued or interrupted requests for {INBOX_TTL // (24 * 60 * 60)} days, {MAX_HANDLED} handled requests, and {MAX_MIRROR_DELIVERIES} mirror deliveries; unprotected mirror deliveries expire after {MIRROR_DELIVERY_TTL // (24 * 60 * 60)} days and each is at most {MAX_MIRROR_DELIVERY_BYTES // 1024} KiB or {MAX_MIRROR_DELIVERY_CHUNKS} Telegram chunks.\n"
                f"Receipt delivery makes at most {len(RECEIPT_RETRY_DELAYS)} attempts with bounded backoff and replies to the exact source message.\n"
                "Reply targets are validated against the pinned private chat, journaled with bounded message IDs, and fall back to the triggering source then an unthreaded send when Telegram rejects a deleted target.\n"
                f"Voice limits: {MAX_VOICE_BYTES // (1024 * 1024)} MiB, {MAX_VOICE_SECONDS} seconds, a {MAX_TRANSCRIPT_UNITS}-unit transcript, {MAX_PENDING_VOICES} waiting notes for {INBOX_TTL // (24 * 60 * 60)} days, and one active confirmation for {PENDING_TTL // 60} minutes. Temporary audio is restricted to /dev/shm.\n"
                "Voice Edit uses copy_text when supported plus ForceReply; the ordinary Telegram composer is never prefilled.\n"
                "Pairing accepts --parakeet-command and --whisper-command as absolute executable paths; configured paths must be regular executable files.\n"
                "FM_TELEGRAM_PARAKEET_CMD and FM_TELEGRAM_WHISPER_CMD override the local transcription commands for one process.\n"
                "Mirror delivery reads UTF-8 from --text-file and accepts no recipient argument."),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--home", help="the one Firstmate home to use")
    parser.add_argument("--test-api-base", help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)
    def add_home(command: argparse.ArgumentParser) -> None:
        command.add_argument("--home", default=argparse.SUPPRESS, help=argparse.SUPPRESS)
    def add_private(command: argparse.ArgumentParser) -> None:
        add_home(command)
        command.add_argument("--owner-pid", type=int, required=True)
        command.add_argument("--capability-fd", type=int, required=True, help=argparse.SUPPRESS)
    pair_parser = sub.add_parser(
        "pair", help="verify and save one private pairing while its service is inactive"
    )
    add_home(pair_parser)
    pair_parser.add_argument("--user-id", type=int, required=True)
    pair_parser.add_argument("--chat-id", type=int, required=True)
    pair_parser.add_argument(
        "--parakeet-command",
        help="absolute executable for Parakeet v3; configure with --whisper-command too",
    )
    pair_parser.add_argument(
        "--whisper-command",
        help="absolute executable for Whisper Small Q8; configure with --parakeet-command too",
    )
    serve_parser = sub.add_parser("serve", help="run the outbound Bot API long-poll service")
    add_home(serve_parser)
    serve_parser.add_argument("--once", action="store_true")
    serve_parser.add_argument("--poll-timeout", type=int, default=POLL_TIMEOUT)
    serve_parser.add_argument("--systemd-service", action="store_true", help=argparse.SUPPRESS)
    migrate_parser = sub.add_parser(
        "migrate-wakes", help="retire obsolete Telegram wake rows without reading request content"
    )
    add_home(migrate_parser)
    open_parser = sub.add_parser("mirror-open", help="open the lock owner's private extension capability")
    add_private(open_parser)
    mode_parser = sub.add_parser("mirror-mode", help="read or set the private Telegram mirror preference")
    add_private(mode_parser)
    mode_parser.add_argument("action", choices=("on", "off", "status"))
    next_parser = sub.add_parser("mirror-next", help="print the next queued mirror request id")
    add_private(next_parser)
    claim_parser = sub.add_parser("mirror-claim", help="claim one queued request for this Pi process")
    add_private(claim_parser)
    claim_parser.add_argument("request_id")
    mirror_read_parser = sub.add_parser("mirror-read", help="print one request owned by this Pi process")
    add_private(mirror_read_parser)
    mirror_read_parser.add_argument("request_id")
    delivered_parser = sub.add_parser("mirror-delivered", help="send the zero-token Pi delivery receipt")
    add_private(delivered_parser)
    delivered_parser.add_argument("request_id")
    release_parser = sub.add_parser("mirror-release", help="return a failed live claim to the queue")
    add_private(release_parser)
    release_parser.add_argument("request_id")
    hold_parser = sub.add_parser("mirror-hold", help="hold one interrupted admission without retrying it")
    add_private(hold_parser)
    hold_parser.add_argument("request_id")
    hold_parser.add_argument("turn_id")
    recover_parser = sub.add_parser("mirror-recover", help="explicitly requeue one held interrupted admission")
    add_private(recover_parser)
    recover_parser.add_argument("request_id")
    validate_parser = sub.add_parser("mirror-validate", help="validate one delivery body without reserving it")
    add_private(validate_parser)
    validate_parser.add_argument("--text-file", required=True)
    reserve_parser = sub.add_parser("mirror-reserve", help="reserve one bounded live terminal delivery")
    add_private(reserve_parser)
    reserve_parser.add_argument("delivery_id")
    reserve_parser.add_argument("--text-file", required=True)
    reserve_parser.add_argument("--accepted-input", action="store_true", help=argparse.SUPPRESS)
    cancel_parser = sub.add_parser("mirror-cancel", help="cancel one unaccepted terminal delivery reservation")
    add_private(cancel_parser)
    cancel_parser.add_argument("delivery_id")
    mirror_reply_parser = sub.add_parser("mirror-reply", help="deliver one stable finalized assistant body")
    add_private(mirror_reply_parser)
    mirror_reply_parser.add_argument("delivery_id")
    mirror_reply_parser.add_argument("--text-file", required=True)
    mirror_reply_parser.add_argument("--request-id", help=argparse.SUPPRESS)
    abandon_parser = sub.add_parser("mirror-abandon", help="finish an admitted request whose response cannot be delivered")
    add_private(abandon_parser)
    abandon_parser.add_argument("request_id")
    abandon_parser.add_argument("delivery_id")
    complete_parser = sub.add_parser("mirror-complete", help="complete a request after settled delivery")
    add_private(complete_parser)
    complete_parser.add_argument("request_id")
    complete_parser.add_argument("delivery_id")
    reconcile_parser = sub.add_parser("mirror-reconcile", help="requeue claims after process or session replacement")
    add_private(reconcile_parser)
    reconcile_parser.add_argument("--preserve-request", action="append", default=[])
    reconcile_parser.add_argument("--report-delivery", action="append", default=[])
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
        validate_home_storage(home)
        configure_test_api_base(
            home, args.test_api_base or os.environ.get("FM_TELEGRAM_TEST_API_BASE")
        )
        if args.command == "pair":
            return pair(
                home, args.user_id, args.chat_id,
                args.parakeet_command, args.whisper_command,
            )
        if args.command == "serve":
            return serve(
                home, args.once, max(0, min(args.poll_timeout, 50)), args.systemd_service
            )
        if args.command == "migrate-wakes":
            return migrate_wakes(home)
        if args.command == "mirror-open":
            return mirror_open(home, args.owner_pid, args.capability_fd)
        if args.command.startswith("mirror-"):
            if not mirror_authorized(home, args.owner_pid, args.capability_fd):
                return die("Telegram mirror capability is not authorized for this Pi process")
        if args.command == "mirror-mode":
            if args.action == "status":
                print("on" if mirror_mode_enabled(home) else "off")
                return 0
            print(mirror_mode_reply(home, args.action))
            return 0
        if args.command == "mirror-next":
            return mirror_list(home)
        if args.command == "mirror-claim":
            return mirror_claim(home, args.request_id, args.owner_pid)
        if args.command == "mirror-read":
            return mirror_read(home, args.request_id, args.owner_pid)
        if args.command == "mirror-delivered":
            return mirror_delivered(home, args.request_id, args.owner_pid)
        if args.command == "mirror-release":
            return mirror_release(home, args.request_id, args.owner_pid)
        if args.command == "mirror-hold":
            return mirror_hold(home, args.request_id, args.turn_id, args.owner_pid)
        if args.command == "mirror-recover":
            return mirror_recover(home, args.request_id, args.owner_pid)
        if args.command == "mirror-validate":
            return mirror_validate(args.text_file)
        if args.command == "mirror-reserve":
            return mirror_reserve(
                home, args.delivery_id, args.owner_pid, args.text_file, args.accepted_input
            )
        if args.command == "mirror-cancel":
            return mirror_cancel(home, args.delivery_id, args.owner_pid)
        if args.command == "mirror-reply":
            return mirror_reply(
                home, args.delivery_id, args.owner_pid, args.text_file, args.request_id
            )
        if args.command == "mirror-abandon":
            return mirror_abandon(home, args.request_id, args.delivery_id, args.owner_pid)
        if args.command == "mirror-complete":
            return mirror_complete(home, args.request_id, args.delivery_id, args.owner_pid)
        if args.command == "mirror-reconcile":
            return mirror_reconcile(
                home, args.owner_pid, args.preserve_request,
                report_held=True, report_deliveries=args.report_delivery,
            )
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
    except PermanentConfigurationError as exc:
        return die(str(exc), PERMANENT_CONFIG_EXIT)
    except (TelegramError, OSError, ValueError) as exc:
        return die(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
