#!/usr/bin/env bash
# Behavioral tests for the one-home Telegram transport.
# The fake HTTP server is local-only and no real bot credentials or service are used.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-tests)
PYTHON=${PYTHON:-python3}
SCRIPT="$ROOT/bin/fm-telegram.py"
export FM_TELEGRAM_UNIT_DIR="$TMP_ROOT/default-systemd-user"

path_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

start_server() {
  local home=$1 port_file=$2 old_pid
  if [ -n "$SERVER_HOME" ] && [ -f "$SERVER_HOME/server.pid" ]; then
    old_pid=$(cat "$SERVER_HOME/server.pid" 2>/dev/null || true)
    [ -z "$old_pid" ] || kill "$old_pid" 2>/dev/null || true
  fi
  SERVER_HOME=$home
  "$PYTHON" - "$home" "$port_file" <<'PY' &
import json, os, socket, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
home = Path(sys.argv[1]); port_file = Path(sys.argv[2])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args): pass
    def _write(self, value):
        raw = json.dumps({'ok': True, 'result': value}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(size)
        try: params = json.loads(body or b'{}')
        except Exception: params = {}
        calls = home / 'calls.jsonl'
        with calls.open('a', encoding='utf-8') as out:
            out.write(json.dumps({'path': self.path, 'params': params}) + '\n')
        method = self.path.rsplit('/', 1)[-1]
        if method == 'getMe':
            if (home / 'block-getme').exists():
                (home / 'getme-entered').write_text('entered')
                while (home / 'block-getme').exists(): time.sleep(.01)
            if (home / 'replace-token-on-getme').exists():
                (home / 'replace-token-on-getme').unlink()
                (home / '.env').write_text('FM_TELEGRAM_BOT_TOKEN=replacement-token\n')
            if (home / 'disconnect-next-getme').exists():
                (home / 'disconnect-next-getme').unlink()
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            if (home / 'unauthorized-next-getme').exists():
                (home / 'unauthorized-next-getme').unlink()
                raw = json.dumps({'ok': False, 'description': 'Unauthorized'}).encode()
                self.send_response(401); self.send_header('Content-Length', str(len(raw)))
                self.end_headers(); self.wfile.write(raw)
                return
            bot_id = 9902 if '/botreplacement-token/' in self.path else 9901
            return self._write({'id': bot_id, 'is_bot': True})
        if method == 'getChat': return self._write({'id': int(params.get('chat_id', 0)), 'type': 'private'})
        if method == 'getFile': return self._write({'file_path': 'voice/test.oga'})
        if method == 'getUpdates':
            if (home / 'hold-updates').exists(): time.sleep(.05)
            expire_during_poll = home / 'expire-pending-during-poll'
            if expire_during_poll.exists():
                expire_during_poll.unlink()
                pending_path = home / 'state' / 'telegram' / 'pending.json'
                pending = json.loads(pending_path.read_text())
                pending['created_at'] = 0
                pending_path.write_text(json.dumps(pending))
            if (home / 'block-updates').exists():
                (home / 'updates-entered').write_text('entered')
                while (home / 'block-updates').exists(): time.sleep(.01)
            if (home / 'unauthorized-next-updates').exists():
                (home / 'unauthorized-next-updates').unlink()
                raw = json.dumps({'ok': False, 'error_code': 401, 'description': 'Unauthorized'}).encode()
                self.send_response(401); self.send_header('Content-Length', str(len(raw)))
                self.end_headers(); self.wfile.write(raw)
                return
            if (home / 'server-error-next-updates').exists():
                (home / 'server-error-next-updates').unlink()
                raw = json.dumps({'ok': False, 'error_code': 500, 'description': 'Server error'}).encode()
                self.send_response(500); self.send_header('Content-Length', str(len(raw)))
                self.end_headers(); self.wfile.write(raw)
                return
            updates = json.loads((home / 'updates.json').read_text()) if (home / 'updates.json').exists() else []
            return self._write(updates)
        if method == 'sendMessage':
            request_root = home / 'state' / 'telegram'
            inbox = list((request_root / 'inbox').glob('*.json')) if (request_root / 'inbox').exists() else []
            handled = list((request_root / 'handled').glob('*.json')) if (request_root / 'handled').exists() else []
            text = params.get('text')
            if isinstance(text, str) and len(text.encode('utf-16-le')) // 2 > 4096:
                raw = json.dumps({'ok': False, 'error_code': 400, 'description': 'message too long'}).encode()
                self.send_response(400); self.send_header('Content-Length', str(len(raw)))
                self.end_headers(); self.wfile.write(raw)
                return
            if isinstance(text, str) and text.startswith('Bot · Message received'):
                wake_path = home / 'state' / '.wake-queue'
                wake = wake_path.read_text() if wake_path.exists() else ''
                if not inbox and not handled:
                    (home / 'receipt-before-durable').write_text('failed')
                if inbox and 'telegram tg-' not in wake:
                    (home / 'receipt-before-durable').write_text('failed')
            send_count_path = home / 'send-count'
            send_count = int(send_count_path.read_text()) + 1 if send_count_path.exists() else 1
            send_count_path.write_text(str(send_count))
            hold = home / 'hold-send'
            hold_at = home / 'hold-send-at-count'
            if hold.exists() or (hold_at.exists() and int(hold_at.read_text()) == send_count):
                (home / 'send-entered').write_text('entered')
                while hold.exists() or hold_at.exists(): time.sleep(.01)
            disconnect = home / 'disconnect-after-send-count'
            disconnect_count = int(disconnect.read_text()) if disconnect.exists() else 0
            if disconnect_count > 0:
                disconnect.write_text(str(disconnect_count - 1))
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            fail = home / 'fail-send-count'
            count = int(fail.read_text()) if fail.exists() else 0
            if count > 0:
                fail.write_text(str(count - 1))
                raw = json.dumps({'ok': False, 'description': 'injected'}).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(raw)))
                self.end_headers(); self.wfile.write(raw)
                return
        return self._write({})
    def do_GET(self):
        if '/file/' in self.path:
            pending_path = home / 'state' / 'telegram' / 'pending.json'
            pending = json.loads(pending_path.read_text()) if pending_path.exists() else {}
            audio = Path(str(pending.get('audio_path', '')))
            if pending.get('mode') != 'transcribing' or not audio.is_file():
                (home / 'audio-not-journaled-before-download').write_text('failed')
            raw = b'fake audio bytes'
            self.send_response(200); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
            return
        self.send_response(404); self.end_headers()
server = HTTPServer(('127.0.0.1', 0), Handler)
port_file.write_text(str(server.server_port))
(port_file.parent / 'server.pid').write_text(str(os.getpid()))
server.serve_forever()
PY
  SERVER_PID=$!
  for _ in $(seq 1 50); do [ -s "$port_file" ] && return 0; sleep .02; done
  fail "fake Telegram server did not start"
}

SERVER_PID=
SERVER_HOME=
cleanup_server() {
  local pid
  if [ -n "$SERVER_HOME" ] && [ -f "$SERVER_HOME/server.pid" ]; then
    pid=$(cat "$SERVER_HOME/server.pid" 2>/dev/null || true)
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  fi
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
}
trap 'cleanup_server' EXIT

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home"; printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' > "$home/.env"; chmod 600 "$home/.env"
  printf '[]\n' > "$home/updates.json"
  printf '%s\n' "$home"
}

set_raw_updates() { printf '%s\n' "$1" > "$2/updates.json"; }
set_updates() {
  "$PYTHON" - "$1" "$2/updates.json" <<'PY'
import json, sys
updates = json.loads(sys.argv[1])
for update in updates:
    if not isinstance(update, dict):
        continue
    messages = [update.get('message')]
    query = update.get('callback_query')
    if isinstance(query, dict):
        messages.append(query.get('message'))
    for message in messages:
        if isinstance(message, dict):
            message.setdefault('date', 1)
with open(sys.argv[2], 'w', encoding='utf-8') as stream:
    json.dump(updates, stream)
PY
}
test_api_base() { printf 'http://127.0.0.1:%s' "$(cat "$1/port")"; }
run_tg() { env FM_HOME="$1" "$SCRIPT" --test-api-base "$(test_api_base "$1")" "${@:2}"; }
reserve_response() {
  local home=$1 claimed=$2 response_id=$3
  shift 3
  run_tg "$home" response-reserve "$claimed" "$response_id" "$@"
}
stage_response() {
  local home=$1 claimed=$2 response_id=$3 text_file=$4 reserved
  shift 4
  reserved=$(reserve_response "$home" "$claimed" "$response_id" "$@") || return
  cp -- "$text_file" "$reserved"
  run_tg "$home" response-stage "$claimed" "$response_id" --text-file "$reserved" "$@"
}
render_response() {
  run_tg "$1" response-render "$2" "$3" &&
    run_tg "$1" response-rendered "$2" "$3"
}
reply_response() {
  run_tg "$1" reply "$2" --response-id "$3"
}
prepare_response() {
  local home=$1 claimed=$2 response_id=$3 text_file=$4
  shift 4
  stage_response "$home" "$claimed" "$response_id" "$text_file" "$@" >/dev/null
  render_response "$home" "$claimed" "$response_id" >/dev/null
}
callback_data() {
  python3 - "$1/calls.jsonl" "$2" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
prefix = sys.argv[2] + ':'
for call in reversed(calls):
    keyboard = call.get('params', {}).get('reply_markup', {}).get('inline_keyboard', [])
    for row in keyboard:
        for button in row:
            value = button.get('callback_data')
            if isinstance(value, str) and value.startswith(prefix):
                print(value)
                raise SystemExit(0)
raise SystemExit(1)
PY
}

home=$(new_home basic)
start_server "$home" "$home/port"
if run_tg "$home" pair --user-id 78 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing must reject a private chat that does not represent the pinned user"
fi
run_tg "$home" pair --user-id 77 --chat-id 77 >/dev/null
[ "$(path_mode "$home/config/telegram.json")" = 600 ] || fail "pairing config must be mode 0600"
python3 - "$home/config/telegram.json" <<'PY'
import json, sys
path = sys.argv[1]
config = json.load(open(path, encoding='utf-8'))
config['api_base'] = 'https://example.com/collect'
json.dump(config, open(path, 'w', encoding='utf-8'))
PY
run_tg "$home" pair --user-id 77 --chat-id 77 >/dev/null
python3 - "$home/config/telegram.json" <<'PY' || fail "pairing persisted a test API endpoint"
import json, sys
assert 'api_base' not in json.load(open(sys.argv[1], encoding='utf-8'))
PY
calls_before_endpoint_refusal=$(wc -l < "$home/calls.jsonl" | tr -d ' ')
if env FM_HOME="$home" "$SCRIPT" --test-api-base "https://example.com" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "non-loopback test API endpoint was accepted"
fi
[ "$(wc -l < "$home/calls.jsonl" | tr -d ' ')" -eq "$calls_before_endpoint_refusal" ] || fail "refused test API endpoint received the bot token"

# Telegram is confined to a primary home's own regular credential file.
boundary_home=$(new_home primary-boundary)
start_server "$boundary_home" "$boundary_home/port"
printf 'secondmate-id\n' > "$boundary_home/.fm-secondmate-home"
if run_tg "$boundary_home" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing accepted a marked secondmate home"
fi
[ ! -e "$boundary_home/calls.jsonl" ] || fail "secondmate home validation reached Telegram"
rm "$boundary_home/.fm-secondmate-home" "$boundary_home/.env"
printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' > "$TMP_ROOT/external-telegram.env"
ln -s "$TMP_ROOT/external-telegram.env" "$boundary_home/.env"
if run_tg "$boundary_home" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing accepted a symlinked home token file"
fi
[ ! -e "$boundary_home/calls.jsonl" ] || fail "symlinked home token was used for Telegram authentication"

# Home-owned storage components cannot redirect pairing or state outside the selected home.
unsafe_home=$(new_home unsafe-storage)
unsafe_target="$TMP_ROOT/unsafe-storage-target"
mkdir -p "$unsafe_target"
ln -s "$unsafe_target" "$unsafe_home/state"
start_server "$unsafe_home" "$unsafe_home/port"
if run_tg "$unsafe_home" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing accepted a symlinked state directory"
fi
[ -z "$(find "$unsafe_target" -mindepth 1 -print -quit)" ] || fail "symlinked state received Telegram files"
rm "$unsafe_home/state"
mkdir "$unsafe_home/state"
ln -s "$unsafe_target" "$unsafe_home/state/telegram"
if run_tg "$unsafe_home" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing accepted a symlinked Telegram state directory"
fi
[ -z "$(find "$unsafe_target" -mindepth 1 -print -quit)" ] || fail "symlinked Telegram state received files"
rm "$unsafe_home/state/telegram"
printf 'not a directory\n' > "$unsafe_home/state/telegram"
if run_tg "$unsafe_home" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing accepted a non-directory Telegram state component"
fi
rm "$unsafe_home/state/telegram"
ln -s "$unsafe_target" "$unsafe_home/config"
if run_tg "$unsafe_home" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing accepted a symlinked config directory"
fi
[ ! -e "$unsafe_target/telegram.json" ] || fail "symlinked config received pairing state"
rm "$unsafe_home/config"
mkdir "$unsafe_home/config"
printf 'external pairing sentinel\n' > "$unsafe_target/telegram.json"
ln -s "$unsafe_target/telegram.json" "$unsafe_home/config/telegram.json"
if run_tg "$unsafe_home" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing accepted a symlinked config file"
fi
[ "$(cat "$unsafe_target/telegram.json")" = "external pairing sentinel" ] || fail "symlinked config file was changed"

# One process pins its verified token, while a later process rejects a changed bot until re-pairing.
pin_home=$(new_home bot-pinning)
start_server "$pin_home" "$pin_home/port"
run_tg "$pin_home" pair --user-id 77 --chat-id 77 >/dev/null
touch "$pin_home/replace-token-on-getme"
set_updates '[{"update_id":90,"message":{"message_id":90,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"stay with the verified bot"}}]' "$pin_home"
run_tg "$pin_home" serve --once >/dev/null
[ "$(cat "$pin_home/.env")" = 'FM_TELEGRAM_BOT_TOKEN=replacement-token' ] || fail "fake token replacement did not occur"
! grep -F '/botreplacement-token/' "$pin_home/calls.jsonl" >/dev/null || fail "running service switched tokens after verification"
pin_updates_before=$(grep -c 'getUpdates' "$pin_home/calls.jsonl")
pin_sends_before=$(grep -c 'sendMessage' "$pin_home/calls.jsonl")
touch "$pin_home/state/telegram/enabled"
run_tg "$pin_home" serve --once >/dev/null 2>&1
mismatch_status=$?
[ "$mismatch_status" -eq 78 ] || fail "changed bot token did not use the permanent configuration exit"
[ ! -e "$pin_home/state/telegram/enabled" ] || fail "changed bot token left transport supervision active"
printf 'must not send\n' > "$pin_home/send.txt"
if run_tg "$pin_home" send --text-file "$pin_home/send.txt" >/dev/null 2>&1; then
  fail "send accepted a bot token that did not match the pairing"
fi
[ "$(grep -c 'getUpdates' "$pin_home/calls.jsonl")" -eq "$pin_updates_before" ] || fail "mismatched bot token polled for updates"
[ "$(grep -c 'sendMessage' "$pin_home/calls.jsonl")" -eq "$pin_sends_before" ] || fail "mismatched bot token sent a message"
cp "$pin_home/config/telegram.json" "$pin_home/pairing-before-stateful-repair.json"
if run_tg "$pin_home" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing replaced the bot identity while old identity-bound requests remained"
fi
cmp -s "$pin_home/config/telegram.json" "$pin_home/pairing-before-stateful-repair.json" || fail "refused bot replacement changed the pairing"

