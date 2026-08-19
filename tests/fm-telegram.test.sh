#!/usr/bin/env bash
# Behavioral tests for the one-home Telegram transport.
# The fake HTTP server is local-only and no real bot credentials or service are used.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-tests)
PYTHON=${PYTHON:-python3}
SCRIPT="$ROOT/bin/fm-telegram.py"

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
            if isinstance(text, str) and text.startswith('Message received'):
                wake_path = home / 'state' / '.wake-queue'
                wake = wake_path.read_text() if wake_path.exists() else ''
                if not inbox and not handled:
                    (home / 'receipt-before-durable').write_text('failed')
                if inbox and 'telegram tg-' not in wake:
                    (home / 'receipt-before-durable').write_text('failed')
            hold = home / 'hold-send'
            if hold.exists():
                (home / 'send-entered').write_text('entered')
                while hold.exists(): time.sleep(.01)
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

set_updates() { printf '%s\n' "$1" > "$2/updates.json"; }
api_env() { printf 'FM_HOME=%s FM_TELEGRAM_API_BASE=http://127.0.0.1:%s' "$1" "$(cat "$1/port")"; }
run_tg() { env FM_HOME="$1" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$1/port")" "$SCRIPT" "${@:2}"; }
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
env FM_HOME="$runtime_home" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$runtime_home/port")" \
  "$SCRIPT" serve --poll-timeout 1 >"$runtime_home/service.out" 2>&1 &
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

rm -f "$home/port"
start_server "$home" "$home/port"
set_updates '[{"update_id":1,"message":{"message_id":10,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"please inspect this"}}]' "$home"
run_tg "$home" serve --once >/dev/null
inbox=$(find "$home/state/telegram/inbox" -name '*.json' -print -quit)
[ -f "$inbox" ] || fail "valid text must be durably queued"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["text"])' "$inbox")" = "please inspect this" ] || fail "queued request text mismatch"
call_count=$(grep -c 'sendMessage' "$home/calls.jsonl")
[ "$call_count" -eq 1 ] || fail "text receipt must be sent once"
grep -F 'Message received and queued. It will be processed when Firstmate starts.' "$home/calls.jsonl" >/dev/null || fail "offline wording mismatch"
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
printf 'endpoint_task_id=terminal-work\n' > "$home/state/terminal-work.meta"
if run_tg "$home" request-bind "$request_id" terminal-work >/dev/null 2>&1; then
  fail "Telegram request bound to a pre-existing terminal work record"
fi
[ "$(run_tg "$home" active-request --claimed-request "$request_id")" = "$request_id" ] || fail "rejected terminal work binding changed the active route"
run_tg "$home" request-bind "$request_id" telegram-work >/dev/null
grep -F "telegram:$request_id" "$home/state/.wake-queue" >/dev/null || fail "bind-before-launch lost the initial recovery wake"
bound_initial_route=$(printf '%s\t%s' "$request_id" telegram-work)
[ "$(run_tg "$home" active-request --claimed-request "$request_id")" = "$bound_initial_route" ] || fail "bound initial recovery did not expose its exact work id"
run_tg "$home" request-handled "$request_id" >/dev/null || fail "bound initial recovery claim was not idempotent"
printf 'endpoint_task_id=telegram-work\n' > "$home/state/telegram-work.meta"
set_updates '[]' "$home"
run_tg "$home" serve --once >/dev/null
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
printf 'decision reply\n' > "$home/reply.txt"
run_tg "$home" reply "$request_id" --text-file "$home/reply.txt" >/dev/null
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
printf 'final answer\n' > "$home/reply.txt"
run_tg "$home" reply "$request_id" --final --text-file "$home/reply.txt" >/dev/null
if run_tg "$home" active-request >/dev/null 2>&1; then fail "final reply did not clear active origin"; fi

grep -F 'final answer' "$home/calls.jsonl" >/dev/null || fail "reply must use the pinned chat"

set_updates '[{"update_id":103,"message":{"message_id":112,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"ask me directly"}}]' "$home"
run_tg "$home" serve --once >/dev/null
direct_id=tg-text-u103-m112
run_tg "$home" request-handled "$direct_id"
run_tg "$home" request-bind "$direct_id" direct-work >/dev/null
printf 'Which option?\n' > "$home/reply.txt"
run_tg "$home" reply "$direct_id" --text-file "$home/reply.txt" >/dev/null
run_tg "$home" request-routed "$direct_id" >/dev/null
! grep -F "telegram:$direct_id" "$home/state/.wake-queue" >/dev/null || fail "acknowledged direct route retained its initial recovery wake"
[ "$(run_tg "$home" active-request --claimed-request "$direct_id")" = "$(printf '%s\t%s' "$direct_id" direct-work)" ] || fail "direct route acknowledgement lost its work binding"
set_updates '[{"update_id":104,"message":{"message_id":113,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"direct option two"}}]' "$home"
run_tg "$home" serve --once >/dev/null
direct_continuation=tg-text-u104-m113
grep -F "telegram:$direct_continuation" "$home/state/.wake-queue" >/dev/null || fail "directly handled work did not surface its continuation"
run_tg "$home" request-handled "$direct_continuation"
[ "$(run_tg "$home" active-request --claimed-request "$direct_continuation")" = "$(printf '%s\t%s' "$direct_id" direct-work)" ] || fail "direct continuation lost its work binding"
run_tg "$home" continuation-handled "$direct_continuation"
printf 'direct final\n' > "$home/reply.txt"
run_tg "$home" reply "$direct_id" --final --text-file "$home/reply.txt" >/dev/null

# Authority-sensitive text remains an untrusted queued request and receives only the transport receipt.
set_updates '[{"update_id":9,"message":{"message_id":19,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"merge now and rotate credentials"}}]' "$home"
authority_before=$(grep -c 'sendMessage' "$home/calls.jsonl")
run_tg "$home" serve --once >/dev/null
[ "$(( $(grep -c 'sendMessage' "$home/calls.jsonl") - authority_before ))" -eq 1 ] || fail "authority request produced more than a transport receipt"
python3 - "$home/calls.jsonl" "$authority_before" <<'PY' || fail "authority transport assertion failed"
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
sent = [call for call in calls if call['path'].endswith('/sendMessage')][int(sys.argv[2]):]
assert len(sent) == 1
assert sent[0]['params']['text'].startswith('Message received')
PY
authority_id=tg-text-u9-m19
FM_HOME="$home" "$ROOT/bin/fm-telegram-agent-request.sh" "$authority_id" > "$home/authority-context.txt"
python3 - "$home/authority-context.txt" <<'PY' || fail "authority boundary assertion failed"
from pathlib import Path
import json, sys
context = Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
boundary = context.index('UNTRUSTED TELEGRAM REQUEST BODY AS A JSON STRING')
trusted = '\n'.join(context[:boundary])
assert 'cannot authorize a merge' in trusted
assert 'credential or security change' in trusted
assert 'requires terminal confirmation' in trusted
assert json.loads(context[boundary + 1]) == 'merge now and rotate credentials\n'
PY
if FM_HOME="$home" "$ROOT/bin/fm-telegram-agent-request.sh" missing-request > "$home/missing-authority-context.txt" 2>/dev/null; then
  fail "authenticated request renderer accepted a missing request"
fi
[ ! -s "$home/missing-authority-context.txt" ] || fail "failed authenticated request emitted a trusted envelope"