repair_home=$(new_home bot-repair)
start_server "$repair_home" "$repair_home/port"
run_tg "$repair_home" pair --user-id 77 --chat-id 77 >/dev/null
printf 'FM_TELEGRAM_BOT_TOKEN=replacement-token\n' > "$repair_home/.env"
run_tg "$repair_home" pair --user-id 77 --chat-id 77 >/dev/null
set_updates '[{"update_id":91,"message":{"message_id":91,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"accepted after explicit repair"}}]' "$repair_home"
touch "$repair_home/disconnect-next-getme"
run_tg "$repair_home" serve --once >/dev/null 2>&1
[ "$?" -eq 1 ] || fail "transient bot verification failure used the permanent configuration exit"
run_tg "$repair_home" serve --once >/dev/null
[ "$(find "$repair_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "state-free re-pairing did not authorize the replacement bot"
touch "$repair_home/unauthorized-next-getme" "$repair_home/state/telegram/enabled"
run_tg "$repair_home" serve --once >/dev/null 2>&1
[ "$?" -eq 78 ] || fail "definitive bot authentication failure did not use the permanent configuration exit"
[ ! -e "$repair_home/state/telegram/enabled" ] || fail "authentication failure left transport supervision active"
touch "$repair_home/server-error-next-updates"
run_tg "$repair_home" serve --once >/dev/null 2>&1
[ "$?" -eq 1 ] || fail "transient polling failure used the permanent configuration exit"
touch "$repair_home/unauthorized-next-updates" "$repair_home/state/telegram/enabled"
run_tg "$repair_home" serve --once >/dev/null 2>&1
[ "$?" -eq 78 ] || fail "polling authentication failure did not use the permanent configuration exit"
[ ! -e "$repair_home/state/telegram/enabled" ] || fail "polling authentication failure left transport supervision active"

# Permanent local service configuration failures stop with status 78 and release supervision.
config_home=$(new_home local-config)
start_server "$config_home" "$config_home/port"
mkdir -p "$config_home/state/telegram"
config_audio=$(mktemp /dev/shm/firstmate-telegram-config.XXXXXX)
python3 - "$config_home/state/telegram/pending.json" "$config_audio" <<'PY'
import json, sys, time
json.dump({'audio_path': sys.argv[2], 'created_at': int(time.time()), 'mode': 'parked'}, open(sys.argv[1], 'w'))
PY
touch "$config_home/state/telegram/enabled"
run_tg "$config_home" serve --once >/dev/null 2>&1
[ "$?" -eq 78 ] || fail "missing pairing did not use the permanent configuration exit"
[ ! -e "$config_audio" ] || fail "permanent startup failure retained pending temporary audio"
[ ! -e "$config_home/state/telegram/pending.json" ] || fail "permanent startup failure retained pending voice state"
[ ! -e "$config_home/state/telegram/enabled" ] || fail "missing pairing left transport supervision active"
run_tg "$config_home" pair --user-id 77 --chat-id 77 >/dev/null
cp "$config_home/config/telegram.json" "$config_home/pairing.valid"
rm "$config_home/.env"
touch "$config_home/state/telegram/enabled"
run_tg "$config_home" serve --once >/dev/null 2>&1
[ "$?" -eq 78 ] || fail "missing home token did not use the permanent configuration exit"
[ ! -e "$config_home/state/telegram/enabled" ] || fail "missing home token left transport supervision active"
printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' > "$config_home/.env"
printf '{not-json\n' > "$config_home/config/telegram.json"
chmod 600 "$config_home/config/telegram.json"
touch "$config_home/state/telegram/enabled"
run_tg "$config_home" serve --once >/dev/null 2>&1
[ "$?" -eq 78 ] || fail "malformed pairing did not use the permanent configuration exit"
[ ! -e "$config_home/state/telegram/enabled" ] || fail "malformed pairing left transport supervision active"
cp "$config_home/pairing.valid" "$config_home/config/telegram.json"
chmod 644 "$config_home/config/telegram.json"
touch "$config_home/state/telegram/enabled"
run_tg "$config_home" serve --once >/dev/null 2>&1
[ "$?" -eq 78 ] || fail "unsafe pairing permissions did not use the permanent configuration exit"
[ ! -e "$config_home/state/telegram/enabled" ] || fail "unsafe pairing permissions left transport supervision active"

runtime_home=$(new_home runtime-owner)
start_server "$runtime_home" "$runtime_home/port"
run_tg "$runtime_home" pair --user-id 77 --chat-id 77 >/dev/null
touch "$runtime_home/block-updates"
env FM_HOME="$runtime_home" "$SCRIPT" --test-api-base "$(test_api_base "$runtime_home")" \
  serve --poll-timeout 1 >"$runtime_home/service.out" 2>&1 &
runtime_pid=$!
runtime_started=0
for _ in $(seq 1 100); do
  if [ -e "$runtime_home/updates-entered" ] && [ -e "$runtime_home/state/telegram/enabled" ]; then
    runtime_started=1
    break
  fi
  sleep .02
done
[ "$runtime_started" -eq 1 ] || fail "primary Telegram runtime did not acquire service ownership"
run_tg "$runtime_home" serve --once >/dev/null 2>&1
[ "$?" -eq 1 ] || fail "second Telegram runtime did not refuse stable service ownership"
[ -e "$runtime_home/state/telegram/enabled" ] || fail "refused second runtime cleared the owner's supervision marker"
kill "$runtime_pid" 2>/dev/null || true
rm -f "$runtime_home/block-updates"
wait "$runtime_pid" 2>/dev/null || true
[ ! -e "$runtime_home/state/telegram/enabled" ] || fail "runtime owner did not clear supervision at shutdown"
[ -f "$runtime_home/state/.telegram-service.lock" ] || fail "runtime ownership lock was not stable outside removable state"

atomic_home=$(new_home atomic-retention)
start_server "$atomic_home" "$atomic_home/port"
run_tg "$atomic_home" pair --user-id 77 --chat-id 77 >/dev/null
atomic_inbox="$atomic_home/state/telegram/inbox"
mkdir -p "$atomic_inbox"
old_atomic="$atomic_inbox/.tg-text-u1000-m1000.json.abcdefgh"
unrelated_atomic="$atomic_inbox/.operator-note.abcdefgh"
printf 'old private payload\n' > "$old_atomic"
printf 'unrelated sentinel\n' > "$unrelated_atomic"
python3 - "$old_atomic" <<'PY'
import os, sys, time
old = time.time() - 1200
os.utime(sys.argv[1], (old, old))
PY
for index in $(seq 1 260); do
  suffix=$(printf '%08d' "$index")
  printf 'bounded private payload %s\n' "$index" > "$atomic_inbox/.tg-text-u$((2000 + index))-m$((2000 + index)).json.$suffix"
done
fresh_atomic="$atomic_inbox/.tg-voice-u5000-m5000.json.fresh123"
printf 'fresh private payload\n' > "$fresh_atomic"
chmod 644 "$old_atomic" "$fresh_atomic"
run_tg "$atomic_home" serve --once >/dev/null
[ ! -e "$old_atomic" ] || fail "bounded cleanup retained an expired Telegram atomic payload"
[ -e "$unrelated_atomic" ] || fail "bounded cleanup removed an unrelated hidden file"
[ -e "$fresh_atomic" ] || fail "bounded cleanup removed the newest bounded Telegram atomic payload"
[ "$(path_mode "$fresh_atomic")" = 600 ] || fail "bounded cleanup did not restore private atomic payload permissions"
atomic_count=$(find "$atomic_inbox" -maxdepth 1 -type f \( -name '.tg-text-*.json.*' -o -name '.tg-voice-*.json.*' \) | wc -l | tr -d ' ')
[ "$atomic_count" -le 256 ] || fail "bounded cleanup retained too many Telegram atomic payloads"

rm -f "$home/port"
start_server "$home" "$home/port"
set_updates '[{"update_id":1,"message":{"message_id":10,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"please inspect this"}}]' "$home"
run_tg "$home" serve --once >/dev/null
inbox=$(find "$home/state/telegram/inbox" -name '*.json' -print -quit)
[ -f "$inbox" ] || fail "valid text must be durably queued"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["text"])' "$inbox")" = "please inspect this" ] || fail "queued request text mismatch"
call_count=$(grep -c 'sendMessage' "$home/calls.jsonl")
[ "$call_count" -eq 1 ] || fail "text receipt must be sent once"
python3 - "$home/calls.jsonl" <<'PY' || fail "offline wording mismatch"
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
sent = [call['params']['text'] for call in calls if call['path'].endswith('/sendMessage')]
assert sent[-1] == 'Bot · Message received and queued. It will be processed when Firstmate starts.'
PY
[ ! -e "$home/receipt-before-durable" ] || fail "receipt was sent before request and wake durability"
grep -F 'please inspect this' "$home/state/.wake-queue" >/dev/null && fail "raw Telegram text entered wake queue"
grep -F "telegram tg-" "$home/state/.wake-queue" >/dev/null || fail "wake did not carry local request id"
run_tg "$home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq 1 ] || fail "replayed text must not send a second receipt"
rm -f "$home/state/telegram/seen.json"
run_tg "$home" serve --once >/dev/null
[ "$(find "$home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "interrupted replay created a duplicate request"
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq 1 ] || fail "interrupted replay duplicated the receipt"
run_tg "$home" request-read "$(basename "$inbox" .json)" > "$home/read.txt"
grep -Fx 'please inspect this' "$home/read.txt" >/dev/null || fail "request-read must expose only queued request text"
request_id=$(basename "$inbox" .json)
python3 - "$inbox" <<'PY'
import json, sys
path = sys.argv[1]
record = json.load(open(path, encoding='utf-8'))
record['wake_recorded'] = False
json.dump(record, open(path, 'w', encoding='utf-8'))
PY
run_tg "$home" request-handled "$request_id"
[ ! -f "$inbox" ] || fail "request-handled must move the private request"
python3 - "$home/state/telegram/handled/$request_id.json" <<'PY' || fail "handled wake durability assertion failed"
import json, sys
path = sys.argv[1]
record = json.load(open(path, encoding='utf-8'))
assert record['wake_recorded'] is True
record['wake_recorded'] = False
json.dump(record, open(path, 'w', encoding='utf-8'))
PY
[ "$(run_tg "$home" active-request)" = "$request_id" ] || fail "request handling must persist the active Telegram origin"
grep -F "telegram:$request_id" "$home/state/.wake-queue" >/dev/null || fail "unbound initial claim was not recoverably wakeable"
run_tg "$home" request-handled "$request_id" || fail "replayed initial claim was not idempotent"
python3 - "$home/state/telegram/handled/$request_id.json" <<'PY' || fail "replayed claim durability assertion failed"
import json, sys
assert json.load(open(sys.argv[1], encoding='utf-8'))['wake_recorded'] is True
PY
[ "$(run_tg "$home" active-request --claimed-request "$request_id")" = "$request_id" ] || fail "replayed initial claim lost its conversation route"
long_work_id=$(printf 'a%.0s' $(seq 1 65))
for invalid_work_id in .hidden 'unicode-é' "$long_work_id"; do
  if run_tg "$home" request-bind "$request_id" "$invalid_work_id" >/dev/null 2>&1; then
    fail "request-bind accepted a work id rejected by fm-spawn"
  fi
done
[ "$(run_tg "$home" active-request --claimed-request "$request_id")" = "$request_id" ] || fail "invalid work binding changed the active route"
printf 'endpoint_task_id=terminal-work\n' > "$home/state/terminal-work.meta"
if run_tg "$home" request-bind "$request_id" terminal-work >/dev/null 2>&1; then
  fail "Telegram request bound to a pre-existing terminal work record"
fi
[ "$(run_tg "$home" active-request --claimed-request "$request_id")" = "$request_id" ] || fail "rejected terminal work binding changed the active route"
touch "$home/hold-task-creation-lock"
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" ROOT="$ROOT" bash -c '
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  task_lock="$STATE/.spawn-telegram-work.lock"
  fm_lock_try_acquire "$task_lock" || exit 1
  touch "$FM_HOME/task-creation-lock-held"
  while [ -e "$FM_HOME/hold-task-creation-lock" ]; do sleep .01; done
  fm_lock_release "$task_lock"
' &
task_lock_pid=$!
for _ in $(seq 1 100); do
  [ -e "$home/task-creation-lock-held" ] && break
  sleep .02
done
[ -e "$home/task-creation-lock-held" ] || fail "task creation lock fixture did not start"
if run_tg "$home" request-bind "$request_id" telegram-work >/dev/null 2>&1; then
  rm -f "$home/hold-task-creation-lock"
  wait "$task_lock_pid" || true
  fail "request-bind raced an in-progress terminal task creation"
fi
rm -f "$home/hold-task-creation-lock"
wait "$task_lock_pid" || fail "task creation lock fixture failed"
run_tg "$home" request-bind "$request_id" telegram-work >/dev/null
FM_HOME="$home" "$ROOT/bin/fm-spawn.sh" telegram-work --relaunch \
  >"$home/telegram-relaunch.out" 2>"$home/telegram-relaunch.err" || true
if grep -F 'reserved for an authenticated Telegram-origin spawn' \
    "$home/telegram-relaunch.err" >/dev/null; then
  fail "Telegram reservation blocked adoption by a lifecycle relaunch"
fi
grep -F -- '--relaunch needs an existing task record' \
  "$home/telegram-relaunch.err" >/dev/null || fail "Telegram relaunch did not reach normal metadata adoption"
if FM_TELEGRAM_REQUEST_ID="$request_id" FM_HOME="$home" \
    "$ROOT/bin/fm-spawn.sh" telegram-work "$home" --secondmate \
    >"$home/telegram-secondmate.out" 2>"$home/telegram-secondmate.err"; then
  fail "Telegram-originated work launched as a secondmate"
fi
grep -F 'Telegram-originated work cannot be routed to a secondmate' \
  "$home/telegram-secondmate.err" >/dev/null || fail "Telegram secondmate route was not rejected at publication"
if FM_HOME="$home" "$ROOT/bin/fm-spawn.sh" telegram-work "$home" "sh -c 'exit 0'" --scout \
    >"$home/terminal-spawn.out" 2>"$home/terminal-spawn.err"; then
  fail "ordinary terminal spawn consumed a Telegram-reserved work identifier"
fi
grep -F 'reserved for an authenticated Telegram-origin spawn' "$home/terminal-spawn.err" >/dev/null || fail "fm-spawn did not enforce Telegram publication ownership"
grep -F "telegram:$request_id" "$home/state/.wake-queue" >/dev/null || fail "bind-before-launch lost the initial recovery wake"
bound_initial_route=$(printf '%s\t%s' "$request_id" telegram-work)
[ "$(run_tg "$home" active-request --claimed-request "$request_id")" = "$bound_initial_route" ] || fail "bound initial recovery did not expose its exact work id"
run_tg "$home" request-handled "$request_id" >/dev/null || fail "bound initial recovery claim was not idempotent"
printf 'endpoint_task_id=telegram-work\n' > "$home/state/telegram-work.meta"
set_updates '[]' "$home"
run_tg "$home" serve --once >/dev/null
grep -F "telegram:$request_id" "$home/state/.wake-queue" >/dev/null || fail "terminal publication stole the Telegram work binding"
if run_tg "$home" active-request --work-id telegram-work >/dev/null 2>&1; then
  fail "unverified terminal publication acquired a Telegram origin"
fi
run_tg "$home" publication-authorize "$request_id" telegram-work >/dev/null
printf 'endpoint_task_id=telegram-work\ntelegram_request_id=%s\n' "$request_id" > "$home/state/telegram-work.meta"
run_tg "$home" request-published "$request_id" telegram-work >/dev/null
! grep -F "telegram:$request_id" "$home/state/.wake-queue" >/dev/null || fail "published work retained its initial recovery wake"
[ "$(run_tg "$home" active-request --claimed-request "$request_id")" = "$bound_initial_route" ] || fail "published work binding was not recoverable from a stale claim"
[ "$(run_tg "$home" active-request --work-id telegram-work)" = "$request_id" ] || fail "matching lifecycle work did not resolve its Telegram origin"
rm -f "$home/state/telegram-work.meta"
run_tg "$home" serve --once >/dev/null
! grep -F "telegram:$request_id" "$home/state/.wake-queue" >/dev/null || fail "removing published work reopened the initial recovery wake"
[ "$(run_tg "$home" active-request --work-id telegram-work)" = "$request_id" ] || fail "published Telegram origin depended on an ephemeral work record"
routing_before=$(grep -c 'sendMessage' "$home/calls.jsonl")
if run_tg "$home" active-request --work-id terminal-work >/dev/null 2>&1; then
  fail "unrelated terminal work matched the active Telegram origin"
fi
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$routing_before" ] || fail "unrelated lifecycle lookup sent a Telegram reply"
printf 'Firstmate · decision reply\r\nsecond line\n' > "$home/reply.txt"
response_terminal="$home/response-terminal.txt"
response_status="$home/response-status.txt"
stage_response "$home" "$request_id" wake-decision "$home/reply.txt" >/dev/null
render_response "$home" "$request_id" wake-decision >"$response_terminal"
reply_response "$home" "$request_id" wake-decision >"$response_status"
cmp -s "$home/reply.txt" "$response_terminal" || fail "terminal rendering changed the generated response bytes"
[ "$(cat "$response_status")" = 'Telegram reply sent.' ] || fail "reply transport rendered response content"
python3 - "$home/calls.jsonl" "$home/reply.txt" <<'PY' || fail "reply surface fan-out changed the response bytes"
from pathlib import Path
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
expected = Path(sys.argv[2]).read_bytes()
replies = [call['params']['text'].encode() for call in calls if call['path'].endswith('/sendMessage') and call['params']['text'].startswith('Firstmate · ')]
assert replies[-1] == expected
assert replies.count(expected) == 1
PY
[ "$(run_tg "$home" active-request)" = "$request_id" ] || fail "non-final reply cleared the active origin"
set_updates '[{"update_id":101,"message":{"message_id":110,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"the answer is option two"}}]' "$home"
run_tg "$home" serve --once >/dev/null
continuation_id=tg-text-u101-m110
[ "$(run_tg "$home" request-read "$continuation_id")" = "the answer is option two" ] || fail "active conversation answer was not durably readable"
run_tg "$home" request-handled "$continuation_id"
continuation_route=$(printf '%s\t%s' "$request_id" telegram-work)
[ "$(run_tg "$home" active-request --claimed-request "$continuation_id")" = "$continuation_route" ] || fail "continuation claim lost its exact active work route"
[ "$(run_tg "$home" active-request --claimed-request "$continuation_id")" = "$continuation_route" ] || fail "unacknowledged continuation route was not recoverable"
grep -F "telegram:$continuation_id" "$home/state/.wake-queue" >/dev/null || fail "unacknowledged continuation lost its durable wake"
run_tg "$home" continuation-handled "$continuation_id"
! grep -F "telegram:$continuation_id" "$home/state/.wake-queue" >/dev/null || fail "acknowledged continuation retained its durable wake"
[ "$(run_tg "$home" active-request --work-id telegram-work)" = "$request_id" ] || fail "continuation answer replaced the active Telegram work"
printf 'Firstmate · final answer\n' > "$home/reply.txt"
prepare_response "$home" "$request_id" wake-final "$home/reply.txt" --final
reply_response "$home" "$request_id" wake-final >/dev/null
if run_tg "$home" active-request >/dev/null 2>&1; then fail "final reply did not clear active origin"; fi

grep -F 'final answer' "$home/calls.jsonl" >/dev/null || fail "reply must use the pinned chat"

set_updates '[{"update_id":103,"message":{"message_id":112,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"ask me directly"}}]' "$home"
run_tg "$home" serve --once >/dev/null
direct_id=tg-text-u103-m112
run_tg "$home" request-handled "$direct_id"
run_tg "$home" request-bind "$direct_id" direct-work >/dev/null
if run_tg "$home" request-routed "$direct_id" >/dev/null 2>&1; then
  fail "direct route was acknowledged without durable lifecycle context"
fi
grep -F "telegram:$direct_id" "$home/state/.wake-queue" >/dev/null || fail "refused direct route lost its recovery wake"
printf 'endpoint_task_id=direct-work\ntelegram_request_id=%s\n' "$direct_id" > "$home/state/direct-work.meta"
run_tg "$home" request-published "$direct_id" direct-work >/dev/null
printf 'Firstmate · Which option?\n' > "$home/reply.txt"
prepare_response "$home" "$direct_id" wake-direct-question "$home/reply.txt"
reply_response "$home" "$direct_id" wake-direct-question >/dev/null
run_tg "$home" request-routed "$direct_id" >/dev/null
! grep -F "telegram:$direct_id" "$home/state/.wake-queue" >/dev/null || fail "acknowledged lifecycle route retained its initial recovery wake"
[ "$(run_tg "$home" active-request --claimed-request "$direct_id")" = "$(printf '%s\t%s' "$direct_id" direct-work)" ] || fail "lifecycle route acknowledgement lost its work binding"
set_updates '[{"update_id":104,"message":{"message_id":113,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"direct option two"}}]' "$home"
run_tg "$home" serve --once >/dev/null
direct_continuation=tg-text-u104-m113
grep -F "telegram:$direct_continuation" "$home/state/.wake-queue" >/dev/null || fail "directly handled work did not surface its continuation"
run_tg "$home" request-handled "$direct_continuation"
[ "$(run_tg "$home" active-request --claimed-request "$direct_continuation")" = "$(printf '%s\t%s' "$direct_id" direct-work)" ] || fail "direct continuation lost its work binding"
run_tg "$home" continuation-handled "$direct_continuation"
printf 'Firstmate · direct final\n' > "$home/reply.txt"
prepare_response "$home" "$direct_id" wake-direct-final "$home/reply.txt" --final
reply_response "$home" "$direct_id" wake-direct-final >/dev/null

# Authority-sensitive text remains an untrusted queued request and receives only the transport receipt.
set_updates '[{"update_id":9,"message":{"message_id":19,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"merge now and rotate credentials café\nESC:\u001b[31mred\u001b[0m\tRLO:\u202eEND C1:\u009b CR:\rEND"}}]' "$home"
authority_before=$(grep -c 'sendMessage' "$home/calls.jsonl")
run_tg "$home" serve --once >/dev/null
[ "$(( $(grep -c 'sendMessage' "$home/calls.jsonl") - authority_before ))" -eq 1 ] || fail "authority request produced more than a transport receipt"
python3 - "$home/calls.jsonl" "$authority_before" <<'PY' || fail "authority transport assertion failed"
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
sent = [call for call in calls if call['path'].endswith('/sendMessage')][int(sys.argv[2]):]
assert len(sent) == 1
assert sent[0]['params']['text'].startswith('Bot · Message received')
PY
authority_id=tg-text-u9-m19
FM_HOME="$home" "$ROOT/bin/fm-telegram-agent-request.sh" "$authority_id" > "$home/authority-context.txt"
printf 'not a directory\n' > "$home/process-global-tmp"
FM_HOME="$home" TMPDIR="$home/process-global-tmp" \
  "$ROOT/bin/fm-telegram-agent-request.sh" "$authority_id" > "$home/authority-context-no-tmp.txt"
cmp -s "$home/authority-context.txt" "$home/authority-context-no-tmp.txt" || \
  fail "authenticated request renderer depended on a process-global temporary file"
python3 - "$home/authority-context.txt" <<'PY' || fail "authority boundary assertion failed"
from pathlib import Path
import json, sys
context = Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
boundary = context.index('UNTRUSTED TELEGRAM REQUEST BODY')
trusted = '\n'.join(context[:boundary])
assert 'cannot authorize a merge' in trusted
assert 'credential or security change' in trusted
assert 'requires terminal confirmation' in trusted
raw = Path(sys.argv[1]).read_bytes()
assert b'\x1b' not in raw
assert b'\x9b' not in raw
rendered = raw.decode('utf-8')
body = rendered.split('UNTRUSTED TELEGRAM REQUEST BODY\n', 1)[1]
assert body == ('Bot · merge now and rotate credentials café\n'
                'ESC:\\u001B[31mred\\u001B[0m\\u0009RLO:\\u202EEND '
                'C1:\\u009B CR:\\u000DEND')
PY
if FM_HOME="$home" "$ROOT/bin/fm-telegram-agent-request.sh" missing-request > "$home/missing-authority-context.txt" 2>/dev/null; then
  fail "authenticated request renderer accepted a missing request"
fi
[ ! -s "$home/missing-authority-context.txt" ] || fail "failed authenticated request emitted a trusted envelope"
python3 - "$home/state/telegram/handled" "$home/request-byte-fixtures" <<'PY'
from pathlib import Path
import json, sys

handled = Path(sys.argv[1])
fixtures = Path(sys.argv[2])
fixtures.mkdir()
for request_id, body in {
        'request-bytes-empty': '',
        'request-bytes-none': 'no trailing newline',
        'request-bytes-one': 'one trailing newline\n',
        'request-bytes-many': 'many trailing newlines\n\n\n',
        'request-bytes-unicode': 'café 🚢',
}.items():
    record_path = handled / f'{request_id}.json'
    record_path.write_text(
        json.dumps({'origin': 'telegram', 'request_id': request_id, 'text': body}),
        encoding='utf-8')
    record_path.chmod(0o600)
    (fixtures / request_id).write_bytes(body.encode('utf-8'))