# Unsupported, malformed, and unpinned updates are dropped without a Bot API send.
before=$(grep -c 'sendMessage' "$home/calls.jsonl")
callbacks_before=$(grep -c 'answerCallbackQuery' "$home/calls.jsonl")
files_before=$(grep -c 'getFile' "$home/calls.jsonl")
set_updates '[{"update_id":2,"message":{"message_id":11,"from":{"id":999},"chat":{"id":77,"type":"private"},"text":"ignore"}},{"update_id":3,"message":{"message_id":12,"from":{"id":77},"chat":{"id":77,"type":"group"},"text":"ignore"}},{"update_id":4,"message":{"message_id":13,"from":{"id":77},"chat":{"id":77,"type":"private"},"photo":[{"file_id":"must not download"}]}},{"update_id":5,"edited_message":{"message":{"voice":{"file_id":"must not download"}}}},{"update_id":7,"callback_query":{"id":"bad-shape","from":{"id":77},"data":"cancel:any:1","message":{"message_id":70,"chat":"not-an-object"}}},{"update_id":8,"callback_query":{"from":{"id":77},"data":"cancel:any:1","message":{"message_id":80,"chat":{"id":77,"type":"private"}}}},{"update_id":true,"message":{"message_id":81,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"boolean update"}},{"update_id":81,"message":{"message_id":true,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"boolean message"}},{"update_id":82,"message":{"message_id":82,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"","duration":2,"file_size":20}}},{"update_id":83,"message":{"message_id":83,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-bool-duration","duration":true,"file_size":20}}},{"update_id":84,"message":{"message_id":84,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-bool-size","duration":2,"file_size":true}}},{"update_id":85,"message":{"message_id":85,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"conflicting text","photo":[{"file_id":"must not download"}]}},{"update_id":86,"message":{"message_id":86,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"must not download","duration":2,"file_size":20},"sticker":{"file_id":"must not download"}}},{"update_id":87,"message":{"message_id":87,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"conflicting update"},"edited_message":{"message_id":88,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"must not parse"}},{"update_id":88,"message":{"message_id":88,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"unknown update companion"},"future_update":{"opaque":"must not parse"}},{"update_id":89,"message":{"message_id":89,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"unknown message content","future_content":{"opaque":"must not parse"}}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$before" ] || fail "unsupported or unpinned updates must be silent"
[ "$(grep -c 'answerCallbackQuery' "$home/calls.jsonl")" -eq "$callbacks_before" ] || fail "malformed callback received an acknowledgement"
[ "$(grep -c 'getFile' "$home/calls.jsonl")" -eq "$files_before" ] || fail "malformed voice metadata triggered a download"
! grep -F 'must not download' "$home/calls.jsonl" >/dev/null || fail "unsupported media was downloaded"
python3 - "$home/updates.json" <<'PY' || fail "oversized identifier fixture failed"
import json, sys
oversized = 1 << 52
json.dump([
    {'update_id': oversized, 'message': {
        'message_id': 90, 'from': {'id': 77},
        'chat': {'id': 77, 'type': 'private'}, 'text': 'oversized update'}},
    {'update_id': 90, 'message': {
        'message_id': oversized, 'from': {'id': 77},
        'chat': {'id': 77, 'type': 'private'}, 'text': 'oversized message'}},
    {'update_id': 91, 'callback_query': {
        'id': 'x' * 257, 'from': {'id': 77}, 'data': 'cancel:any:1',
        'message': {'message_id': 91, 'chat': {'id': 77, 'type': 'private'}}}},
    {'update_id': 92, 'callback_query': {
        'id': 'oversized-callback-message', 'from': {'id': 77}, 'data': 'cancel:any:1',
        'message': {'message_id': oversized, 'chat': {'id': 77, 'type': 'private'}}}},
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
        'message_id': value, 'from': {'id': 77},
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
grep -F 'Message received.' "$live_home/calls.jsonl" >/dev/null || fail "live-primary receipt mismatch"
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
printf 'endpoint_task_id=authority-work\n' > "$home/state/authority-work.meta"
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
printf 'endpoint_task_id=order-work\n' > "$order_home/state/order-work.meta"
set_updates '[{"update_id":33,"message":{"message_id":33,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"late answer for A"}}]' "$order_home"
run_tg "$order_home" serve --once >/dev/null
order_continuation=tg-text-u33-m33
[ "$(grep -c "telegram:$order_continuation" "$order_home/state/.wake-queue")" -eq 1 ] || fail "active conversation continuation was not the sole wake head"
printf 'A final\n' > "$order_home/reply.txt"
order_final_status=0
run_tg "$order_home" reply "$order_a" --final --text-file "$order_home/reply.txt" >/dev/null || order_final_status=$?
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
printf 'B final\n' > "$order_home/reply.txt"
run_tg "$order_home" reply "$order_b" --final --text-file "$order_home/reply.txt" >/dev/null
[ "$(grep -c "telegram:$order_c" "$order_home/state/.wake-queue")" -eq 1 ] || fail "ordered queue did not advance to its final head"

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
run_tg "$voice_home" pair --user-id 77 --chat-id 77 >/dev/null
python3 - "$voice_home/config/telegram.json" "$voice_home/parakeet.sh" "$voice_home/whisper.sh" <<'PY'
import json, shlex, sys
p=sys.argv[1]; d=json.load(open(p)); d['parakeet_command']=shlex.quote(sys.argv[2]); d['whisper_command']=shlex.quote(sys.argv[3]); json.dump(d, open(p,'w'))
PY
chmod 600 "$voice_home/config/telegram.json"
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
edit_data=$(callback_data "$voice_home" edit)
stale_send_data=$(callback_data "$voice_home" send)
malformed_callback_answers=$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")
set_updates '[{"update_id":2001,"callback_query":{"id":"cb-inline-conflict","from":{"id":77},"data":"'"$stale_send_data"'","message":{"message_id":2001,"chat":{"id":77,"type":"private"}},"inline_message_id":"conflict"}},{"update_id":2002,"callback_query":{"id":"cb-future-field","from":{"id":77},"data":"'"$stale_send_data"'","message":{"message_id":2002,"chat":{"id":77,"type":"private"}},"future_callback":{"opaque":true}}},{"update_id":2003,"callback_query":{"id":"cb-media-message","from":{"id":77},"data":"'"$stale_send_data"'","message":{"message_id":2003,"chat":{"id":77,"type":"private"},"photo":[{"file_id":"must not parse"}]}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$malformed_callback_answers" ] || fail "unsupported callback envelope was acknowledged"
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ] || fail "unsupported callback envelope queued a voice request"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mode"])' "$pending")" = confirm ] || fail "unsupported callback envelope changed pending voice state"
set_updates '[{"update_id":21,"callback_query":{"id":"cb-edit","from":{"id":77},"data":"'"$edit_data"'","message":{"message_id":201,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
prompt_count=$(grep -c 'Reply with the corrected text.' "$voice_home/calls.jsonl")
[ "$prompt_count" -eq 1 ] || fail "edit prompt missing"
set_updates '[{"update_id":210,"callback_query":{"id":"cb-edit-second-tap","from":{"id":77},"data":"'"$edit_data"'","message":{"message_id":201,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(grep -c 'Reply with the corrected text.' "$voice_home/calls.jsonl")" -eq "$prompt_count" ] || fail "a second edit tap repeated the prompt"
stale_send_answers=$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")
set_updates '[{"update_id":211,"callback_query":{"id":"cb-stale-send","from":{"id":77},"data":"'"$stale_send_data"'","message":{"message_id":201,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(find "$voice_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ] || fail "stale Send control queued text while an edit was pending"
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$stale_send_answers" ] || fail "stale Send control was acknowledged while an edit was pending"
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
env FM_HOME="$voice_home" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$voice_home/port")" "$SCRIPT" serve --once >/dev/null &
retry_pid=$!
retry_entered=0
for _ in $(seq 1 100); do
  if [ -e "$voice_home/whisper.sh.entered" ]; then retry_entered=1; break; fi
  sleep .02