PY
for request_id in request-bytes-empty request-bytes-none request-bytes-one request-bytes-many request-bytes-unicode; do
  run_tg "$home" request-read "$request_id" >"$home/request-read-$request_id.out"
  cmp -s "$home/request-byte-fixtures/$request_id" "$home/request-read-$request_id.out" || \
    fail "request-read changed the exact body bytes for $request_id"
  env FM_HOME="$home" PYTHONIOENCODING=latin-1 "$SCRIPT" request-read "$request_id" \
    >"$home/request-read-locale-$request_id.out"
  cmp -s "$home/request-byte-fixtures/$request_id" "$home/request-read-locale-$request_id.out" || \
    fail "request-read changed UTF-8 body bytes under a non-UTF-8 process encoding for $request_id"
  FM_HOME="$home" "$ROOT/bin/fm-telegram-agent-request.sh" "$request_id" \
    >"$home/request-render-$request_id.out"
  python3 - "$home/request-byte-fixtures/$request_id" \
    "$home/request-render-$request_id.out" <<'PY' || fail "authenticated rendering changed exact request body bytes"
from pathlib import Path
import sys

expected = Path(sys.argv[1]).read_bytes()
rendered = Path(sys.argv[2]).read_bytes()
marker = b'UNTRUSTED TELEGRAM REQUEST BODY\nBot \xc2\xb7 '
assert rendered.count(marker) == 1
assert rendered.split(marker, 1)[1] == expected
PY
done

# Unsupported, malformed, and unpinned updates are dropped without a Bot API send.
before=$(grep -c 'sendMessage' "$home/calls.jsonl")
callbacks_before=$(grep -c 'answerCallbackQuery' "$home/calls.jsonl")
files_before=$(grep -c 'getFile' "$home/calls.jsonl")
malformed_inbox_before=$(find "$home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')
set_raw_updates '[{"update_id":9002,"message":{"message_id":9002,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"missing mandatory date"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$before" ] || fail "message missing its mandatory date received a reply"
[ "$(find "$home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq "$malformed_inbox_before" ] || fail "message missing its mandatory date was queued"
set_updates '[{"update_id":2,"message":{"message_id":11,"from":{"id":999},"chat":{"id":77,"type":"private"},"text":"ignore"}},{"update_id":3,"message":{"message_id":12,"from":{"id":77},"chat":{"id":77,"type":"group"},"text":"ignore"}},{"update_id":4,"message":{"message_id":13,"from":{"id":77},"chat":{"id":77,"type":"private"},"photo":[{"file_id":"must not download"}]}},{"update_id":5,"edited_message":{"message":{"voice":{"file_id":"must not download"}}}},{"update_id":7,"callback_query":{"id":"bad-shape","from":{"id":77},"data":"cancel:any:1","message":{"message_id":70,"chat":"not-an-object"}}},{"update_id":8,"callback_query":{"from":{"id":77},"data":"cancel:any:1","message":{"message_id":80,"chat":{"id":77,"type":"private"}}}},{"update_id":true,"message":{"message_id":81,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"boolean update"}},{"update_id":81,"message":{"message_id":true,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"boolean message"}},{"update_id":82,"message":{"message_id":82,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"","duration":2,"file_size":20}}},{"update_id":83,"message":{"message_id":83,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-bool-duration","duration":true,"file_size":20}}},{"update_id":84,"message":{"message_id":84,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-bool-size","duration":2,"file_size":true}}},{"update_id":85,"message":{"message_id":85,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"conflicting text","photo":[{"file_id":"must not download"}]}},{"update_id":86,"message":{"message_id":86,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"must not download","duration":2,"file_size":20},"sticker":{"file_id":"must not download"}}},{"update_id":87,"message":{"message_id":87,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"conflicting update"},"edited_message":{"message_id":88,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"must not parse"}},{"update_id":88,"message":{"message_id":88,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"unknown update companion"},"future_update":{"opaque":"must not parse"}},{"update_id":89,"message":{"message_id":89,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"unknown message content","future_content":{"opaque":"must not parse"}}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$before" ] || fail "unsupported or unpinned updates must be silent"
[ "$(grep -c 'answerCallbackQuery' "$home/calls.jsonl")" -eq "$callbacks_before" ] || fail "malformed callback received an acknowledgement"
[ "$(grep -c 'getFile' "$home/calls.jsonl")" -eq "$files_before" ] || fail "malformed voice metadata triggered a download"
! grep -F 'must not download' "$home/calls.jsonl" >/dev/null || fail "unsupported media was downloaded"
set_raw_updates '[{"update_id":8999,"message":{"message_id":8999,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"\ud800","duration":2,"file_size":20}}}]' "$home"
run_tg "$home" serve --once >/dev/null || fail "malformed Unicode voice identifier stopped the transport"
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$before" ] || fail "malformed Unicode voice identifier received a reply"
[ "$(grep -c 'getFile' "$home/calls.jsonl")" -eq "$files_before" ] || fail "malformed Unicode voice identifier reached Telegram file lookup"
python3 - "$home/updates.json" <<'PY' || fail "oversized identifier fixture failed"
import json, sys
oversized = 1 << 52
json.dump([
    {'update_id': oversized, 'message': {
        'message_id': 90, 'date': 1, 'from': {'id': 77},
        'chat': {'id': 77, 'type': 'private'}, 'text': 'oversized update'}},
    {'update_id': 90, 'message': {
        'message_id': oversized, 'date': 1, 'from': {'id': 77},
        'chat': {'id': 77, 'type': 'private'}, 'text': 'oversized message'}},
    {'update_id': 91, 'callback_query': {
        'id': 'x' * 257, 'from': {'id': 77}, 'data': 'cancel:any:1',
        'message': {'message_id': 91, 'date': 1, 'chat': {'id': 77, 'type': 'private'}}}},
    {'update_id': 92, 'callback_query': {
        'id': 'oversized-callback-message', 'from': {'id': 77}, 'data': 'cancel:any:1',
        'message': {'message_id': oversized, 'date': 1, 'chat': {'id': 77, 'type': 'private'}}}},
], open(sys.argv[1], 'w', encoding='utf-8'))
PY
run_tg "$home" serve --once >/dev/null || fail "oversized identifiers stopped the transport"
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$before" ] || fail "oversized identifiers received a reply"
[ "$(grep -c 'answerCallbackQuery' "$home/calls.jsonl")" -eq "$callbacks_before" ] || fail "oversized callback identifiers were acknowledged"
! find "$home/state/telegram/inbox" -name '*4503599627370496*' -print -quit | grep . >/dev/null || fail "oversized identifiers reached request paths"
zero_inbox_before=$(find "$home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')
set_updates '[{"update_id":9000,"message":{"message_id":0,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"zero message"}},{"update_id":9001,"callback_query":{"id":"zero-callback-message","from":{"id":77},"message":{"message_id":0,"chat":{"id":77,"type":"private"}},"data":"cancel:any:1"}}]' "$home"
run_tg "$home" serve --once >/dev/null || fail "zero message identifiers stopped the transport"
[ "$(find "$home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq "$zero_inbox_before" ] || fail "zero message identifier was queued"
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$before" ] || fail "zero message identifier received a reply"
[ "$(grep -c 'answerCallbackQuery' "$home/calls.jsonl")" -eq "$callbacks_before" ] || fail "zero callback message identifier was acknowledged"

# Locked admission retains only the newest 256 queued requests for text and confirmed voice.
capacity_home=$(new_home capacity)
start_server "$capacity_home" "$capacity_home/port"
run_tg "$capacity_home" pair --user-id 77 --chat-id 77 >/dev/null
cat > "$capacity_home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
printf 'capacity voice transcript\n'
SH
chmod +x "$capacity_home/parakeet.sh"
python3 - "$capacity_home/config/telegram.json" "$capacity_home/parakeet.sh" "$capacity_home/updates.json" <<'PY'
import json, shlex, sys
config_path, parakeet, updates_path = sys.argv[1:]
config = json.load(open(config_path, encoding='utf-8'))
config['parakeet_command'] = shlex.quote(parakeet)
json.dump(config, open(config_path, 'w', encoding='utf-8'))
updates = [
    {'update_id': value, 'message': {
        'message_id': value, 'date': 1, 'from': {'id': 77},
        'chat': {'id': 77, 'type': 'private'}, 'text': f'capacity request {value}'}}
    for value in range(257, 0, -1)
]
json.dump(updates, open(updates_path, 'w', encoding='utf-8'))
PY
chmod 600 "$capacity_home/config/telegram.json"
run_tg "$capacity_home" serve --once >/dev/null
[ "$(find "$capacity_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 256 ] || fail "text admission exceeded the 256 request cap"
[ ! -e "$capacity_home/state/telegram/inbox/tg-text-u257-m257.json" ] || fail "text admission did not evict the oldest queued request"
[ -e "$capacity_home/state/telegram/inbox/tg-text-u1-m1.json" ] || fail "text admission did not retain the newest queued request"
set_updates '[{"update_id":258,"message":{"message_id":258,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"capacity-voice","duration":2,"file_size":20}}}]' "$capacity_home"
run_tg "$capacity_home" serve --once >/dev/null
capacity_send=$(callback_data "$capacity_home" send)
set_updates "[{\"update_id\":259,\"callback_query\":{\"id\":\"capacity-send\",\"from\":{\"id\":77},\"message\":{\"message_id\":259,\"chat\":{\"id\":77,\"type\":\"private\"}},\"data\":\"$capacity_send\"}}]" "$capacity_home"
run_tg "$capacity_home" serve --once >/dev/null
[ "$(find "$capacity_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 256 ] || fail "confirmed voice admission exceeded the 256 request cap"
[ ! -e "$capacity_home/state/telegram/inbox/tg-text-u256-m256.json" ] || fail "confirmed voice admission did not evict the oldest queued request"
[ -e "$capacity_home/state/telegram/inbox/tg-voice-u258-m258.json" ] || fail "confirmed voice admission did not retain its queued request"

# A live primary must have its harness-owned watcher before activation can accept requests.
live_home=$(new_home live-primary)
start_server "$live_home" "$live_home/port"
run_tg "$live_home" pair --user-id 77 --chat-id 77 >/dev/null
bash -c 'exec -a pi sleep 30' &
harness_pid=$!
sleep .05
mkdir -p "$live_home/state"
printf '%s\n' "$harness_pid" > "$live_home/state/.lock"
set_updates '[{"update_id":60,"message":{"message_id":60,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"live request"}}]' "$live_home"
get_updates_before=$(grep -c 'getUpdates' "$live_home/calls.jsonl" || true)
if run_tg "$live_home" serve --once >/dev/null 2>&1; then
  fail "transport activated beside an idle primary without healthy supervision"
fi
[ "$(grep -c 'getUpdates' "$live_home/calls.jsonl" || true)" -eq "$get_updates_before" ] || fail "failed activation polled Telegram before supervision was healthy"
[ -e "$live_home/state/telegram/enabled" ] || fail "failed activation did not record the harness-owned supervision need"
touch "$live_home/state/.last-heartbeat" "$live_home/state/.last-check"
FM_HOME="$live_home" FM_STATE_OVERRIDE="$live_home/state" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 "$ROOT/bin/fm-watch.sh" > "$live_home/telegram-watcher.out" 2>&1 &
telegram_watcher_pid=$!
watcher_ready=0
for _ in $(seq 1 100); do
  if [ -s "$live_home/state/.watch.lock/pid" ] && [ -e "$live_home/state/.last-watcher-beat" ]; then watcher_ready=1; break; fi
  sleep .02
done
[ "$watcher_ready" -eq 1 ] || fail "harness-safe Telegram supervision watcher did not become healthy"
run_tg "$live_home" serve --once >/dev/null
watcher_delivered=0
for _ in $(seq 1 100); do
  if grep -F "check: telegram tg-text-u60-m60" "$live_home/telegram-watcher.out" >/dev/null 2>&1; then watcher_delivered=1; break; fi
  sleep .02
done
kill "$telegram_watcher_pid" 2>/dev/null || true
wait "$telegram_watcher_pid" 2>/dev/null || true
kill "$harness_pid" 2>/dev/null || true
[ "$watcher_delivered" -eq 1 ] || fail "healthy watcher did not surface the queued Telegram request"
python3 - "$live_home/calls.jsonl" <<'PY' || fail "live-primary receipt mismatch"
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
sent = [call['params']['text'] for call in calls if call['path'].endswith('/sendMessage')]
assert 'Bot · Message received.' in sent
PY
rm -f "$home/port"
start_server "$home" "$home/port"
set_updates '[{"update_id":6,"message":{"message_id":14,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"queued request"}}]' "$home"
run_tg "$home" serve --once >/dev/null
live_id=tg-text-u6-m14
set_updates '[{"update_id":102,"message":{"message_id":111,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"later queued request"}}]' "$home"
run_tg "$home" serve --once >/dev/null
later_id=tg-text-u102-m111
python3 - "$home/state/telegram/inbox/$live_id.json" <<'PY'
import os, sys, time
future = time.time() + 60
os.utime(sys.argv[1], (future, future))
PY
run_tg "$home" request-handled "$authority_id"
run_tg "$home" request-bind "$authority_id" authority-work >/dev/null
printf 'endpoint_task_id=authority-work\ntelegram_request_id=%s\n' "$authority_id" > "$home/state/authority-work.meta"
run_tg "$home" request-published "$authority_id" authority-work >/dev/null
if run_tg "$home" request-handled "$live_id" >/dev/null 2>&1; then fail "a second Telegram conversation bypassed the active binding"; fi
if run_tg "$home" active-request --work-id terminal-work >/dev/null 2>&1; then fail "terminal-originated work matched an authority request"; fi
python3 - "$home/state/.wake-queue" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text(encoding='utf-8').splitlines()
path.write_text(''.join(line + '\n' for line in lines if '\ttelegram:' not in line), encoding='utf-8')
PY
python3 - "$home/state/telegram/handled/$authority_id.json" "$home/state/telegram/closing.json" "$authority_id" <<'PY'
import json, sys
request_path, closing_path, request_id = sys.argv[1:]
record = json.load(open(request_path, encoding='utf-8'))
record['final_sent'] = True
json.dump(record, open(request_path, 'w', encoding='utf-8'))
json.dump({'request_id': request_id, 'created_at': 1}, open(closing_path, 'w', encoding='utf-8'))
PY
if run_tg "$home" active-request >/dev/null 2>&1; then fail "interrupted finalization left its predecessor active"; fi
grep -F "telegram $live_id" "$home/state/.wake-queue" >/dev/null || fail "finalization recovery did not wake the oldest admitted conversation"
! grep -F "telegram $later_id" "$home/state/.wake-queue" >/dev/null || fail "mutable request mtime reordered the Telegram conversation queue"
run_tg "$home" request-handled "$live_id" >/dev/null || fail "recovered next conversation remained blocked by its predecessor"

# A delivery-unknown receipt backs off, survives a claim, and reconciles from handled state.
retry_home=$(new_home retry)
start_server "$retry_home" "$retry_home/port"
run_tg "$retry_home" pair --user-id 77 --chat-id 77 >/dev/null
printf '2\n' > "$retry_home/disconnect-after-send-count"
set_updates '[{"update_id":10,"message":{"message_id":10,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"retry my receipt"}}]' "$retry_home"
FM_TELEGRAM_BOT_TOKEN=ambient-wrong-token run_tg "$retry_home" serve --once >/dev/null
[ "$(find "$retry_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "delivery-unknown receipt lost or duplicated the request"
retry_request=$(find "$retry_home/state/telegram/inbox" -name '*.json' -print -quit)
python3 - "$retry_request" <<'PY' || fail "delivery-unknown receipt assertion failed"
import json, sys
record = json.load(open(sys.argv[1]))
assert record['receipt_status'] == 'delivery_unknown'
assert record['receipt_attempts'] == 1
assert record['receipt_unknown_attempts'] == 1
assert record['receipt_retry_at'] > record['receipt_attempted_at']
PY
run_tg "$retry_home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$retry_home/calls.jsonl")" -eq 1 ] || fail "delivery-unknown receipt ignored its retry backoff"
python3 - "$retry_request" <<'PY'
import json, sys
data = json.load(open(sys.argv[1])); data['receipt_retry_at'] = 0
json.dump(data, open(sys.argv[1], 'w'))
PY
run_tg "$retry_home" serve --once >/dev/null
retry_id=$(basename "$retry_request" .json)
run_tg "$retry_home" request-handled "$retry_id" >/dev/null
python3 - "$retry_home/state/telegram/handled/$retry_id.json" <<'PY' || fail "handled receipt retry assertion failed"
import json, sys
path = sys.argv[1]; data = json.load(open(path))
assert data['receipt_status'] == 'delivery_unknown'
assert data['receipt_attempts'] == 2
data['receipt_retry_at'] = 0
json.dump(data, open(path, 'w'))
PY
set_updates '[]' "$retry_home"
run_tg "$retry_home" serve --once >/dev/null
python3 - "$retry_home/state/telegram/handled/$retry_id.json" <<'PY' || fail "reconciled handled receipt assertion failed"
import json, sys
assert json.load(open(sys.argv[1]))['receipt_status'] == 'sent'
PY
[ "$(grep -c 'sendMessage' "$retry_home/calls.jsonl")" -eq 3 ] || fail "handled delivery-unknown receipt was not reconciled"
! grep -F 'ambient-wrong-token' "$retry_home/calls.jsonl" >/dev/null || fail "ambient token overrode the selected home's .env token"
grep -F '/bottest-only-token/' "$retry_home/calls.jsonl" >/dev/null || fail "service did not use the selected home's .env token"

# Delivery-unknown recovery reaches a finite terminal state instead of retrying forever.
terminal_home=$(new_home terminal-receipt)
start_server "$terminal_home" "$terminal_home/port"
run_tg "$terminal_home" pair --user-id 77 --chat-id 77 >/dev/null
printf '4\n' > "$terminal_home/disconnect-after-send-count"
set_updates '[{"update_id":16,"message":{"message_id":16,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"bound my receipt retries"}}]' "$terminal_home"
run_tg "$terminal_home" serve --once >/dev/null
terminal_request="$terminal_home/state/telegram/inbox/tg-text-u16-m16.json"
for expected in 2 3; do
  python3 - "$terminal_request" <<'PY'
import json, sys
path = sys.argv[1]; data = json.load(open(path)); data['receipt_retry_at'] = 0
json.dump(data, open(path, 'w'))
PY
  run_tg "$terminal_home" serve --once >/dev/null
  python3 - "$terminal_request" "$expected" <<'PY' || fail "bounded delivery-unknown attempt assertion failed"
import json, sys
record = json.load(open(sys.argv[1]))
assert record['receipt_attempts'] == int(sys.argv[2])
PY
done
python3 - "$terminal_request" <<'PY' || fail "terminal delivery-unknown state assertion failed"
import json, sys
assert json.load(open(sys.argv[1]))['receipt_status'] == 'delivery_unknown_terminal'
PY
run_tg "$terminal_home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$terminal_home/calls.jsonl")" -eq 3 ] || fail "terminal delivery-unknown receipt retried beyond its bound"

rejected_home=$(new_home rejected-receipt)
start_server "$rejected_home" "$rejected_home/port"
run_tg "$rejected_home" pair --user-id 77 --chat-id 77 >/dev/null
printf '4\n' > "$rejected_home/fail-send-count"
set_updates '[{"update_id":17,"message":{"message_id":17,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"bound rejected receipt retries"}}]' "$rejected_home"
run_tg "$rejected_home" serve --once >/dev/null
rejected_request="$rejected_home/state/telegram/inbox/tg-text-u17-m17.json"
python3 - "$rejected_request" <<'PY' || fail "rejected receipt assertion failed"
import json, sys
record = json.load(open(sys.argv[1], encoding='utf-8'))
assert record['receipt_status'] == 'rejected'
assert record['receipt_attempts'] == 1
assert record['receipt_retry_at'] > record['receipt_attempted_at']
PY
run_tg "$rejected_home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$rejected_home/calls.jsonl")" -eq 1 ] || fail "rejected receipt ignored its retry backoff"
for expected in 2 3; do
  python3 - "$rejected_request" <<'PY'
import json, sys
path = sys.argv[1]
record = json.load(open(path, encoding='utf-8'))
record['receipt_retry_at'] = 0
json.dump(record, open(path, 'w', encoding='utf-8'))
PY
  run_tg "$rejected_home" serve --once >/dev/null
  python3 - "$rejected_request" "$expected" <<'PY' || fail "bounded rejected receipt attempt assertion failed"
import json, sys
record = json.load(open(sys.argv[1], encoding='utf-8'))
assert record['receipt_attempts'] == int(sys.argv[2])
PY
done
python3 - "$rejected_request" <<'PY' || fail "terminal rejected receipt state assertion failed"
import json, sys
assert json.load(open(sys.argv[1], encoding='utf-8'))['receipt_status'] == 'rejected_terminal'
PY
run_tg "$rejected_home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$rejected_home/calls.jsonl")" -eq 3 ] || fail "terminal rejected receipt retried beyond its bound"

expiry_home=$(new_home expiry)
start_server "$expiry_home" "$expiry_home/port"
run_tg "$expiry_home" pair --user-id 77 --chat-id 77 >/dev/null
set_updates '[{"update_id":11,"message":{"message_id":11,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"expire my request"}}]' "$expiry_home"
run_tg "$expiry_home" serve --once >/dev/null
expiry_request=$(find "$expiry_home/state/telegram/inbox" -name '*.json' -print -quit)
python3 - "$expiry_request" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path)); data['created_at'] = 0
json.dump(data, open(path, 'w'))
PY
set_updates '[]' "$expiry_home"
run_tg "$expiry_home" serve --once >/dev/null
[ ! -e "$expiry_request" ] || fail "expired unhandled request exceeded bounded retention"
! grep -F "telegram:$(basename "$expiry_request" .json)" "$expiry_home/state/.wake-queue" >/dev/null || fail "expired request left its Telegram wake queued"

# Boolean identities cannot alias the pinned integer identity.
identity_home=$(new_home identity)
start_server "$identity_home" "$identity_home/port"
run_tg "$identity_home" pair --user-id 1 --chat-id 1 >/dev/null
set_updates '[{"update_id":12,"message":{"message_id":12,"from":{"id":true},"chat":{"id":1,"type":"private"},"text":"boolean sender"}},{"update_id":13,"message":{"message_id":13,"from":{"id":1},"chat":{"id":true,"type":"private"},"text":"boolean chat"}},{"update_id":14,"callback_query":{"id":"boolean-callback-sender","from":{"id":true},"data":"cancel:any:1","message":{"message_id":14,"chat":{"id":1,"type":"private"}}}},{"update_id":15,"callback_query":{"id":"boolean-callback-chat","from":{"id":1},"data":"cancel:any:1","message":{"message_id":15,"chat":{"id":true,"type":"private"}}}}]' "$identity_home"
run_tg "$identity_home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$identity_home/calls.jsonl")" -eq 0 ] || fail "boolean identity queued or acknowledged a request"
[ "$(grep -c 'answerCallbackQuery' "$identity_home/calls.jsonl")" -eq 0 ] || fail "boolean callback identity was acknowledged"
[ "$(find "$identity_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ] || fail "boolean identity aliased the pinned integer identity"

# Only the immutable-order head is woken, and a queued continuation keeps its predecessor.
order_home=$(new_home order)
start_server "$order_home" "$order_home/port"
run_tg "$order_home" pair --user-id 77 --chat-id 77 >/dev/null
set_updates '[{"update_id":30,"message":{"message_id":30,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"conversation A"}},{"update_id":31,"message":{"message_id":31,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"conversation B"}},{"update_id":32,"message":{"message_id":32,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"conversation C"}}]' "$order_home"
run_tg "$order_home" serve --once >/dev/null
order_a=tg-text-u30-m30
order_b=tg-text-u31-m31
order_c=tg-text-u32-m32
[ "$(grep -c "telegram:$order_a" "$order_home/state/.wake-queue")" -eq 1 ] || fail "ordered queue did not publish its first head exactly once"
! grep -F "telegram:$order_b" "$order_home/state/.wake-queue" >/dev/null || fail "ordered queue published its second request early"
! grep -F "telegram:$order_c" "$order_home/state/.wake-queue" >/dev/null || fail "ordered queue published its third request early"
: > "$order_home/state/.seen-telegram-$order_a"
order_wake_sequence=$(cat "$order_home/state/.wake-queue.seq")
set_updates '[]' "$order_home"
run_tg "$order_home" serve --once >/dev/null
[ "$(cat "$order_home/state/.wake-queue.seq")" = "$order_wake_sequence" ] || fail "unchanged wake head was re-emitted during reconciliation"
[ -e "$order_home/state/.seen-telegram-$order_a" ] || fail "unchanged surfaced wake marker was cleared during reconciliation"
[ "$(grep -c "telegram:$order_a" "$order_home/state/.wake-queue")" -eq 1 ] || fail "unchanged surfaced wake was duplicated during reconciliation"
if run_tg "$order_home" request-handled "$order_b" >/dev/null 2>&1; then
  fail "request handling claimed a later conversation ahead of the ordered head"
fi
[ ! -e "$order_home/state/telegram/active.json" ] || fail "out-of-order claim created an active conversation"
run_tg "$order_home" request-handled "$order_a" >/dev/null
run_tg "$order_home" request-bind "$order_a" order-work >/dev/null
printf 'endpoint_task_id=order-work\ntelegram_request_id=%s\n' "$order_a" > "$order_home/state/order-work.meta"
run_tg "$order_home" request-published "$order_a" order-work >/dev/null
set_updates '[{"update_id":33,"message":{"message_id":33,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"late answer for A"}}]' "$order_home"
run_tg "$order_home" serve --once >/dev/null
order_continuation=tg-text-u33-m33
[ "$(grep -c "telegram:$order_continuation" "$order_home/state/.wake-queue")" -eq 1 ] || fail "active conversation continuation was not the sole wake head"
printf 'Firstmate · A final\n' > "$order_home/reply.txt"
prepare_response "$order_home" "$order_a" wake-order-a-final "$order_home/reply.txt" --final
order_final_status=0
reply_response "$order_home" "$order_a" wake-order-a-final >/dev/null || order_final_status=$?
[ "$order_final_status" -eq 2 ] || fail "final reply did not report its queued continuation as incomplete"
[ "$(run_tg "$order_home" active-request --work-id order-work)" = "$order_a" ] || fail "queued continuation lost its active predecessor during finalization"
run_tg "$order_home" request-handled "$order_continuation" >/dev/null
order_continuation_route=$(printf '%s\t%s' "$order_a" order-work)
[ "$(run_tg "$order_home" active-request --claimed-request "$order_continuation")" = "$order_continuation_route" ] || fail "claimed continuation lost its exact work route during finalization"
[ "$(run_tg "$order_home" active-request --claimed-request "$order_continuation")" = "$order_continuation_route" ] || fail "claimed continuation route was consumed before acknowledgement"
run_tg "$order_home" continuation-handled "$order_continuation"
if next_active=$(run_tg "$order_home" active-request 2>/dev/null); then
  [ "$next_active" != "$order_continuation" ] || fail "continuation was promoted to unrelated active work"
fi
[ "$(grep -c "telegram:$order_b" "$order_home/state/.wake-queue")" -eq 1 ] || fail "closing did not publish the immutable-order next head"
! grep -F "telegram:$order_c" "$order_home/state/.wake-queue" >/dev/null || fail "closing published a later request ahead of the head"
run_tg "$order_home" request-handled "$order_b" >/dev/null
printf 'Firstmate · B final\n' > "$order_home/reply.txt"
prepare_response "$order_home" "$order_b" wake-order-b-final "$order_home/reply.txt" --final
reply_response "$order_home" "$order_b" wake-order-b-final >/dev/null
[ "$(grep -c "telegram:$order_c" "$order_home/state/.wake-queue")" -eq 1 ] || fail "ordered queue did not advance to its final head"

# A direct final must release queued continuations in order without re-waking its predecessor.
direct_order_home=$(new_home direct-order)
start_server "$direct_order_home" "$direct_order_home/port"
run_tg "$direct_order_home" pair --user-id 77 --chat-id 77 >/dev/null
set_updates '[{"update_id":40,"message":{"message_id":40,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"direct initial"}}]' "$direct_order_home"
run_tg "$direct_order_home" serve --once >/dev/null
direct_order_a=tg-text-u40-m40
run_tg "$direct_order_home" request-handled "$direct_order_a" >/dev/null
set_updates '[{"update_id":41,"message":{"message_id":41,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"direct continuation one"}},{"update_id":42,"message":{"message_id":42,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"direct continuation two"}}]' "$direct_order_home"
run_tg "$direct_order_home" serve --once >/dev/null
direct_order_b=tg-text-u41-m41
direct_order_c=tg-text-u42-m42
printf 'Firstmate · direct final before continuations\n' > "$direct_order_home/reply.txt"
direct_order_terminal="$direct_order_home/response-terminal.txt"
direct_order_status="$direct_order_home/response-status.txt"
direct_order_replay_status="$direct_order_home/response-replay-status.txt"
stage_response "$direct_order_home" "$direct_order_a" wake-direct-order-final \
  "$direct_order_home/reply.txt" --final >/dev/null
render_response "$direct_order_home" "$direct_order_a" wake-direct-order-final >"$direct_order_terminal"
direct_final_status=0
reply_response "$direct_order_home" "$direct_order_a" wake-direct-order-final \
  >"$direct_order_status" || direct_final_status=$?
[ "$direct_final_status" -eq 2 ] || fail "direct final did not report queued continuations as incomplete"
[ "$(cat "$direct_order_status")" = 'Telegram final reply sent; continuation handling remains pending.' ] || fail "direct final transport rendered response content"
direct_replay_status=0
render_response "$direct_order_home" "$direct_order_a" wake-direct-order-final \
  >"$direct_order_home/response-replay-terminal.txt"
reply_response "$direct_order_home" "$direct_order_a" wake-direct-order-final \
  >"$direct_order_replay_status" || direct_replay_status=$?
[ "$direct_replay_status" -eq 2 ] || fail "replayed direct final did not preserve pending status"
[ "$(cat "$direct_order_replay_status")" = 'Telegram final reply already sent; continuation handling remains pending.' ] || fail "replayed direct final rendered response content"
[ ! -s "$direct_order_home/response-replay-terminal.txt" ] || fail "replayed direct final rendered a second terminal response"
cmp -s "$direct_order_home/reply.txt" "$direct_order_terminal" || fail "direct final terminal rendering changed response bytes"
python3 - "$direct_order_home/calls.jsonl" "$direct_order_home/reply.txt" <<'PY' || fail "direct final replay changed fan-out behavior"
from pathlib import Path
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
expected = Path(sys.argv[2]).read_bytes()
replies = [call['params']['text'].encode() for call in calls if call['path'].endswith('/sendMessage')]
assert replies.count(expected) == 1
PY
! grep -F "telegram:$direct_order_a" "$direct_order_home/state/.wake-queue" >/dev/null || fail "direct final re-woke its handled predecessor"
[ "$(grep -c "telegram:$direct_order_b" "$direct_order_home/state/.wake-queue")" -eq 1 ] || fail "direct final did not wake the first continuation"
! grep -F "telegram:$direct_order_c" "$direct_order_home/state/.wake-queue" >/dev/null || fail "direct final woke a later continuation out of order"
run_tg "$direct_order_home" request-handled "$direct_order_b" >/dev/null
run_tg "$direct_order_home" request-handled "$direct_order_b" >/dev/null || fail "replayed first continuation claim was not idempotent"
[ "$(run_tg "$direct_order_home" active-request --claimed-request "$direct_order_b")" = "$direct_order_a" ] || fail "first direct continuation route was not recoverable"
printf 'Firstmate · first continuation answered\n' > "$direct_order_home/continuation-reply.txt"
prepare_response "$direct_order_home" "$direct_order_b" wake-direct-order-b \
  "$direct_order_home/continuation-reply.txt"
reply_response "$direct_order_home" "$direct_order_a" wake-direct-order-b >"$direct_order_status"
[ "$(cat "$direct_order_status")" = 'Telegram reply sent.' ] || fail "first direct continuation reply rendered response content"
run_tg "$direct_order_home" continuation-handled "$direct_order_b" >/dev/null
run_tg "$direct_order_home" continuation-handled "$direct_order_b" >/dev/null || fail "replayed first continuation route was not idempotent"
[ "$(grep -c "telegram:$direct_order_c" "$direct_order_home/state/.wake-queue")" -eq 1 ] || fail "acknowledged first continuation did not wake the second"
run_tg "$direct_order_home" request-handled "$direct_order_c" >/dev/null
run_tg "$direct_order_home" request-handled "$direct_order_c" >/dev/null || fail "replayed second continuation claim was not idempotent"
[ "$(run_tg "$direct_order_home" active-request --claimed-request "$direct_order_c")" = "$direct_order_a" ] || fail "second direct continuation route was not recoverable"
printf 'Firstmate · second continuation answered\n' > "$direct_order_home/continuation-reply.txt"
prepare_response "$direct_order_home" "$direct_order_c" wake-direct-order-c \
  "$direct_order_home/continuation-reply.txt"
reply_response "$direct_order_home" "$direct_order_a" wake-direct-order-c >"$direct_order_status"
[ "$(cat "$direct_order_status")" = 'Telegram reply sent.' ] || fail "second direct continuation reply rendered response content"
run_tg "$direct_order_home" continuation-handled "$direct_order_c" >/dev/null
run_tg "$direct_order_home" continuation-handled "$direct_order_c" >/dev/null || fail "replayed second continuation route was not idempotent"
if run_tg "$direct_order_home" active-request >/dev/null 2>&1; then
  fail "direct final retained the active conversation after all continuations"
fi
[ ! -e "$direct_order_home/state/telegram/closing.json" ] || fail "direct final retained closing state after all continuations"
reply_response "$direct_order_home" "$direct_order_a" wake-direct-order-final \
  >"$direct_order_replay_status" || fail "closed final replay failed"
[ "$(cat "$direct_order_replay_status")" = 'Telegram final reply already sent.' ] || fail "closed final replay rendered response content"
python3 - "$direct_order_home/calls.jsonl" "$direct_order_home/reply.txt" <<'PY' || fail "closed final replay duplicated Telegram delivery"
from pathlib import Path
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
expected = Path(sys.argv[2]).read_bytes()
replies = [call['params']['text'].encode() for call in calls if call['path'].endswith('/sendMessage')]
assert replies.count(expected) == 1
PY
set_updates '[{"update_id":43,"message":{"message_id":43,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"next independent request"}}]' "$direct_order_home"
run_tg "$direct_order_home" serve --once >/dev/null
direct_order_d=tg-text-u43-m43
run_tg "$direct_order_home" request-handled "$direct_order_d" >/dev/null || fail "next independent request could not claim after direct close"
[ "$(run_tg "$direct_order_home" active-request)" = "$direct_order_d" ] || fail "next independent request did not become active"

response_chunk_home=$(new_home response-chunks)
start_server "$response_chunk_home" "$response_chunk_home/port"
run_tg "$response_chunk_home" pair --user-id 77 --chat-id 77 >/dev/null
set_updates '[{"update_id":47,"message":{"message_id":47,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"chunk one canonical response"}}]' "$response_chunk_home"
run_tg "$response_chunk_home" serve --once >/dev/null
response_chunk_request=tg-text-u47-m47
run_tg "$response_chunk_home" request-handled "$response_chunk_request" >/dev/null
python3 - "$response_chunk_home/chunk-response.txt" <<'PY'
from pathlib import Path
import sys
label = 'Firstmate · '
label_units = len(label.encode('utf-16-le')) // 2
text = label + ('a' * (4096 - label_units)) + ('🙂' * 2048) + ('界' * 4096) + '\n'
Path(sys.argv[1]).write_text(text, encoding='utf-8')
PY
stage_response "$response_chunk_home" "$response_chunk_request" wake-response-chunks \
  "$response_chunk_home/chunk-response.txt" >/dev/null
render_response "$response_chunk_home" "$response_chunk_request" wake-response-chunks \
  >"$response_chunk_home/chunk-terminal.txt"
reply_response "$response_chunk_home" "$response_chunk_request" wake-response-chunks \
  >"$response_chunk_home/chunk-reply.out" || fail "bounded Unicode response chunks were not delivered"
[ "$(cat "$response_chunk_home/chunk-reply.out")" = 'Telegram reply sent.' ] || \
  fail "chunk delivery exposed response content"
cmp -s "$response_chunk_home/chunk-response.txt" "$response_chunk_home/chunk-terminal.txt" || \
  fail "chunked response changed terminal bytes"
python3 - "$response_chunk_home/calls.jsonl" "$response_chunk_home/chunk-response.txt" <<'PY' || fail "Telegram chunks did not preserve Unicode boundaries and canonical bytes"
from pathlib import Path
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
expected = Path(sys.argv[2]).read_bytes()
chunks = [call['params']['text'] for call in calls
          if call['path'].endswith('/sendMessage')
          and not call.get('params', {}).get('text', '').startswith('Bot · ')]