done
[ "$retry_entered" -eq 1 ] || fail "Whisper retry did not start"
timeout 2 env FM_HOME="$voice_home" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$voice_home/port")" "$SCRIPT" active-request >/dev/null 2>&1
retry_lock_status=$?
[ "$retry_lock_status" -ne 124 ] || fail "Whisper retry held the Telegram state lock"
rm -f "$voice_home/whisper.sh.hold"
wait "$retry_pid"
grep -F 'whisper transcript' "$voice_home/calls.jsonl" >/dev/null || fail "retry must use Whisper transcript"
set_updates '[{"update_id":230,"callback_query":{"id":"cb-retry-second-tap","from":{"id":77},"data":"'"$retry_data"'","message":{"message_id":202,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(wc -c < "$voice_home/whisper.sh.calls" | tr -d ' ')" -eq 1 ] || fail "a second retry tap transcribed twice"
cancel_data=$(callback_data "$voice_home" cancel)
set_updates '[{"update_id":24,"callback_query":{"id":"cb-cancel","from":{"id":77},"data":"'"$cancel_data"'","message":{"message_id":203,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$audio" ] || fail "cancel must delete temporary audio"
[ ! -e "$pending" ] || fail "cancel must delete pending state"
cancel_answers=$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")
set_updates '[{"update_id":240,"callback_query":{"id":"cb-cancel-completed","from":{"id":77},"data":"'"$cancel_data"'","message":{"message_id":203,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ "$(grep -c 'answerCallbackQuery' "$voice_home/calls.jsonl")" -eq "$((cancel_answers + 1))" ] || fail "durably completed callback was not recognized idempotently"
[ ! -e "$pending" ] && [ ! -e "$audio" ] || fail "completed cancel callback recreated pending voice state"