assert len(chunks) == 4
assert len(chunks[0].encode('utf-16-le')) // 2 == 4096
assert all(0 < len(chunk.encode('utf-16-le')) // 2 <= 4096 for chunk in chunks)
assert b''.join(chunk.encode('utf-8') for chunk in chunks) == expected
assert any('🙂' in chunk for chunk in chunks)
assert any('界' in chunk for chunk in chunks)
PY
set_updates '[{"update_id":48,"message":{"message_id":48,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"continuation behind chunked final"}}]' "$response_chunk_home"
run_tg "$response_chunk_home" serve --once >/dev/null
response_chunk_continuation=tg-text-u48-m48
python3 - "$response_chunk_home/chunk-final.txt" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text('Firstmate · ' + ('final chunk ' * 500) + '\n', encoding='utf-8')
PY
stage_response "$response_chunk_home" "$response_chunk_request" wake-response-chunk-final \
  "$response_chunk_home/chunk-final.txt" --final >/dev/null
render_response "$response_chunk_home" "$response_chunk_request" wake-response-chunk-final >/dev/null
printf '1\n' >"$response_chunk_home/disconnect-after-send-count"
response_chunk_final_status=0
reply_response "$response_chunk_home" "$response_chunk_request" wake-response-chunk-final \
  >"$response_chunk_home/chunk-final-first.out" || response_chunk_final_status=$?
[ "$response_chunk_final_status" -eq 3 ] || fail "unknown first chunk did not stop final release"
[ "$(cat "$response_chunk_home/chunk-final-first.out")" = \
  'Telegram reply delivery is incomplete; settled chunks were not resent.' ] || \
  fail "incomplete chunk delivery exposed response content"
[ ! -e "$response_chunk_home/state/telegram/closing.json" ] || \
  fail "final conversation began closing before every chunk settled"
[ "$(run_tg "$response_chunk_home" active-request)" = "$response_chunk_request" ] || \
  fail "incomplete chunk delivery released its active conversation"
response_chunk_final_status=0
reply_response "$response_chunk_home" "$response_chunk_request" wake-response-chunk-final \
  >"$response_chunk_home/chunk-final-replay.out" || response_chunk_final_status=$?
[ "$response_chunk_final_status" -eq 3 ] || fail "settled unknown final lost its uncertainty status"
[ "$(cat "$response_chunk_home/chunk-final-replay.out")" = \
  'Telegram final reply delivery unknown; continuation handling remains pending.' ] || \
  fail "settled unknown final did not enter continuation closing"
run_tg "$response_chunk_home" request-handled "$response_chunk_continuation" >/dev/null
[ "$(run_tg "$response_chunk_home" active-request --claimed-request "$response_chunk_continuation")" = \
  "$response_chunk_request" ] || fail "settled chunked final lost its direct continuation route"
printf 'Firstmate · continuation settled\n' >"$response_chunk_home/chunk-continuation.txt"
prepare_response "$response_chunk_home" "$response_chunk_continuation" \
  wake-response-chunk-continuation "$response_chunk_home/chunk-continuation.txt"
reply_response "$response_chunk_home" "$response_chunk_request" \
  wake-response-chunk-continuation >/dev/null
run_tg "$response_chunk_home" continuation-handled "$response_chunk_continuation" >/dev/null
if run_tg "$response_chunk_home" active-request >/dev/null 2>&1; then
  fail "settled chunked continuation retained its closed conversation"
fi

response_crash_home=$(new_home response-crash)
start_server "$response_crash_home" "$response_crash_home/port"
run_tg "$response_crash_home" pair --user-id 77 --chat-id 77 >/dev/null
set_updates '[{"update_id":44,"message":{"message_id":44,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"recover one response"}}]' "$response_crash_home"
run_tg "$response_crash_home" serve --once >/dev/null
response_crash_request=tg-text-u44-m44
run_tg "$response_crash_home" request-handled "$response_crash_request" >/dev/null
reserved_path=$(reserve_response "$response_crash_home" "$response_crash_request" \
  wake-response-crash)
[ ! -s "$reserved_path" ] || fail "pre-generation reservation was not empty"
[ "$(reserve_response "$response_crash_home" "$response_crash_request" wake-response-crash)" = "$reserved_path" ] || fail "reservation replay changed the response identity"
response_crash_status=$(run_tg "$response_crash_home" response-status \
  "$response_crash_request" wake-response-crash)
[ "$response_crash_status" = "$(printf '%s\treserved\tpending\tpending\tnon-final' "$reserved_path")" ] || fail "pre-generation reservation was not recoverable"
python3 - "$reserved_path" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text('Firstmate · ' + ('recoverable bytes ' * 700) + '\n', encoding='utf-8')
PY
[ "$(reserve_response "$response_crash_home" "$response_crash_request" wake-response-crash)" = "$reserved_path" ] || fail "generated reservation replay changed the response file"
response_crash_status=$(run_tg "$response_crash_home" response-status \
  "$response_crash_request" wake-response-crash)
[ "$response_crash_status" = "$(printf '%s\treserved\tpending\tpending\tnon-final' "$reserved_path")" ] || fail "generated but unstaged response lost its reservation"
staged_path=$(run_tg "$response_crash_home" response-stage "$response_crash_request" \
  wake-response-crash --text-file "$reserved_path")
response_crash_status=$(run_tg "$response_crash_home" response-status \
  "$response_crash_request" wake-response-crash)
[ "$response_crash_status" = "$(printf '%s\tstaged\tpending\tpending\tnon-final' "$staged_path")" ] || fail "staged response did not persist both pending boundaries"
[ "$staged_path" = "$reserved_path" ] || fail "response staging changed the reserved output path"
printf 'Firstmate · regenerated different bytes\n' >"$response_crash_home/regenerated.txt"
if run_tg "$response_crash_home" response-stage "$response_crash_request" \
    wake-response-crash --text-file "$response_crash_home/regenerated.txt" >/dev/null 2>&1; then
  fail "stable response identity accepted regenerated bytes"
fi
response_pending_send_count=$(cat "$response_crash_home/send-count")
if reply_response "$response_crash_home" "$response_crash_request" \
    wake-response-crash >"$response_crash_home/reply-before-render.out" 2>&1; then
  fail "reply accepted a response before terminal rendering"
fi
if run_tg "$response_crash_home" response-rendered "$response_crash_request" \
    wake-response-crash >/dev/null 2>&1; then
  fail "terminal acknowledgement succeeded before a render attempt"
fi
[ "$(cat "$response_crash_home/send-count")" = "$response_pending_send_count" ] || \
  fail "pending terminal render reached Telegram delivery"
python3 - "$SCRIPT" "$response_crash_home" "$response_crash_request" <<'PY' || fail "response render crash fixture failed"
import fcntl, os, subprocess, sys, time
script, home, request_id = sys.argv[1:]
read_fd, write_fd = os.pipe()
fcntl.fcntl(write_fd, fcntl.F_SETPIPE_SZ, 4096)
process = subprocess.Popen(
    [script, '--home', home, 'response-render', request_id, 'wake-response-crash'],
    stdout=write_fd,
    stderr=subprocess.DEVNULL,
)
os.close(write_fd)
for _ in range(200):
    status = subprocess.run(
        [script, '--home', home, 'response-status', request_id, 'wake-response-crash'],
        text=True, capture_output=True,
    )
    if '\trendering\t' in status.stdout:
        break
    time.sleep(.01)
else:
    process.kill()
    process.wait()
    os.close(read_fd)
    raise SystemExit(1)
process.kill()
process.wait()
os.close(read_fd)
PY
response_render_blocked_send_count=$(cat "$response_crash_home/send-count")
if reply_response "$response_crash_home" "$response_crash_request" \
    wake-response-crash >"$response_crash_home/reply-before-render-ack.out" 2>&1; then
  fail "reply accepted a render attempt without terminal acknowledgement"
fi
[ "$(cat "$response_crash_home/send-count")" = "$response_render_blocked_send_count" ] || \
  fail "unacknowledged render reached Telegram delivery"
python3 - "$SCRIPT" "$response_crash_home" "$response_crash_request" <<'PY' || fail "broken render pipe fixture failed"
import fcntl, os, subprocess, sys
script, home, request_id = sys.argv[1:]
read_fd, write_fd = os.pipe()
fcntl.fcntl(write_fd, fcntl.F_SETPIPE_SZ, 4096)
process = subprocess.Popen(
    [script, '--home', home, 'response-render', request_id, 'wake-response-crash'],
    stdout=write_fd,
    stderr=subprocess.DEVNULL,
)
os.close(write_fd)
prefix = os.read(read_fd, 32)
os.close(read_fd)
status = process.wait()
assert len(prefix) == 32
assert prefix.startswith(b'Firstmate \xc2\xb7 recoverable bytes ')
assert status != 0
PY
response_crash_status=$(run_tg "$response_crash_home" response-status \
  "$response_crash_request" wake-response-crash)
case $response_crash_status in
  *$'\tstaged\trendering\tpending\tnon-final') ;;
  *) fail "interrupted rendering did not retain unresolved render evidence" ;;
esac
run_tg "$response_crash_home" response-render "$response_crash_request" \
  wake-response-crash >"$response_crash_home/render-replay.txt"
cmp -s "$staged_path" "$response_crash_home/render-replay.txt" || \
  fail "render recovery did not replay the complete staged response"
if reply_response "$response_crash_home" "$response_crash_request" \
    wake-response-crash >"$response_crash_home/reply-before-explicit-ack.out" 2>&1; then
  fail "successful render attempt bypassed explicit acknowledgement"
fi
[ "$(cat "$response_crash_home/send-count")" = "$response_render_blocked_send_count" ] || \
  fail "rendered but unacknowledged response reached Telegram delivery"
run_tg "$response_crash_home" response-rendered "$response_crash_request" \
  wake-response-crash
response_crash_status=$(run_tg "$response_crash_home" response-status \
  "$response_crash_request" wake-response-crash)
case $response_crash_status in
  *$'\tstaged\trendered\tpending\tnon-final') ;;
  *) fail "explicit render acknowledgement was not durable" ;;
esac
render_response "$response_crash_home" "$response_crash_request" \
  wake-response-crash >"$response_crash_home/render-after-ack.txt"
[ ! -s "$response_crash_home/render-after-ack.txt" ] || \
  fail "acknowledged response rendered a second complete body"
printf '%s\n' "$(( $(cat "$response_crash_home/send-count") + 2 ))" \
  >"$response_crash_home/hold-send-at-count"
rm -f "$response_crash_home/send-entered"
env FM_HOME="$response_crash_home" "$SCRIPT" \
  --test-api-base "$(test_api_base "$response_crash_home")" reply \
  "$response_crash_request" --response-id wake-response-crash \
  >"$response_crash_home/reply-crash.out" 2>&1 &
response_reply_pid=$!
response_send_entered=0
for _ in $(seq 1 100); do
  if [ -e "$response_crash_home/send-entered" ]; then response_send_entered=1; break; fi
  sleep .02
done
[ "$response_send_entered" -eq 1 ] || fail "staged response did not reach its delivery-unknown boundary"
kill -9 "$response_reply_pid" 2>/dev/null || true
wait "$response_reply_pid" 2>/dev/null || true
rm -f "$response_crash_home/hold-send-at-count"
sleep .05
python3 - "$response_crash_home/state/telegram/responses/wake-response-crash.json" <<'PY' || fail "chunk crash did not preserve independent delivery evidence"
import json, sys
record = json.load(open(sys.argv[1], encoding='utf-8'))
statuses = [chunk['telegram_status'] for chunk in record['chunks']]
assert statuses[:2] == ['sent', 'delivery_unknown']
assert all(status == 'pending' for status in statuses[2:])
PY
response_reply_replay_status=0
reply_response "$response_crash_home" "$response_crash_request" \
  wake-response-crash >"$response_crash_home/reply-replay.out" || response_reply_replay_status=$?
[ "$response_reply_replay_status" -eq 3 ] || fail "delivery-unknown response replay did not retain uncertainty"
[ "$(cat "$response_crash_home/reply-replay.out")" = 'Telegram reply delivery unknown; settled chunks were not resent.' ] || fail "delivery-unknown replay exposed response content"
python3 - "$response_crash_home/calls.jsonl" "$staged_path" \
  "$response_crash_home/state/telegram/responses/wake-response-crash.json" <<'PY' || fail "chunk replay changed staged bytes or resent settled chunks"
from pathlib import Path
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
expected = Path(sys.argv[2]).read_bytes()
record = json.load(open(sys.argv[3], encoding='utf-8'))
replies = [call['params']['text'].encode() for call in calls
           if call['path'].endswith('/sendMessage')
           and not call.get('params', {}).get('text', '').startswith('Bot · ')]
assert b''.join(replies) == expected
assert len(replies) == len(record['chunks'])
assert [chunk['telegram_status'] for chunk in record['chunks']] == [
    'sent', 'delivery_unknown', 'sent', 'sent'
]
PY
response_crash_status=$(run_tg "$response_crash_home" response-status \
  "$response_crash_request" wake-response-crash)
case $response_crash_status in
  *$'\tstaged\trendered\tdelivery_unknown\tnon-final') ;;
  *) fail "delivery interruption did not preserve acknowledged terminal evidence" ;;
esac

response_oversize_send_count=$(grep -c 'sendMessage' "$response_crash_home/calls.jsonl")
response_oversize_crash_path=$(reserve_response "$response_crash_home" \
  "$response_crash_request" wake-response-oversized-crash)
python3 - "$response_oversize_crash_path" <<'PY'
from pathlib import Path
import sys
label = 'Firstmate · '.encode()
Path(sys.argv[1]).write_bytes(label + b'c' * (256 * 1024 + 1 - len(label)))
PY
oversize_crash_status=0
env FM_HOME="$response_crash_home" \
  FM_TELEGRAM_TEST_CRASH_AFTER_OVERSIZE_REFUSAL=1 \
  "$SCRIPT" --test-api-base "$(test_api_base "$response_crash_home")" \
  response-stage "$response_crash_request" wake-response-oversized-crash \
  --text-file "$response_oversize_crash_path" \
  >"$response_crash_home/oversized-crash.out" \
  2>"$response_crash_home/oversized-crash.err" || oversize_crash_status=$?
[ "$oversize_crash_status" -eq 99 ] || fail "oversized refusal crash boundary was not reached"
[ -s "$response_oversize_crash_path" ] || fail "crash fixture removed oversized bytes before refusal evidence"
response_oversize_crash_state=$(run_tg "$response_crash_home" response-status \
  "$response_crash_request" wake-response-oversized-crash)
[ "$response_oversize_crash_state" = \
  "$(printf '%s\toversized\tpending\tpending\tnon-final' "$response_oversize_crash_path")" ] || \
  fail "interrupted oversized refusal was not durably recoverable"
run_tg "$response_crash_home" serve --once >/dev/null
[ ! -s "$response_oversize_crash_path" ] || \
  fail "startup cleanup retained oversized response bytes after durable refusal"
[ "$(run_tg "$response_crash_home" response-status "$response_crash_request" \
  wake-response-oversized-crash)" = "$response_oversize_crash_state" ] || \
  fail "startup cleanup changed oversized refusal identity or evidence"
if run_tg "$response_crash_home" response-stage "$response_crash_request" \
    wake-response-oversized-crash --text-file "$response_oversize_crash_path" \
    >/dev/null 2>"$response_crash_home/oversized-crash-replay.err"; then
  fail "interrupted oversized refusal replay was staged"
fi
[ "$(cat "$response_crash_home/oversized-crash-replay.err")" = \
  'fm-telegram: Telegram response exceeds the 262144-byte staging limit' ] || \
  fail "interrupted oversized refusal changed its deterministic error"
[ ! -s "$response_oversize_crash_path" ] || \
  fail "interrupted oversized refusal replay did not bound stored bytes"
[ "$(reserve_response "$response_crash_home" "$response_crash_request" \
  wake-response-oversized-crash)" = "$response_oversize_crash_path" ] || \
  fail "interrupted oversized refusal lost its stable response identity"
response_oversize_path=$(reserve_response "$response_crash_home" "$response_crash_request" \
  wake-response-oversized)
python3 - "$response_oversize_path" <<'PY'
from pathlib import Path
import sys
label = 'Firstmate · '.encode()
Path(sys.argv[1]).write_bytes(label + b'x' * (256 * 1024 + 1 - len(label)))
PY
if run_tg "$response_crash_home" response-stage "$response_crash_request" \
    wake-response-oversized --text-file "$response_oversize_path" \
    >"$response_crash_home/oversized-stage.out" 2>"$response_crash_home/oversized-stage.err"; then
  fail "oversized response was staged"
fi
[ "$(cat "$response_crash_home/oversized-stage.err")" = \
  'fm-telegram: Telegram response exceeds the 262144-byte staging limit' ] || \
  fail "oversized response did not expose its deterministic local error"
if run_tg "$response_crash_home" response-stage "$response_crash_request" \
    wake-response-oversized --text-file "$response_oversize_path" \
    >/dev/null 2>"$response_crash_home/oversized-stage-replay.err"; then
  fail "oversized response replay was staged"
fi
cmp -s "$response_crash_home/oversized-stage.err" \
  "$response_crash_home/oversized-stage-replay.err" || \
  fail "oversized response replay changed its local error"
[ ! -s "$response_oversize_path" ] || fail "oversized response remained in the bounded journal"
response_oversize_status=$(run_tg "$response_crash_home" response-status \
  "$response_crash_request" wake-response-oversized)
[ "$response_oversize_status" = \
  "$(printf '%s\toversized\tpending\tpending\tnon-final' "$response_oversize_path")" ] || \
  fail "oversized response identity was not durably refused"
if render_response "$response_crash_home" "$response_crash_request" \
    wake-response-oversized >/dev/null 2>&1; then
  fail "oversized response rendered in the terminal"
fi
if reply_response "$response_crash_home" "$response_crash_request" \
    wake-response-oversized >/dev/null 2>&1; then
  fail "oversized response reached Telegram delivery"
fi
[ "$(grep -c 'sendMessage' "$response_crash_home/calls.jsonl")" -eq \
  "$response_oversize_send_count" ] || fail "oversized response contacted Telegram"

response_abandoned_path=$(reserve_response "$response_crash_home" \
  "$response_crash_request" wake-response-abandoned)
python3 - "$response_abandoned_path" <<'PY'
from pathlib import Path
import sys
label = 'Firstmate · '.encode()
Path(sys.argv[1]).write_bytes(label + b'a' * (256 * 1024 + 1 - len(label)))
PY
run_tg "$response_crash_home" serve --once >/dev/null
[ -s "$response_abandoned_path" ] || \
  fail "cleanup raced a recently generated unstaged response"
[ "$(run_tg "$response_crash_home" response-status "$response_crash_request" \
  wake-response-abandoned)" = \
  "$(printf '%s\treserved\tpending\tpending\tnon-final' "$response_abandoned_path")" ] || \
  fail "recent unstaged response lost its generation reservation"
python3 - "$response_crash_home/state/telegram/responses/wake-response-abandoned.json" \
  "$response_abandoned_path" <<'PY'
import json, os, sys
metadata_path, body_path = sys.argv[1:]
with open(metadata_path, encoding='utf-8') as stream:
    record = json.load(stream)
record['created_at'] = 1
with open(metadata_path, 'w', encoding='utf-8') as stream:
    json.dump(record, stream)
os.utime(body_path, (1, 1))
PY
run_tg "$response_crash_home" serve --once >/dev/null
[ ! -s "$response_abandoned_path" ] || \
  fail "startup cleanup retained an abandoned oversized reservation"
[ "$(run_tg "$response_crash_home" response-status "$response_crash_request" \
  wake-response-abandoned)" = \
  "$(printf '%s\toversized\tpending\tpending\tnon-final' "$response_abandoned_path")" ] || \
  fail "abandoned oversized reservation lacked durable refusal evidence"
if run_tg "$response_crash_home" response-stage "$response_crash_request" \
    wake-response-abandoned --text-file "$response_abandoned_path" \
    >/dev/null 2>"$response_crash_home/abandoned-stage.err"; then
  fail "abandoned oversized response was regenerated or staged"
fi
[ "$(cat "$response_crash_home/abandoned-stage.err")" = \
  'fm-telegram: Telegram response exceeds the 262144-byte staging limit' ] || \
  fail "abandoned oversized response changed its deterministic error"

response_capacity_home=$(new_home response-capacity)
start_server "$response_capacity_home" "$response_capacity_home/port"
run_tg "$response_capacity_home" pair --user-id 77 --chat-id 77 >/dev/null
mkdir -p "$response_capacity_home/state/telegram/handled" \
  "$response_capacity_home/state/telegram/responses"
printf '{"origin":"telegram","request_id":"closed-conversation"}\n' \
  >"$response_capacity_home/state/telegram/handled/closed-conversation.json"
chmod 600 "$response_capacity_home/state/telegram/handled/closed-conversation.json"
python3 - "$response_capacity_home/state/telegram/responses" <<'PY'
from pathlib import Path
import hashlib, json, sys

root = Path(sys.argv[1])
for index in range(256):
    response_id = f'capacity-{index:03d}'
    body = b'' if index == 254 else f'Firstmate · capacity {index}\n'.encode()
    status = 'reserved' if index == 254 else 'staged'
    telegram = 'delivery_unknown' if index == 255 else ('pending' if index == 254 else 'sent')
    terminal = 'pending' if index == 254 else 'rendered'
    record = {
        'response_id': response_id,
        'claimed_request_id': 'closed-conversation',
        'conversation_id': 'closed-conversation',
        'final': False,
        'content_status': status,
        'created_at': index + 1,
        'terminal_status': terminal,
        'telegram_status': telegram,
        'telegram_attempts': 1 if index == 255 else 0,
        'chunks': [],
    }
    if status == 'staged':
        record['body_sha256'] = hashlib.sha256(body).hexdigest()
        record['chunks'] = [{
            'index': 0,
            'start': 0,
            'end': len(body),
            'body_sha256': hashlib.sha256(body).hexdigest(),
            'telegram_status': telegram,
            'telegram_attempts': 1 if index == 255 else 0,
        }]
    (root / f'{response_id}.txt').write_bytes(body)
    (root / f'{response_id}.json').write_text(
        json.dumps(record, sort_keys=True, separators=(',', ':')) + '\n', encoding='utf-8')
    (root / f'{response_id}.txt').chmod(0o600)
    (root / f'{response_id}.json').chmod(0o600)
PY
set_updates '[{"update_id":46,"message":{"message_id":46,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"response after journal capacity"}}]' "$response_capacity_home"
run_tg "$response_capacity_home" serve --once >/dev/null
response_capacity_request=tg-text-u46-m46
run_tg "$response_capacity_home" request-handled "$response_capacity_request" >/dev/null
reserve_response "$response_capacity_home" "$response_capacity_request" capacity-new >/dev/null || \
  fail "a full response journal did not evict its oldest completed closed response"
[ ! -e "$response_capacity_home/state/telegram/responses/capacity-000.json" ] || \
  fail "response journal retained its oldest completed closed response"
[ -e "$response_capacity_home/state/telegram/responses/capacity-254.json" ] || \
  fail "response journal evicted a reserved response"
[ -e "$response_capacity_home/state/telegram/responses/capacity-255.json" ] || \
  fail "response journal evicted delivery-unknown evidence"
[ "$(find "$response_capacity_home/state/telegram/responses" -name '*.json' | wc -l | tr -d ' ')" -eq 256 ] || \
  fail "response journal did not remain bounded after capacity recovery"

# Unsafe configured commands are rejected before pairing contacts Telegram and without leaking private values.
command_config_home=$(new_home command-config)
start_server "$command_config_home" "$command_config_home/port"
unsafe_command="$command_config_home/not-an-executable"
command_config_err="$command_config_home/pair.err"
command_config_out="$command_config_home/pair.out"
if run_tg "$command_config_home" pair --user-id 77 --chat-id 77 \
    --parakeet-command relative-wrapper --whisper-command "$unsafe_command" \
    >"$command_config_out" 2>"$command_config_err"; then
  fail "pairing accepted an unsafe or missing transcriber command"
fi
! grep -F 'relative-wrapper' "$command_config_err" >/dev/null || fail "unsafe command path was exposed in pairing diagnostics"
! grep -F 'test-only-token' "$command_config_err" >/dev/null || fail "bot token was exposed in pairing diagnostics"
[ ! -e "$command_config_home/config/telegram.json" ] || fail "unsafe pairing wrote configuration"
if run_tg "$command_config_home" pair --user-id 77 --chat-id 77 \
    --parakeet-command "$unsafe_command" --whisper-command "$unsafe_command" \
    >"$command_config_out" 2>"$command_config_err"; then
  fail "pairing accepted a missing transcriber command"
fi
! grep -F "$unsafe_command" "$command_config_err" >/dev/null || fail "missing command path was exposed in pairing diagnostics"
! grep -F 'test-only-token' "$command_config_err" >/dev/null || fail "bot token was exposed in missing-command diagnostics"
[ ! -e "$command_config_home/config/telegram.json" ] || fail "missing-command pairing wrote configuration"
for command in old-parakeet old-whisper new-parakeet new-whisper; do
  printf '#!/bin/sh\nprintf "transcript\\n"\n' >"$command_config_home/$command"
  chmod +x "$command_config_home/$command"
done
run_tg "$command_config_home" pair --user-id 77 --chat-id 77 \
  --parakeet-command "$command_config_home/old-parakeet" \
  --whisper-command "$command_config_home/old-whisper" >/dev/null
rm -f "$command_config_home/old-parakeet" "$command_config_home/old-whisper"
run_tg "$command_config_home" pair --user-id 77 --chat-id 77 \
  --parakeet-command "$command_config_home/new-parakeet" \
  --whisper-command "$command_config_home/new-whisper" >/dev/null || \
  fail "pairing replacements could not repair missing configured commands"
touch "$command_config_home/block-getme"
rm -f "$command_config_home/getme-entered"
run_tg "$command_config_home" pair --user-id 77 --chat-id 77 \
  --parakeet-command "$command_config_home/new-parakeet" \
  --whisper-command "$command_config_home/new-whisper" >/dev/null &
command_repair_pid=$!
for _ in $(seq 1 100); do
  [ -e "$command_config_home/getme-entered" ] && break
  sleep .02
done
[ -e "$command_config_home/getme-entered" ] || fail "command repair race did not reach pairing validation"
python3 - "$command_config_home/config/telegram.json" "$command_config_home/stale-parakeet" "$command_config_home/stale-whisper" <<'PY'
import json, sys
path, parakeet, whisper = sys.argv[1:]
with open(path, encoding='utf-8') as stream:
    config = json.load(stream)
config['parakeet_command'] = parakeet
config['whisper_command'] = whisper
with open(path, 'w', encoding='utf-8') as stream:
    json.dump(config, stream)
PY
chmod 600 "$command_config_home/config/telegram.json"
rm -f "$command_config_home/block-getme"
wait "$command_repair_pid" || fail "pairing replacements did not repair commands changed during verification"
python3 - "$command_config_home/config/telegram.json" "$command_config_home/new-parakeet" "$command_config_home/new-whisper" <<'PY' || fail "paired command repair saved the wrong commands"
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    config = json.load(stream)
assert config['parakeet_command'] == sys.argv[2]
assert config['whisper_command'] == sys.argv[3]
PY

override_home=$(new_home command-override)
start_server "$override_home" "$override_home/port"
cat >"$override_home/override-transcriber" <<'SH'
#!/usr/bin/env bash
[ "$1" = --model ] && [ "$2" = test ] && [ -f "$3" ] || exit 1
printf 'environment override transcript\n'
SH
chmod +x "$override_home/override-transcriber"
run_tg "$override_home" pair --user-id 77 --chat-id 77 >/dev/null
set_updates '[{"update_id":45,"message":{"message_id":45,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-override","duration":2,"file_size":20}}}]' "$override_home"
env FM_TELEGRAM_PARAKEET_CMD="$override_home/override-transcriber --model test {audio}" \
  FM_HOME="$override_home" "$SCRIPT" --test-api-base "$(test_api_base "$override_home")" \
  serve --once >/dev/null
grep -F 'environment override transcript' "$override_home/calls.jsonl" >/dev/null || fail "absolute environment override lost arguments or its audio placeholder"

# A full voice queue leaves the next valid voice unconfirmed and pauses its batch.
overflow_home=$(new_home voice-overflow)
start_server "$overflow_home" "$overflow_home/port"
run_tg "$overflow_home" pair --user-id 77 --chat-id 77 >/dev/null
mkdir -p "$overflow_home/state/telegram"
chmod 700 "$overflow_home/state" "$overflow_home/state/telegram"
python3 - "$overflow_home/state/telegram/pending.json" \
  "$overflow_home/state/telegram/pending-voice-queue.json" <<'PY'
import json, sys, time
pending_path, queue_path = sys.argv[1:]
created_at = int(time.time())
pending = {
    'pending_id': 'voice-u3000-m3000',
    'mode': 'confirm',
    'audio_path': '/dev/shm/firstmate-telegram-overflow-fixture.oga',
    'chat_id': 77,
    'message_id': 3000,
    'update_id': 3000,
    'created_at': created_at,
    'revision': 1,
    'completed_actions': [],
    'text': 'active confirmation',
    'heading_sent': True,
    'transcript_sent': True,
}
records = [{
    'pending_id': f'voice-u{3100 + index}-m{3100 + index}',
    'file_id': f'queued-{index}',
    'duration': 2,
    'size': 20,
    'chat_id': 77,
    'message_id': 3100 + index,
    'update_id': 3100 + index,
    'queued_at': created_at,
} for index in range(64)]
for path, value in ((pending_path, pending), (queue_path, records)):
    with open(path, 'w', encoding='utf-8') as stream:
        json.dump(value, stream)
PY
chmod 600 "$overflow_home/state/telegram/pending.json" \
  "$overflow_home/state/telegram/pending-voice-queue.json"
set_updates '[{"update_id":4000,"message":{"message_id":4000,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-over-capacity","duration":2,"file_size":20}}},{"update_id":4001,"message":{"message_id":4001,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"must wait behind full voice queue"}}]' "$overflow_home"
run_tg "$overflow_home" serve --once >/dev/null
[ ! -e "$overflow_home/state/telegram/inbox/tg-text-u4001-m4001.json" ] || fail "full voice queue processed a later update from the blocked batch"
python3 - "$overflow_home/state/telegram/pending-voice-queue.json" \
  "$overflow_home/state/telegram/seen.json" <<'PY' || fail "full voice queue confirmed or discarded its blocked update"
import json, os, sys
records = json.load(open(sys.argv[1], encoding='utf-8'))
seen = json.load(open(sys.argv[2], encoding='utf-8')) if os.path.exists(sys.argv[2]) else {}
assert len(records) == 64
assert 'voice-u4000-m4000' not in [record['pending_id'] for record in records]
assert 4000 not in seen.get('updates', [])
PY
python3 - "$overflow_home/state/telegram/pending-voice-queue.json" <<'PY'
import json, sys
path = sys.argv[1]
records = json.load(open(path, encoding='utf-8'))
with open(path, 'w', encoding='utf-8') as stream:
    json.dump(records[:-1], stream)
PY
run_tg "$overflow_home" serve --once >/dev/null
[ -e "$overflow_home/state/telegram/inbox/tg-text-u4001-m4001.json" ] || fail "released voice capacity did not resume the paused update batch"
python3 - "$overflow_home/state/telegram/pending-voice-queue.json" <<'PY' || fail "blocked voice was not retried after capacity became available"
import json, sys
records = json.load(open(sys.argv[1], encoding='utf-8'))
assert len(records) == 64
assert records[-1]['pending_id'] == 'voice-u4000-m4000'
PY

# Voice confirm, edit, retry, cancel, expiry, and temporary-audio cleanup.
voice_home=$(new_home 'voice home % dollar$ quote"')
start_server "$voice_home" "$voice_home/port"
cat > "$voice_home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
printf 'parakeet transcript\n'
SH
cat > "$voice_home/whisper.sh" <<'SH'
#!/usr/bin/env bash
printf x >> "$0.calls"
touch "$0.entered"
while [ -e "$0.hold" ]; do sleep .01; done
printf 'whisper transcript\n'
SH
chmod +x "$voice_home/parakeet.sh" "$voice_home/whisper.sh"
run_tg "$voice_home" pair --user-id 77 --chat-id 77 \
  --parakeet-command "$voice_home/parakeet.sh" \
  --whisper-command "$voice_home/whisper.sh" >/dev/null
set_updates '[{"update_id":20,"message":{"message_id":20,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-1","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
pending="$voice_home/state/telegram/pending.json"
[ -f "$pending" ] || fail "voice note must create pending confirmation"
[ ! -e "$voice_home/audio-not-journaled-before-download" ] || fail "voice audio was downloaded before its cleanup journal was durable"
audio=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["audio_path"])' "$pending")
[ -f "$audio" ] || fail "voice audio must be retained for confirmation"
grep -F 'I heard this:' "$voice_home/calls.jsonl" >/dev/null || fail "voice confirmation heading missing"
grep -F 'Send to Firstmate' "$voice_home/calls.jsonl" >/dev/null || fail "voice controls missing"

pending_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_id"])' "$pending")
get_file_calls=$(grep -c 'getFile' "$voice_home/calls.jsonl")
confirmation_calls=$(grep -c 'I heard this:' "$voice_home/calls.jsonl")
set_updates '[{"update_id":2000,"message":{"message_id":2000,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-must-wait","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_id"])' "$pending")" = "$pending_id" ] || fail "a subsequent voice note replaced the active confirmation"
[ -f "$audio" ] || fail "a subsequent voice note deleted the active confirmation audio"
[ "$(grep -c 'getFile' "$voice_home/calls.jsonl")" -eq "$get_file_calls" ] || fail "a subsequent voice note was downloaded during an active confirmation"
[ "$(grep -c 'I heard this:' "$voice_home/calls.jsonl")" -eq "$confirmation_calls" ] || fail "a subsequent voice note created a concurrent confirmation"
voice_queue="$voice_home/state/telegram/pending-voice-queue.json"
python3 - "$voice_queue" <<'PY' || fail "a subsequent voice note was not durably serialized"
import json, sys
records = json.load(open(sys.argv[1], encoding='utf-8'))
assert [record['pending_id'] for record in records] == ['voice-u2000-m2000']
PY
[ "$(path_mode "$voice_queue")" = 600 ] || fail "pending voice queue was not private"

edit_data=$(callback_data "$voice_home" edit)
stale_send_data=$(callback_data "$voice_home" send)
malformed_callback_answers=$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")
set_updates '[{"update_id":2001,"callback_query":{"id":"cb-inline-conflict","from":{"id":77},"data":"'"$stale_send_data"'","message":{"message_id":2001,"chat":{"id":77,"type":"private"}},"inline_message_id":"conflict"}},{"update_id":2002,"callback_query":{"id":"cb-future-field","from":{"id":77},"data":"'"$stale_send_data"'","message":{"message_id":2002,"chat":{"id":77,"type":"private"}},"future_callback":{"opaque":true}}},{"update_id":2003,"callback_query":{"id":"cb-media-message","from":{"id":77},"data":"'"$stale_send_data"'","message":{"message_id":2003,"chat":{"id":77,"type":"private"},"photo":[{"file_id":"must not parse"}]}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$malformed_callback_answers" ] || fail "unsupported callback envelope was acknowledged"
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ] || fail "unsupported callback envelope queued a voice request"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mode"])' "$pending")" = confirm ] || fail "unsupported callback envelope changed pending voice state"
touch "$voice_home/hold-send"
rm -f "$voice_home/send-entered"
set_updates '[{"update_id":21,"callback_query":{"id":"cb-edit","from":{"id":77},"data":"'"$edit_data"'","message":{"message_id":201,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
env FM_HOME="$voice_home" "$SCRIPT" --test-api-base "$(test_api_base "$voice_home")" serve --once >/dev/null &
edit_pid=$!
edit_entered=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/send-entered" ]; then edit_entered=1; break; fi
  sleep .02
done
[ "$edit_entered" -eq 1 ] || fail "edit prompt did not reach its journaled delivery"
kill -9 "$edit_pid" 2>/dev/null || true
python3 - "$pending" <<'PY' || fail "edit prompt delivery was not journaled before send"
import json, sys
pending = json.load(open(sys.argv[1], encoding='utf-8'))
assert pending['edit_prompt_delivery'] == 'sending'
assert pending['edit_prompt_attempts'] == 1
PY
rm -f "$voice_home/hold-send"
wait "$edit_pid" 2>/dev/null || true
set_updates '[]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
prompt_count=$(grep -c 'Reply with the corrected text.' "$voice_home/calls.jsonl")
[ "$prompt_count" -eq 2 ] || fail "edit prompt delivery-unknown recovery was not bounded and deterministic"
python3 - "$pending" <<'PY' || fail "edit prompt recovery did not complete"
import json, sys
pending = json.load(open(sys.argv[1], encoding='utf-8'))
assert pending['edit_prompt_delivery'] == 'sent'
assert pending['edit_prompt_attempts'] == 2
PY
set_updates '[{"update_id":210,"callback_query":{"id":"cb-edit-second-tap","from":{"id":77},"data":"'"$edit_data"'","message":{"message_id":201,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(grep -c 'Reply with the corrected text.' "$voice_home/calls.jsonl")" -eq "$prompt_count" ] || fail "a second edit tap repeated the prompt"
stale_send_answers=$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")
set_updates '[{"update_id":211,"callback_query":{"id":"cb-stale-send","from":{"id":77},"data":"'"$stale_send_data"'","message":{"message_id":201,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ] || fail "stale Send control queued text while an edit was pending"
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$stale_send_answers" ] || fail "stale Send control was acknowledged while an edit was pending"
malformed_edit_sends=$(grep -c 'sendMessage' "$voice_home/calls.jsonl")
malformed_edit_inbox=$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')
set_updates '[{"update_id":212,"message":{"message_id":212,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"\ud800"}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mode"])' "$pending")" = edit ] || fail "malformed corrected text changed pending voice state"
[ "$(grep -c 'sendMessage' "$voice_home/calls.jsonl")" -eq "$malformed_edit_sends" ] || fail "malformed corrected text received a reply"
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq "$malformed_edit_inbox" ] || fail "malformed corrected text entered the request queue"
set_updates '[{"update_id":22,"message":{"message_id":22,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"corrected voice text"}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
grep -F 'corrected voice text' "$voice_home/calls.jsonl" >/dev/null || fail "edit must reconfirm corrected text"
edit_inbox_before=$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')
rm -f "$voice_home/state/telegram/seen.json"
run_tg "$voice_home" serve --once >/dev/null
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq "$edit_inbox_before" ] || fail "replayed edited text bypassed voice confirmation"

retry_data=$(callback_data "$voice_home" retry)
touch "$voice_home/whisper.sh.hold"
rm -f "$voice_home/whisper.sh.entered"
set_updates '[{"update_id":23,"callback_query":{"id":"cb-retry","from":{"id":77},"data":"'"$retry_data"'","message":{"message_id":202,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
env FM_HOME="$voice_home" "$SCRIPT" --test-api-base "$(test_api_base "$voice_home")" serve --once >/dev/null &
retry_pid=$!
retry_entered=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/whisper.sh.entered" ]; then retry_entered=1; break; fi
  sleep .02
done
[ "$retry_entered" -eq 1 ] || fail "Whisper retry did not start"
timeout 2 env FM_HOME="$voice_home" "$SCRIPT" --test-api-base "$(test_api_base "$voice_home")" active-request >/dev/null 2>&1
retry_lock_status=$?
[ "$retry_lock_status" -ne 124 ] || fail "Whisper retry held the Telegram state lock"
printf '1\n' > "$voice_home/disconnect-after-send-count"
rm -f "$voice_home/whisper.sh.hold"
wait "$retry_pid"
python3 - "$pending" <<'PY' || fail "retry confirmation delivery-unknown state was not journaled"
import json, sys
pending = json.load(open(sys.argv[1], encoding='utf-8'))
assert pending['heading_delivery'] == 'delivery_unknown'
assert pending['heading_attempts'] == 1
PY
set_updates '[]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
grep -F 'whisper transcript' "$voice_home/calls.jsonl" >/dev/null || fail "retry must use Whisper transcript"
[ "$(wc -c < "$voice_home/whisper.sh.calls" | tr -d ' ')" -eq 1 ] || fail "retry delivery recovery transcribed twice"
set_updates '[{"update_id":230,"callback_query":{"id":"cb-retry-second-tap","from":{"id":77},"data":"'"$retry_data"'","message":{"message_id":202,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(wc -c < "$voice_home/whisper.sh.calls" | tr -d ' ')" -eq 1 ] || fail "a second retry tap transcribed twice"
cancel_data=$(callback_data "$voice_home" cancel)
cancel_audio_dir=$(mktemp -d /dev/shm/firstmate-telegram-cancel-hold.XXXXXX)
cancel_audio="$cancel_audio_dir/firstmate-telegram-cancel-audio"
mv "$audio" "$cancel_audio"
python3 - "$pending" "$cancel_audio" <<'PY' || fail "cancel recovery setup failed"
import json, sys
path, audio = sys.argv[1:]
with open(path, encoding='utf-8') as stream:
    pending = json.load(stream)
pending['audio_path'] = audio
with open(path, 'w', encoding='utf-8') as stream:
    json.dump(pending, stream)
PY
chmod 500 "$cancel_audio_dir"
queued_get_file_before=$(grep -c 'getFile' "$voice_home/calls.jsonl")
queued_confirmation_before=$(grep -c 'I heard this:' "$voice_home/calls.jsonl")
set_updates '[{"update_id":24,"callback_query":{"id":"cb-cancel","from":{"id":77},"data":"'"$cancel_data"'","message":{"message_id":203,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
if run_tg "$voice_home" serve --once >/dev/null 2>&1; then
  fail "cancel unexpectedly completed while temporary audio deletion was blocked"
fi
python3 - "$pending" <<'PY' || fail "cancel was not journaled before destructive cleanup"
import json, sys
assert json.load(open(sys.argv[1], encoding='utf-8'))['mode'] == 'canceling'
PY
chmod 700 "$cancel_audio_dir"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$cancel_audio" ] || fail "recovered cancel must delete temporary audio"
python3 - "$pending" <<'PY' || fail "cancel did not advance the next serialized voice"
import json, sys
pending = json.load(open(sys.argv[1], encoding='utf-8'))
assert pending['pending_id'] == 'voice-u2000-m2000'
assert pending['mode'] == 'confirm'
PY
[ ! -e "$voice_queue" ] || fail "advanced voice remained duplicated in the pending queue"
queued_audio=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["audio_path"])' "$pending")
[ -f "$queued_audio" ] || fail "advanced voice did not retain its bounded confirmation audio"
[ "$(grep -c 'getFile' "$voice_home/calls.jsonl")" -eq "$((queued_get_file_before + 1))" ] || fail "serialized voice was not downloaded on advancement"
[ "$(grep -c 'I heard this:' "$voice_home/calls.jsonl")" -eq "$((queued_confirmation_before + 1))" ] || fail "serialized voice did not enter confirmation after cancellation"
queued_cancel_data=$(callback_data "$voice_home" cancel)
set_updates '[{"update_id":241,"callback_query":{"id":"cb-cancel-queued","from":{"id":77},"data":"'"$queued_cancel_data"'","message":{"message_id":241,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$pending" ] && [ ! -e "$queued_audio" ] || fail "serialized voice cancellation retained pending state"
rmdir "$cancel_audio_dir"
cancel_answers=$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")
set_updates '[{"update_id":240,"callback_query":{"id":"cb-cancel-completed","from":{"id":77},"data":"'"$cancel_data"'","message":{"message_id":203,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$((cancel_answers + 1))" ] || fail "durably completed callback was not recognized idempotently"
[ ! -e "$pending" ] && [ ! -e "$cancel_audio" ] || fail "completed cancel callback recreated pending voice state"

# Confirmed voice queues text, while an expired pending record deletes its audio.
set_updates '[{"update_id":25,"message":{"message_id":25,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-2","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
pending_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_id"])' "$pending")
send_audio=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["audio_path"])' "$pending")
send_data=$(callback_data "$voice_home" send)
touch "$voice_home/hold-send"
rm -f "$voice_home/send-entered"
set_updates '[{"update_id":26,"callback_query":{"id":"cb-send","from":{"id":77},"data":"'"$send_data"'","message":{"message_id":204,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
env FM_HOME="$voice_home" "$SCRIPT" --test-api-base "$(test_api_base "$voice_home")" serve --once >/dev/null &
send_pid=$!
send_entered=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/send-entered" ]; then send_entered=1; break; fi
  sleep .02