# Confirmed voice queues text, while an expired pending record deletes its audio.
set_updates '[{"update_id":25,"message":{"message_id":25,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-2","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
pending_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_id"])' "$pending")
send_audio=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["audio_path"])' "$pending")
send_data=$(callback_data "$voice_home" send)
touch "$voice_home/hold-send"
rm -f "$voice_home/send-entered"
set_updates '[{"update_id":26,"callback_query":{"id":"cb-send","from":{"id":77},"data":"'"$send_data"'","message":{"message_id":204,"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
env FM_HOME="$voice_home" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$voice_home/port")" "$SCRIPT" serve --once >/dev/null &
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
python3 - "$pending" <<'PY'
import json, sys
data=json.load(open(sys.argv[1])); data['created_at']=0; json.dump(data, open(sys.argv[1], 'w'))
PY
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$expired_audio" ] || fail "expired pending voice must delete audio"
[ ! -e "$pending" ] || fail "expired pending voice must delete pending state"
cat > "$voice_home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
python3 -c 'print("x" * 4097)'
SH
chmod +x "$voice_home/parakeet.sh"
set_updates '[{"update_id":28,"message":{"message_id":28,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-long","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$pending" ] || fail "oversized transcript created unusable Telegram controls"

# Service lifecycle and cleanup are verified, scoped to this home, and leave .env intact.
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
assert command[0] == ':/usr/bin/python3'
assert command[1].endswith('/bin/fm-telegram.py')
assert command[2:] == ['--home', expected, 'serve']
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
    if [ ! -s "$root/systemctl.service.pid" ]; then
      env FM_HOME="$FM_TELEGRAM_EXPECT_HOME" FM_TELEGRAM_API_BASE="$FM_TELEGRAM_API_BASE" \
        "$FM_TELEGRAM_SERVICE_SCRIPT" --home "$FM_TELEGRAM_EXPECT_HOME" serve --poll-timeout 1 \
        >"$root/systemctl.service.log" 2>&1 &
      printf '%s\n' "$!" > "$root/systemctl.service.pid"
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
          env FM_HOME="$FM_TELEGRAM_EXPECT_HOME" FM_TELEGRAM_API_BASE="$FM_TELEGRAM_API_BASE" \
            "$FM_TELEGRAM_SERVICE_SCRIPT" --home "$FM_TELEGRAM_EXPECT_HOME" serve --once \
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
lifecycle_env=(env FM_HOME="$voice_home" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$voice_home/port")" FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" FM_TELEGRAM_EXPECT_HOME="$voice_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT")
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
"${lifecycle_env[@]}" "$SCRIPT" status >/dev/null || fail "status must report installed active service"
cp "$voice_home/config/telegram.json" "$voice_home/pairing-before-active-repair.json"
if "${lifecycle_env[@]}" "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null 2>&1; then
  fail "pairing changed while the owned Telegram service was active"
fi
cmp -s "$voice_home/config/telegram.json" "$voice_home/pairing-before-active-repair.json" || fail "active pairing attempt changed the pinned identity"
[ "$(cat "$TMP_ROOT/systemctl.active")" = active ] || fail "active pairing attempt stopped the service"
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
env FM_HOME="$other_home" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$voice_home/port")" \
  FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" \
  FM_TELEGRAM_EXPECT_HOME="$other_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT" \
  "$SCRIPT" pair --user-id 77 --chat-id 77 >/dev/null
unit_hold="$TMP_ROOT/unit-transition"
rm -f "$unit_hold.entered" "$unit_hold.release"
env FM_HOME="$voice_home" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$voice_home/port")" \
  FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" \
  FM_TELEGRAM_EXPECT_HOME="$voice_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT" \
  FM_TELEGRAM_DAEMON_HOLD="$unit_hold" "$SCRIPT" install >/dev/null &
first_install_pid=$!
unit_transition_entered=0
for _ in $(seq 1 100); do
  if [ -e "$unit_hold.entered" ]; then unit_transition_entered=1; break; fi
  sleep .02
done
[ "$unit_transition_entered" -eq 1 ] || fail "first singleton install did not reach its held unit transition"
env FM_HOME="$other_home" FM_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$voice_home/port")" \
  FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" \
  FM_TELEGRAM_EXPECT_HOME="$other_home" FM_TELEGRAM_SERVICE_SCRIPT="$SCRIPT" \
  "$SCRIPT" install >/dev/null 2>&1 &
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