done
[ "$send_entered" -eq 1 ] || fail "voice Send did not reach its journaled reconciliation"
kill -9 "$send_pid" 2>/dev/null || true
rm -f "$voice_home/hold-send"
wait "$send_pid" 2>/dev/null || true
python3 - "$pending" <<'PY' || fail "interrupted voice send assertion failed"
import json, sys
assert json.load(open(sys.argv[1], encoding='utf-8'))['mode'] == 'sending'
PY
[ -e "$send_audio" ] || fail "interrupted Send lost audio before recovery completed"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$pending" ] || fail "recovered send must clear pending voice state"
[ ! -e "$send_audio" ] || fail "recovered send must delete temporary audio"
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "confirmed voice must queue exactly one request"
rm -f "$voice_home/state/telegram/seen.json"
run_tg "$voice_home" serve --once >/dev/null
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "replayed send callback duplicated the voice request"
set_updates '[{"update_id":27,"message":{"message_id":27,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-3","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
expired_audio=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["audio_path"])' "$pending")
expired_send_data=$(callback_data "$voice_home" send)
unknown_expired_data=$(python3 - "$expired_send_data" <<'PY'
import sys
parts = sys.argv[1].split(':')
parts[-1] = str(int(parts[-1]) + 1)
print(':'.join(parts))
PY
)
expired_callback_answers=$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")
touch "$voice_home/expire-pending-during-poll"
set_updates '[{"update_id":270,"callback_query":{"id":"cb-unknown-expired","from":{"id":77},"data":"'"$unknown_expired_data"'","message":{"message_id":270,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$expired_callback_answers" ] || fail "unknown expired callback received an acknowledgement"
[ -e "$expired_audio" ] && [ -e "$pending" ] || fail "unknown expired callback mutated pending voice state"
set_updates '[]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$expired_audio" ] || fail "expired pending voice must delete audio"
[ ! -e "$pending" ] || fail "expired pending voice must delete pending state"
set_updates '[{"update_id":271,"message":{"message_id":271,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-expired-callback","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
expired_action_audio=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["audio_path"])' "$pending")
expired_action_data=$(callback_data "$voice_home" send)
expired_action_answers=$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")
touch "$voice_home/expire-pending-during-poll"
set_updates '[{"update_id":272,"callback_query":{"id":"cb-recognized-expired","from":{"id":77},"data":"'"$expired_action_data"'","message":{"message_id":272,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$expired_action_audio" ] && [ ! -e "$pending" ] || fail "recognized expired callback retained pending voice state"
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$((expired_action_answers + 1))" ] || fail "recognized expired callback was not acknowledged"
set_updates '[{"update_id":273,"callback_query":{"id":"cb-recognized-expired-replay","from":{"id":77},"data":"'"$expired_action_data"'","message":{"message_id":273,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$((expired_action_answers + 2))" ] || fail "expired callback completion was not durable across replay"
cat > "$voice_home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
python3 -c 'print("x" * 4097)'
SH
chmod +x "$voice_home/parakeet.sh"
set_updates '[{"update_id":28,"message":{"message_id":28,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-long","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$pending" ] || fail "oversized transcript created unusable Telegram controls"
cat > "$voice_home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$0.audio"
printf '\377'
SH
chmod +x "$voice_home/parakeet.sh"
transcription_failures_before=$(grep -c "I couldn't transcribe that voice note." "$voice_home/calls.jsonl" || true)
set_updates '[{"update_id":29,"message":{"message_id":29,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-invalid-utf8","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
invalid_utf8_audio=$(cat "$voice_home/parakeet.sh.audio")
[ ! -e "$invalid_utf8_audio" ] || fail "invalid UTF-8 transcription retained temporary audio"
[ ! -e "$pending" ] || fail "invalid UTF-8 transcription retained pending voice state"
[ "$(grep -c "I couldn't transcribe that voice note." "$voice_home/calls.jsonl")" -eq "$((transcription_failures_before + 1))" ] || fail "invalid UTF-8 transcription did not report failure"

# Service lifecycle and cleanup are verified, scoped to this home, and leave .env intact.
cat >"$voice_home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
printf 'systemd absolute transcript\n'
SH
chmod +x "$voice_home/parakeet.sh"
set_updates '[]' "$voice_home"
unit_dir="$TMP_ROOT/units"; mkdir -p "$unit_dir"
systemctl_fake="$TMP_ROOT/systemctl"
touch "$voice_home/hold-updates"
cat > "$systemctl_fake" <<'SH'
#!/usr/bin/env bash
root=$(dirname "$0")
printf '%s\n' "$*" >> "$root/systemctl.calls"
shift
command=${1:-}; shift || true
active=$(cat "$root/systemctl.active" 2>/dev/null || printf inactive)
enabled=$(cat "$root/systemctl.enabled" 2>/dev/null || printf disabled)
stop_transport() {
  if [ -s "$root/systemctl.service.pid" ]; then
    pid=$(cat "$root/systemctl.service.pid")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
      [ ! -e "$FM_TELEGRAM_EXPECT_HOME/state/telegram/enabled" ] && break
      sleep .02
    done
    rm -f "$root/systemctl.service.pid"
  fi
  if [ -s "$root/systemctl.child-primary.pid" ]; then
    pid=$(cat "$root/systemctl.child-primary.pid")
    kill "$pid" 2>/dev/null || true
    rm -f "$root/systemctl.child-primary.pid" "$FM_TELEGRAM_EXPECT_HOME/state/.lock"
  fi
}
case "$command" in
  daemon-reload)
    unit="$FM_TELEGRAM_UNIT_DIR/firstmate-telegram.service"
    if [ -f "$unit" ]; then
      systemd-analyze --user verify "$unit" >/dev/null 2>&1 || exit 1
      python3 - "$unit" "$FM_TELEGRAM_EXPECT_HOME" <<'PY' || exit 1
import shlex, sys
from pathlib import Path
unit = Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
expected = sys.argv[2]
def value(name):
    matches = [line.split('=', 1)[1] for line in unit if line.startswith(name + '=')]
    assert len(matches) == 1
    return matches[0]
def words(raw):
    lexer = shlex.shlex(raw, posix=True)
    lexer.whitespace_split = True
    lexer.commenters = ''
    return [word.replace('%%', '%') for word in lexer]
environment = words(value('Environment'))
command = words(value('ExecStart'))
assert environment == ['FM_HOME=' + expected]
assert all('token' not in line.lower() for line in unit)
assert command[0] == ':/usr/bin/python3'
assert command[1].endswith('/bin/fm-telegram.py')
assert command[2:] == ['--home', expected, 'serve', '--systemd-service']
assert value('Restart') == 'on-failure'
assert words(value('RestartPreventExitStatus')) == ['78']
PY
    fi
    if [ -n "${FM_TELEGRAM_DAEMON_HOLD:-}" ]; then
      printf 'entered\n' > "$FM_TELEGRAM_DAEMON_HOLD.entered"
      while [ ! -e "$FM_TELEGRAM_DAEMON_HOLD.release" ]; do sleep .01; done
    fi
    ;;
  start)
    if [ -e "$root/systemctl.fail-start" ]; then
      printf inactive > "$root/systemctl.active"
      exit 1
    fi
    if [ -n "${FM_TELEGRAM_START_HOLD:-}" ]; then
      printf 'entered\n' > "$FM_TELEGRAM_START_HOLD.entered"
      while [ ! -e "$FM_TELEGRAM_START_HOLD.release" ]; do sleep .01; done
    fi
    if [ -e "$root/systemctl.hold-child-getme" ] || [ -e "$root/systemctl.partial-fail-start" ]; then
      rm -f "$root/systemctl.hold-child-getme"
      rm -f "$FM_TELEGRAM_EXPECT_HOME/getme-entered"
      touch "$FM_TELEGRAM_EXPECT_HOME/block-getme"
    fi
    if [ -e "$root/systemctl.child-watcher-fail" ]; then
      rm -f "$root/systemctl.child-watcher-fail"
      bash -c 'exec -a pi sleep 30' &
      printf '%s\n' "$!" > "$root/systemctl.child-primary.pid"
      printf '%s\n' "$!" > "$FM_TELEGRAM_EXPECT_HOME/state/.lock"
    fi
    if [ ! -s "$root/systemctl.service.pid" ]; then
      PATH=/usr/bin:/bin env FM_HOME="$FM_TELEGRAM_EXPECT_HOME" \
        "$FM_TELEGRAM_SERVICE_SCRIPT" --test-api-base "$FM_TELEGRAM_TEST_API_BASE" --home "$FM_TELEGRAM_EXPECT_HOME" serve --systemd-service --poll-timeout 1 \
        >"$root/systemctl.service.log" 2>&1 &
      printf '%s\n' "$!" > "$root/systemctl.service.pid"
    fi
    if [ -e "$root/systemctl.partial-fail-start" ]; then
      rm -f "$root/systemctl.partial-fail-start"
      for _ in $(seq 1 100); do
        [ -e "$FM_TELEGRAM_EXPECT_HOME/getme-entered" ] && break
        sleep .02
      done
      [ -e "$FM_TELEGRAM_EXPECT_HOME/getme-entered" ] || exit 1
      exit 1
    fi
    for _ in $(seq 1 100); do
      [ -e "$FM_TELEGRAM_EXPECT_HOME/state/telegram/enabled" ] && break
      sleep .02
    done
    [ -e "$FM_TELEGRAM_EXPECT_HOME/state/telegram/enabled" ] || exit 1
    printf active > "$root/systemctl.active"
    ;;
  stop)
    stop_transport
    printf inactive > "$root/systemctl.active"
    ;;
  enable) printf enabled > "$root/systemctl.enabled" ;;
  disable)
    [ ! -e "$root/systemctl.fail-disable" ] || exit 1
    printf disabled > "$root/systemctl.enabled"
    case " $* " in
      *' --now '*) stop_transport; printf inactive > "$root/systemctl.active" ;;
    esac
    ;;
  is-active)
    if [ -e "$root/systemctl.race-pair" ]; then
      count=$(cat "$root/systemctl.race-pair-count" 2>/dev/null || printf 0)
      count=$((count + 1))
      printf '%s\n' "$count" > "$root/systemctl.race-pair-count"
      if [ "$count" -eq 1 ]; then
        rm -f "$root/systemctl.race-pair"
        (
          PATH=/usr/bin:/bin env FM_HOME="$FM_TELEGRAM_EXPECT_HOME" \
            "$FM_TELEGRAM_SERVICE_SCRIPT" --test-api-base "$FM_TELEGRAM_TEST_API_BASE" --home "$FM_TELEGRAM_EXPECT_HOME" serve --once --systemd-service \
            >"$root/systemctl.race-service.log" 2>&1
          printf '%s\n' "$?" > "$root/systemctl.race-service.status"
        ) </dev/null >/dev/null 2>&1 &
        for _ in $(seq 1 100); do
          [ -e "$FM_TELEGRAM_EXPECT_HOME/state/telegram/enabled" ] && break
          sleep .01
        done
      fi
    fi
    [ "$active" = active ] && { printf 'active\n'; exit 0; }
    printf 'inactive\n'; exit 3
    ;;
  is-enabled)
    [ "$enabled" = enabled ] && { printf 'enabled\n'; exit 0; }
    printf 'disabled\n'; exit 1
    ;;
esac
exit 0
SH
chmod +x "$systemctl_fake"
lifecycle_env=(env FM_HOME="$voice_home" FM_TELEGRAM_TEST_API_BASE="$(test_api_base "$voice_home")" FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" FM_TELEGRAM_EXPECT_HOME="$voice_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT")
supervision_needs() {
  bash -c '. "$1"; fm_supervision_needed "$2"' _ "$ROOT/bin/fm-supervision-lib.sh" "$1/state"
}
bash -c 'exec -a pi sleep 30' &
install_primary_pid=$!
sleep .05
printf '%s\n' "$install_primary_pid" > "$voice_home/state/.lock"
if "${lifecycle_env[@]}" "$SCRIPT" install >/dev/null 2>&1; then
  fail "install activated beside an idle primary without healthy supervision"
fi
[ -e "$voice_home/state/telegram/enabled" ] || fail "install precondition discarded the durable Telegram supervision need"
[ "$(cat "$TMP_ROOT/systemctl.enabled")" = disabled ] || fail "install precondition retained a partially enabled service"
rm -f "$voice_home/state/.lock"
kill "$install_primary_pid" 2>/dev/null || true
wait "$install_primary_pid" 2>/dev/null || true
touch "$TMP_ROOT/systemctl.fail-start"
if "${lifecycle_env[@]}" "$SCRIPT" install >/dev/null 2>&1; then
  fail "install accepted a failed service start"
fi
[ ! -e "$voice_home/state/telegram/enabled" ] || fail "failed install retained Telegram supervision"
[ "$(cat "$TMP_ROOT/systemctl.enabled")" = disabled ] || fail "failed install retained a partially enabled service"
rm -f "$TMP_ROOT/systemctl.fail-start"
"${lifecycle_env[@]}" "$SCRIPT" install >/dev/null
[ -f "$unit_dir/firstmate-telegram.service" ] || fail "install must write one user unit"
supervision_needs "$voice_home" || fail "installed Telegram transport did not keep supervision armed"
set_updates '[{"update_id":296,"message":{"message_id":296,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-systemd-path","duration":2,"file_size":20}}}]' "$voice_home"
systemd_voice_confirmed=0
for _ in $(seq 1 200); do
  if grep -F 'systemd absolute transcript' "$voice_home/calls.jsonl" >/dev/null; then
    systemd_voice_confirmed=1
    break
  fi
  sleep .02
done
[ "$systemd_voice_confirmed" -eq 1 ] || fail "systemd PATH excluded the configured absolute transcriber"
set_updates '[]' "$voice_home"
"${lifecycle_env[@]}" "$SCRIPT" status >/dev/null || fail "status must report installed active service"
install_start_calls=$(grep -c -- '--user start firstmate-telegram.service' "$TMP_ROOT/systemctl.calls" || true)
"${lifecycle_env[@]}" "$SCRIPT" install >/dev/null || fail "repeat install rejected the exact active owned service"
[ "$(grep -c -- '--user start firstmate-telegram.service' "$TMP_ROOT/systemctl.calls" || true)" -eq "$install_start_calls" ] || fail "repeat install restarted the exact active owned service"
singleton_other_home=$(new_home singleton-other-home)
singleton_api="http://127.0.0.1:$(cat "$voice_home/port")"
printf 'FM_TELEGRAM_BOT_TOKEN=replacement-token\n' > "$singleton_other_home/.env"
env FM_HOME="$singleton_other_home" \
  "$SCRIPT" --test-api-base "$singleton_api" pair --user-id 77 --chat-id 77 >/dev/null
singleton_polls_before=$(grep -c '/botreplacement-token/getUpdates' "$voice_home/calls.jsonl" || true)
if env FM_HOME="$singleton_other_home" \
  FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" \
  FM_TELEGRAM_EXPECT_HOME="$voice_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT" \
  "$SCRIPT" --test-api-base "$singleton_api" serve --once >/dev/null 2>&1; then
  fail "another home entered beside the installed singleton service"
fi
if env FM_HOME="$singleton_other_home" \
  FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" \
  FM_TELEGRAM_EXPECT_HOME="$voice_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT" \
  "$SCRIPT" --test-api-base "$singleton_api" serve --once --systemd-service >/dev/null 2>&1; then
  fail "hidden systemd entry accepted a home that does not own the singleton unit"
fi
[ "$(grep -c '/botreplacement-token/getUpdates' "$voice_home/calls.jsonl" || true)" -eq "$singleton_polls_before" ] || fail "refused singleton home polled Telegram"
[ ! -e "$singleton_other_home/state/telegram/enabled" ] || fail "refused singleton home published supervision state"
cp "$voice_home/config/telegram.json" "$voice_home/pairing-before-active-repair.json"
if "${lifecycle_env[@]}" "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing changed while the owned Telegram service was active"
fi
cmp -s "$voice_home/config/telegram.json" "$voice_home/pairing-before-active-repair.json" || fail "active pairing attempt changed the pinned identity"
[ "$(cat "$TMP_ROOT/systemctl.active")" = active ] || fail "active pairing attempt stopped the service"
service_pid=$(cat "$TMP_ROOT/systemctl.service.pid")
kill -9 "$service_pid" 2>/dev/null || true
wait "$service_pid" 2>/dev/null || true
rm -f "$TMP_ROOT/systemctl.service.pid"
printf inactive > "$TMP_ROOT/systemctl.active"
if "${lifecycle_env[@]}" "$SCRIPT" serve --once --poll-timeout 0 >/dev/null 2>&1; then
  fail "direct runtime entered an enabled systemd restart gap"
fi
supervision_needs "$voice_home" || fail "systemd restart gap lost Telegram supervision"
"${lifecycle_env[@]}" "$SCRIPT" start >/dev/null || fail "systemd runtime did not recover after its restart gap"
stop_audio=$(mktemp /dev/shm/firstmate-telegram-stop.XXXXXX)
python3 - "$voice_home/state/telegram/pending.json" "$stop_audio" <<'PY'
import json, sys, time
json.dump({'audio_path': sys.argv[2], 'created_at': int(time.time()), 'mode': 'parked'}, open(sys.argv[1], 'w'))
PY
"${lifecycle_env[@]}" "$SCRIPT" stop >/dev/null
[ ! -e "$stop_audio" ] || fail "stop retained pending temporary audio"
[ ! -e "$voice_home/state/telegram/pending.json" ] || fail "stop retained pending voice state"
if supervision_needs "$voice_home"; then fail "stopped Telegram transport still required supervision"; fi
if "${lifecycle_env[@]}" "$SCRIPT" status >/dev/null; then fail "stop did not verify inactive state"; fi
bash -c 'exec -a pi sleep 30' &
start_primary_pid=$!
sleep .05
printf '%s\n' "$start_primary_pid" > "$voice_home/state/.lock"
if "${lifecycle_env[@]}" "$SCRIPT" start >/dev/null 2>&1; then
  fail "start activated beside an idle primary without healthy supervision"
fi
[ -e "$voice_home/state/telegram/enabled" ] || fail "start precondition discarded the durable Telegram supervision need"
[ "$(cat "$TMP_ROOT/systemctl.active")" = inactive ] || fail "start precondition changed service state"
rm -f "$voice_home/state/.lock"
kill "$start_primary_pid" 2>/dev/null || true
wait "$start_primary_pid" 2>/dev/null || true
touch "$TMP_ROOT/systemctl.fail-start"
if "${lifecycle_env[@]}" "$SCRIPT" start >/dev/null 2>&1; then
  fail "start accepted a failed service activation"
fi
[ ! -e "$voice_home/state/telegram/enabled" ] || fail "failed start retained Telegram supervision"
[ "$(cat "$TMP_ROOT/systemctl.enabled")" = enabled ] || fail "failed start disabled the installed service"
rm -f "$TMP_ROOT/systemctl.fail-start"
touch "$TMP_ROOT/systemctl.child-watcher-fail"
if "${lifecycle_env[@]}" "$SCRIPT" start >/dev/null 2>&1; then
  fail "start ignored a watcher precondition lost in the systemd child"
fi
[ -e "$voice_home/state/telegram/enabled" ] || fail "child watcher failure discarded the durable Telegram supervision need"
[ "$(cat "$TMP_ROOT/systemctl.active")" = inactive ] || fail "child watcher failure left the service active"
[ ! -e "$voice_home/state/.lock" ] || fail "child watcher failure retained its fake primary"
set_updates '[]' "$voice_home"
touch "$TMP_ROOT/systemctl.partial-fail-start"
if "${lifecycle_env[@]}" "$SCRIPT" start >/dev/null 2>&1; then
  fail "partial systemd activation failure was accepted"
fi
rm -f "$voice_home/block-getme"
[ ! -e "$voice_home/state/.telegram-service-activation" ] || fail "failed activation retained its reservation after the child stopped"
[ ! -e "$voice_home/state/telegram/enabled" ] || fail "failed activation retained Telegram supervision"
[ ! -e "$TMP_ROOT/systemctl.service.pid" ] || fail "failed activation left its systemd child running"
if "${lifecycle_env[@]}" "$SCRIPT" serve --once --poll-timeout 0 >/dev/null 2>&1; then
  fail "direct runtime entered while the installed systemd service remained enabled"
fi
rm -f "$voice_home/getme-entered"
touch "$TMP_ROOT/systemctl.hold-child-getme"
"${lifecycle_env[@]}" "$SCRIPT" start >/dev/null &
reserved_start_pid=$!
child_verifying=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/getme-entered" ]; then child_verifying=1; break; fi
  sleep .02
done
[ "$child_verifying" -eq 1 ] || fail "systemd child did not reach token verification"
[ -e "$voice_home/state/.telegram-service-activation" ] || fail "systemd child released its reservation before verification"
"${lifecycle_env[@]}" "$SCRIPT" serve --once --poll-timeout 0 >/dev/null 2>&1 &
racing_direct_pid=$!
sleep .1
kill -0 "$racing_direct_pid" 2>/dev/null || fail "direct runtime was not excluded during systemd verification"
kill -0 "$reserved_start_pid" 2>/dev/null || fail "activation parent did not wait for child readiness"
rm -f "$voice_home/block-getme"
wait "$reserved_start_pid" || fail "reserved systemd activation failed"
if wait "$racing_direct_pid"; then
  fail "waiting direct runtime entered after systemd readiness"
fi
service_pid=$(cat "$TMP_ROOT/systemctl.service.pid")
kill -0 "$service_pid" 2>/dev/null || fail "reserved activation did not leave the systemd runtime owning service"
[ ! -e "$voice_home/state/.telegram-service-activation" ] || fail "ready systemd runtime did not consume its activation reservation"
"${lifecycle_env[@]}" "$SCRIPT" stop >/dev/null || fail "reserved systemd runtime did not stop cleanly"
cp "$voice_home/config/telegram.json" "$voice_home/pairing-before-identity-change.json"
if "${lifecycle_env[@]}" "$SCRIPT" pair --user-id 88 --chat-id 88 >/dev/null 2>&1; then
  fail "pairing replaced the pinned user while old identity-bound state remained"
fi
cmp -s "$voice_home/config/telegram.json" "$voice_home/pairing-before-identity-change.json" || fail "refused identity replacement changed the pairing"
set_updates '[]' "$voice_home"
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null
"${lifecycle_env[@]}" "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null
"${lifecycle_env[@]}" "$SCRIPT" install >/dev/null
"${lifecycle_env[@]}" "$SCRIPT" stop >/dev/null
race_inbox_before=$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')
set_updates '[{"update_id":290,"message":{"message_id":290,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"old pairing must not survive replacement"}}]' "$voice_home"
rm -f "$TMP_ROOT/systemctl.race-pair-count" "$TMP_ROOT/systemctl.race-service.status"
touch "$TMP_ROOT/systemctl.race-pair"
"${lifecycle_env[@]}" "$SCRIPT" pair --user-id 88 --chat-id 88 >/dev/null || fail "serialized inactive pairing replacement failed"
race_service_done=0
for _ in $(seq 1 200); do
  if [ -s "$TMP_ROOT/systemctl.race-service.status" ]; then race_service_done=1; break; fi
  sleep .01
done
[ "$race_service_done" -eq 1 ] || fail "service racing pairing replacement did not finish"
[ "$(cat "$TMP_ROOT/systemctl.race-service.status")" -eq 0 ] || fail "service racing pairing replacement failed"
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq "$race_inbox_before" ] || fail "racing startup accepted the replaced pairing"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_id"])' "$voice_home/config/telegram.json")" -eq 88 ] || fail "serialized replacement did not persist the new pairing"
set_updates '[]' "$voice_home"
"${lifecycle_env[@]}" "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null || fail "state-free inactive service refused explicit re-pairing"
"${lifecycle_env[@]}" "$systemctl_fake" --user start firstmate-telegram.service
supervision_needs "$voice_home" || fail "direct enabled-service restart did not restore supervision"
direct_stop_audio=$(mktemp /dev/shm/firstmate-telegram-direct-stop.XXXXXX)
python3 - "$voice_home/state/telegram/pending.json" "$direct_stop_audio" <<'PY'
import json, sys, time
json.dump({'audio_path': sys.argv[2], 'created_at': int(time.time()), 'mode': 'parked'}, open(sys.argv[1], 'w'))
PY
"${lifecycle_env[@]}" "$systemctl_fake" --user stop firstmate-telegram.service
[ ! -e "$direct_stop_audio" ] || fail "graceful direct service stop retained temporary audio"
[ ! -e "$voice_home/state/telegram/pending.json" ] || fail "graceful direct service stop retained pending voice state"
if supervision_needs "$voice_home"; then fail "direct service stop did not release supervision"; fi
"${lifecycle_env[@]}" "$SCRIPT" disable >/dev/null
set_updates '[]' "$voice_home"
touch "$voice_home/block-updates"
rm -f "$voice_home/updates-entered"
"${lifecycle_env[@]}" "$SCRIPT" serve --poll-timeout 1 >"$voice_home/direct-lifecycle-service.out" 2>&1 &
direct_lifecycle_pid=$!
direct_lifecycle_started=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/updates-entered" ] && supervision_needs "$voice_home"; then direct_lifecycle_started=1; break; fi
  sleep .02
done
[ "$direct_lifecycle_started" -eq 1 ] || fail "direct lifecycle runtime did not acquire service ownership"
if "${lifecycle_env[@]}" "$SCRIPT" start >/dev/null 2>&1; then
  fail "start activated a second service runtime"
fi
if "${lifecycle_env[@]}" "$SCRIPT" install >/dev/null 2>&1; then
  fail "install activated a second service runtime"
fi
kill -0 "$direct_lifecycle_pid" 2>/dev/null || fail "refused activation terminated the direct runtime"
[ "$(cat "$TMP_ROOT/systemctl.active")" = inactive ] || fail "refused activation changed systemd service state"
supervision_needs "$voice_home" || fail "refused activation cleared direct runtime supervision"
if "${lifecycle_env[@]}" "$SCRIPT" stop >/dev/null 2>&1; then
  fail "stop cleared state while a direct runtime owned the service lock"
fi
kill -0 "$direct_lifecycle_pid" 2>/dev/null || fail "refused stop terminated the direct runtime"
supervision_needs "$voice_home" || fail "refused stop cleared direct runtime supervision"
if "${lifecycle_env[@]}" "$SCRIPT" disable >/dev/null 2>&1; then
  fail "disable cleared state while a direct runtime owned the service lock"
fi
kill -0 "$direct_lifecycle_pid" 2>/dev/null || fail "refused disable terminated the direct runtime"
supervision_needs "$voice_home" || fail "refused disable cleared direct runtime supervision"
kill "$direct_lifecycle_pid" 2>/dev/null || true
rm -f "$voice_home/block-updates"
wait "$direct_lifecycle_pid" 2>/dev/null || true
"${lifecycle_env[@]}" "$SCRIPT" install >/dev/null
supervision_needs "$voice_home" || fail "reinstalled Telegram transport did not restore supervision"
printf 'serialize stop\n' > "$voice_home/lifecycle-send.txt"
touch "$voice_home/hold-send"
rm -f "$voice_home/send-entered"
"${lifecycle_env[@]}" "$SCRIPT" send --text-file "$voice_home/lifecycle-send.txt" >/dev/null &
lifecycle_send_pid=$!
for _ in $(seq 1 100); do [ -e "$voice_home/send-entered" ] && break; sleep .02; done
[ -e "$voice_home/send-entered" ] || fail "lifecycle serialization send did not reach the fake server"
"${lifecycle_env[@]}" "$SCRIPT" stop >/dev/null &
serialized_stop_pid=$!
sleep .1
kill -0 "$serialized_stop_pid" 2>/dev/null || fail "stop did not wait for the lifecycle boundary"
[ "$(cat "$TMP_ROOT/systemctl.active")" = active ] || fail "stop mutated service state during an outbound transaction"
rm -f "$voice_home/hold-send"
wait "$lifecycle_send_pid" || fail "outbound transaction failed while stop waited"
wait "$serialized_stop_pid" || fail "serialized stop failed"
"${lifecycle_env[@]}" "$SCRIPT" start >/dev/null
supervision_needs "$voice_home" || fail "service did not restart after serialized stop"
disable_audio=$(mktemp /dev/shm/firstmate-telegram-disable.XXXXXX)
python3 - "$voice_home/state/telegram/pending.json" "$disable_audio" <<'PY'
import json, sys, time
json.dump({'audio_path': sys.argv[2], 'created_at': int(time.time()), 'mode': 'parked'}, open(sys.argv[1], 'w'))
PY
touch "$voice_home/hold-send"
rm -f "$voice_home/send-entered"
"${lifecycle_env[@]}" "$SCRIPT" send --text-file "$voice_home/lifecycle-send.txt" >/dev/null &
disable_send_pid=$!
for _ in $(seq 1 100); do [ -e "$voice_home/send-entered" ] && break; sleep .02; done
[ -e "$voice_home/send-entered" ] || fail "disable serialization send did not reach the fake server"
"${lifecycle_env[@]}" "$SCRIPT" disable >/dev/null &
serialized_disable_pid=$!
sleep .1
kill -0 "$serialized_disable_pid" 2>/dev/null || fail "disable did not wait for the lifecycle boundary"
[ "$(cat "$TMP_ROOT/systemctl.active")" = active ] || fail "disable mutated service state during an outbound transaction"
rm -f "$voice_home/hold-send"
wait "$disable_send_pid" || fail "outbound transaction failed while disable waited"
wait "$serialized_disable_pid" || fail "serialized disable failed"
[ ! -e "$disable_audio" ] || fail "disable retained pending temporary audio"
[ ! -e "$voice_home/state/telegram/pending.json" ] || fail "disable retained pending voice state"
if supervision_needs "$voice_home"; then fail "disabled Telegram transport still required supervision"; fi
[ "$(cat "$TMP_ROOT/systemctl.active")" = inactive ] || fail "disable did not verify service stopped"
[ "$(cat "$TMP_ROOT/systemctl.enabled")" = disabled ] || fail "disable did not verify service disabled"
"${lifecycle_env[@]}" "$SCRIPT" install >/dev/null
other_home=$(new_home other-cleanup)
if supervision_needs "$other_home"; then fail "Telegram supervision marker leaked into another home"; fi
before_systemctl=$(wc -l < "$TMP_ROOT/systemctl.calls")
if env FM_HOME="$other_home" FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" "$SCRIPT" cleanup >/dev/null 2>&1; then
  fail "cleanup for another home accepted the installed singleton unit"
fi
tail -n +$((before_systemctl + 1)) "$TMP_ROOT/systemctl.calls" | grep -Ev -- '^--user is-(active|enabled) firstmate-telegram\.service$' > "$TMP_ROOT/wrong-home.mutations" || true
[ ! -s "$TMP_ROOT/wrong-home.mutations" ] || fail "wrong-home cleanup mutated the singleton service"
unit="$unit_dir/firstmate-telegram.service"
mv "$unit" "$unit.saved"
ln -s "$unit.missing" "$unit"
if "${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null 2>&1; then fail "cleanup accepted an active service with unverified ownership"; fi
[ "$(cat "$TMP_ROOT/systemctl.active")" = active ] || fail "unverified cleanup changed the active service"
[ -e "$voice_home/state/telegram" ] || fail "unverified cleanup removed private state"
rm "$unit"
mv "$unit.saved" "$unit"
touch "$TMP_ROOT/systemctl.fail-disable"
if "${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null 2>&1; then fail "cleanup ignored systemctl failure"; fi
[ -e "$voice_home/state/telegram" ] || fail "failed cleanup removed private state while service could be live"
[ -e "$unit_dir/firstmate-telegram.service" ] || fail "failed cleanup removed the installed unit"
rm -f "$TMP_ROOT/systemctl.fail-disable"
"${lifecycle_env[@]}" "$SCRIPT" stop >/dev/null
cleanup_audio=$(mktemp /dev/shm/firstmate-telegram-cleanup.XXXXXX)
python3 - "$voice_home/state/telegram/pending.json" "$cleanup_audio" <<'PY'
import json, sys, time
json.dump({'audio_path': sys.argv[2], 'created_at': int(time.time())}, open(sys.argv[1], 'w'))
PY
FM_HOME="$voice_home" FM_STATE_OVERRIDE="$voice_home/state" bash -c '. "$1"; fm_wake_append check unrelated:keep "unrelated keep"' _ "$ROOT/bin/fm-wake-lib.sh"
state_lock_ready="$voice_home/state-lock-ready"
state_lock_release="$voice_home/state-lock-release"
"$PYTHON" - "$voice_home/state/.telegram-state.lock" "$state_lock_ready" "$state_lock_release" <<'PY' &
import fcntl, os, sys, time
lock_path, ready_path, release_path = sys.argv[1:]
with open(lock_path, 'a+', encoding='utf-8') as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    with open(ready_path, 'w', encoding='utf-8') as ready:
        ready.write('ready\n')
        ready.flush()
        os.fsync(ready.fileno())
    while not os.path.exists(release_path):
        time.sleep(.01)
PY
state_lock_holder=$!
state_lock_ready_seen=0
for _ in $(seq 1 100); do
  if [ -e "$state_lock_ready" ]; then state_lock_ready_seen=1; break; fi
  sleep .02
done
[ "$state_lock_ready_seen" -eq 1 ] || fail "state lock holder did not become ready"
"${lifecycle_env[@]}" "$SCRIPT" request-handled missing-request >/dev/null 2>&1 &
blocked_handler_pid=$!
sleep .1
handler_waited=0
if kill -0 "$blocked_handler_pid" 2>/dev/null; then handler_waited=1; fi
kill "$blocked_handler_pid" 2>/dev/null || true
wait "$blocked_handler_pid" 2>/dev/null || true
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null &
locked_cleanup_pid=$!
cleanup_disabled_service=0
for _ in $(seq 1 100); do
  if [ "$(cat "$TMP_ROOT/systemctl.enabled" 2>/dev/null)" = disabled ]; then cleanup_disabled_service=1; break; fi
  sleep .02
done
cleanup_waited=0
if kill -0 "$locked_cleanup_pid" 2>/dev/null; then cleanup_waited=1; fi
touch "$state_lock_release"
wait "$state_lock_holder" || fail "state lock holder failed"
locked_cleanup_status=0
wait "$locked_cleanup_pid" || locked_cleanup_status=$?
[ "$handler_waited" -eq 1 ] || fail "request handling bypassed the stable Telegram state lock"
[ "$cleanup_disabled_service" -eq 1 ] || fail "cleanup did not disable the service before waiting for private state"
[ "$cleanup_waited" -eq 1 ] || fail "cleanup deleted private state while a Telegram state transition was active"
[ "$locked_cleanup_status" -eq 0 ] || fail "serialized cleanup failed"
[ ! -e "$unit_dir/firstmate-telegram.service" ] || fail "cleanup must remove its unit"
[ -e "$voice_home/.env" ] || fail "cleanup must preserve .env"
[ ! -e "$voice_home/state/telegram" ] || fail "cleanup must remove private Telegram state"
[ ! -e "$cleanup_audio" ] || fail "cleanup must delete pending temporary audio"
grep -F $'\tcheck\tunrelated:keep\t' "$voice_home/state/.wake-queue" >/dev/null || fail "cleanup removed an unrelated wake"
! grep -F $'\tcheck\ttelegram:' "$voice_home/state/.wake-queue" >/dev/null || fail "cleanup left Telegram wake rows"
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null || fail "cleanup must be idempotent"
if "${lifecycle_env[@]}" "$SCRIPT" request-handled missing-request >/dev/null 2>&1; then
  fail "request handling remained available after cleanup"
fi
[ ! -e "$voice_home/state/telegram" ] || fail "a failed post-cleanup request recreated private Telegram state"

"${lifecycle_env[@]}" "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null
set_updates '[]' "$voice_home"
rm -f "$voice_home/updates-entered"
touch "$voice_home/block-updates"
"${lifecycle_env[@]}" "$SCRIPT" serve --poll-timeout 1 >"$voice_home/direct-cleanup-service.out" 2>&1 &
direct_cleanup_pid=$!
direct_cleanup_started=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/updates-entered" ]; then direct_cleanup_started=1; break; fi
  sleep .02
done
[ "$direct_cleanup_started" -eq 1 ] || fail "direct cleanup runtime did not acquire service ownership"
if "${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null 2>&1; then
  fail "cleanup removed state while a direct runtime owned the service lock"
fi
kill -0 "$direct_cleanup_pid" 2>/dev/null || fail "refused cleanup stopped the direct runtime"
[ -f "$voice_home/config/telegram.json" ] || fail "refused cleanup removed the active runtime pairing"
[ -d "$voice_home/state/telegram" ] || fail "refused cleanup removed the active runtime state"
kill "$direct_cleanup_pid" 2>/dev/null || true
rm -f "$voice_home/block-updates"
wait "$direct_cleanup_pid" 2>/dev/null || true
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null || fail "cleanup failed after the direct runtime stopped"

# Pairing, outbound sends, and cleanup share one stable home lifecycle boundary.
"${lifecycle_env[@]}" "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null
printf 'serialized outbound\n' > "$voice_home/serialized-send.txt"
touch "$voice_home/hold-send"
rm -f "$voice_home/send-entered"
"${lifecycle_env[@]}" "$SCRIPT" send --text-file "$voice_home/serialized-send.txt" >/dev/null &
serialized_send_pid=$!
serialized_send_entered=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/send-entered" ]; then serialized_send_entered=1; break; fi
  sleep .02
done
[ "$serialized_send_entered" -eq 1 ] || fail "serialized outbound send did not reach the fake server"
"${lifecycle_env[@]}" "$SCRIPT" pair --user-id 88 --chat-id 88 >/dev/null &
serialized_pair_pid=$!
sleep .1
kill -0 "$serialized_pair_pid" 2>/dev/null || fail "pairing did not wait for the in-flight outbound send"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_id"])' "$voice_home/config/telegram.json")" -eq 77 ] || fail "pairing changed identity during an outbound send"
rm -f "$voice_home/hold-send"
wait "$serialized_send_pid" || fail "serialized outbound send failed"
wait "$serialized_pair_pid" || fail "serialized pairing replacement failed"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_id"])' "$voice_home/config/telegram.json")" -eq 88 ] || fail "serialized pairing replacement was not committed"
"${lifecycle_env[@]}" "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null

touch "$voice_home/hold-send"
rm -f "$voice_home/send-entered"
"${lifecycle_env[@]}" "$SCRIPT" send --text-file "$voice_home/serialized-send.txt" >/dev/null &
cleanup_send_pid=$!
cleanup_send_entered=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/send-entered" ]; then cleanup_send_entered=1; break; fi
  sleep .02
done
[ "$cleanup_send_entered" -eq 1 ] || fail "cleanup serialization send did not reach the fake server"
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null &
serialized_cleanup_pid=$!
sleep .1
kill -0 "$serialized_cleanup_pid" 2>/dev/null || fail "cleanup did not wait for the in-flight outbound send"
[ -f "$voice_home/config/telegram.json" ] || fail "cleanup removed pairing during an outbound send"
rm -f "$voice_home/hold-send"
wait "$cleanup_send_pid" || fail "outbound send failed while cleanup waited"
wait "$serialized_cleanup_pid" || fail "serialized cleanup failed"
[ ! -e "$voice_home/state/telegram" ] || fail "serialized cleanup retained private Telegram state"
[ ! -e "$voice_home/config/telegram.json" ] || fail "serialized cleanup retained pairing config"
[ -f "$voice_home/state/.telegram-lifecycle.lock" ] || fail "cleanup removed the stable lifecycle lock"
[ -f "$voice_home/state/.telegram-state.lock" ] || fail "cleanup removed the stable state lock"
[ -f "$voice_home/state/.telegram-service.lock" ] || fail "cleanup removed the stable service lock"
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null || fail "cleanup with retained stable locks was not idempotent"

# The singleton unit transition serializes concurrent installs for different homes.
"${lifecycle_env[@]}" "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null
env FM_HOME="$other_home" \
  FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" \
  FM_TELEGRAM_EXPECT_HOME="$other_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT" \
  "$SCRIPT" --test-api-base "$(test_api_base "$voice_home")" pair --user-id 77 --chat-id 77 >/dev/null
unit_hold="$TMP_ROOT/unit-transition"
rm -f "$unit_hold.entered" "$unit_hold.release"
env FM_HOME="$voice_home" FM_TELEGRAM_TEST_API_BASE="$(test_api_base "$voice_home")" \
  FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" \
  FM_TELEGRAM_EXPECT_HOME="$voice_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT" \
  FM_TELEGRAM_DAEMON_HOLD="$unit_hold" "$SCRIPT" --test-api-base "$(test_api_base "$voice_home")" install >/dev/null &
first_install_pid=$!
unit_transition_entered=0
for _ in $(seq 1 100); do
  if [ -e "$unit_hold.entered" ]; then unit_transition_entered=1; break; fi
  sleep .02
done
[ "$unit_transition_entered" -eq 1 ] || fail "first singleton install did not reach its held unit transition"
env FM_HOME="$other_home" FM_TELEGRAM_TEST_API_BASE="$(test_api_base "$voice_home")" \
  FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" \
  FM_TELEGRAM_EXPECT_HOME="$other_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT" \
  "$SCRIPT" --test-api-base "$(test_api_base "$voice_home")" install >/dev/null 2>&1 &
second_install_pid=$!
sleep .1
kill -0 "$second_install_pid" 2>/dev/null || fail "concurrent install bypassed the singleton unit transition"
touch "$unit_hold.release"
wait "$first_install_pid" || fail "serialized first singleton install failed"
if wait "$second_install_pid"; then
  fail "serialized second home replaced the installed singleton unit"
fi
"${lifecycle_env[@]}" "$SCRIPT" status >/dev/null || fail "singleton unit no longer belonged to the first installed home"
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null || fail "serialized singleton cleanup failed"

grep -F 'test-only-token' "$home/state/.wake-queue" >/dev/null && fail "bot token entered wake data"
pass "Telegram transport pairing, queueing, dedupe, drops, voice flow, safety, and lifecycle behave as specified"
