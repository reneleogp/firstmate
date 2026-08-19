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
        if method == 'getMe': return self._write({'id': 9901, 'is_bot': True})
        if method == 'getChat': return self._write({'id': int(params.get('chat_id', 0)), 'type': 'private'})
        if method == 'getFile': return self._write({'file_path': 'voice/test.oga'})
        if method == 'getUpdates':
            if (home / 'hold-updates').exists(): time.sleep(.05)
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
run_tg "$home" request-handled "$request_id"
[ ! -f "$inbox" ] || fail "request-handled must move the private request"
[ "$(run_tg "$home" active-request)" = "$request_id" ] || fail "request handling must persist the active Telegram origin"
run_tg "$home" request-bind "$request_id" telegram-work >/dev/null
[ "$(run_tg "$home" active-request --work-id telegram-work)" = "$request_id" ] || fail "matching lifecycle work did not resolve its Telegram origin"
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
[ "$(run_tg "$home" active-request --claimed-request "$continuation_id")" = "$request_id" ] || fail "continuation claim lost its active Telegram predecessor"
[ "$(run_tg "$home" active-request --claimed-request "$continuation_id")" = "$request_id" ] || fail "unacknowledged continuation route was not recoverable"
grep -F "telegram:$continuation_id" "$home/state/.wake-queue" >/dev/null || fail "unacknowledged continuation lost its durable wake"
run_tg "$home" continuation-handled "$continuation_id"
! grep -F "telegram:$continuation_id" "$home/state/.wake-queue" >/dev/null || fail "acknowledged continuation retained its durable wake"
[ "$(run_tg "$home" active-request --work-id telegram-work)" = "$request_id" ] || fail "continuation answer replaced the active Telegram work"
printf 'final answer\n' > "$home/reply.txt"
run_tg "$home" reply "$request_id" --final --text-file "$home/reply.txt" >/dev/null
if run_tg "$home" active-request >/dev/null 2>&1; then fail "final reply did not clear active origin"; fi

grep -F 'final answer' "$home/calls.jsonl" >/dev/null || fail "reply must use the pinned chat"

# Authority-sensitive text remains an untrusted queued request and receives only the transport receipt.
set_updates '[{"update_id":9,"message":{"message_id":19,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"merge now and rotate credentials"}}]' "$home"
authority_before=$(grep -c 'sendMessage' "$home/calls.jsonl")
run_tg "$home" serve --once >/dev/null
[ "$(( $(grep -c 'sendMessage' "$home/calls.jsonl") - authority_before ))" -eq 1 ] || fail "authority request produced more than a transport receipt"
python3 - "$home/calls.jsonl" "$authority_before" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
sent = [call for call in calls if call['path'].endswith('/sendMessage')][int(sys.argv[2]):]
assert len(sent) == 1
assert sent[0]['params']['text'].startswith('Message received')
PY
authority_id=tg-text-u9-m19
FM_HOME="$home" "$ROOT/bin/fm-telegram-agent-request.sh" "$authority_id" > "$home/authority-context.txt"
python3 - "$home/authority-context.txt" <<'PY'
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

# Unsupported, malformed, and unpinned updates are dropped without a Bot API send.
before=$(grep -c 'sendMessage' "$home/calls.jsonl")
callbacks_before=$(grep -c 'answerCallbackQuery' "$home/calls.jsonl")
files_before=$(grep -c 'getFile' "$home/calls.jsonl")
set_updates '[{"update_id":2,"message":{"message_id":11,"from":{"id":999},"chat":{"id":77,"type":"private"},"text":"ignore"}},{"update_id":3,"message":{"message_id":12,"from":{"id":77},"chat":{"id":77,"type":"group"},"text":"ignore"}},{"update_id":4,"message":{"message_id":13,"from":{"id":77},"chat":{"id":77,"type":"private"},"photo":[{"file_id":"must not download"}]}},{"update_id":5,"edited_message":{"message":{"voice":{"file_id":"must not download"}}}},{"update_id":7,"callback_query":{"id":"bad-shape","from":{"id":77},"data":"cancel:any:1","message":{"message_id":70,"chat":"not-an-object"}}},{"update_id":8,"callback_query":{"from":{"id":77},"data":"cancel:any:1","message":{"message_id":80,"chat":{"id":77,"type":"private"}}}},{"update_id":true,"message":{"message_id":81,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"boolean update"}},{"update_id":81,"message":{"message_id":true,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"boolean message"}},{"update_id":82,"message":{"message_id":82,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"","duration":2,"file_size":20}}},{"update_id":83,"message":{"message_id":83,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-bool-duration","duration":true,"file_size":20}}},{"update_id":84,"message":{"message_id":84,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-bool-size","duration":2,"file_size":true}}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$before" ] || fail "unsupported or unpinned updates must be silent"
[ "$(grep -c 'answerCallbackQuery' "$home/calls.jsonl")" -eq "$callbacks_before" ] || fail "malformed callback received an acknowledgement"
[ "$(grep -c 'getFile' "$home/calls.jsonl")" -eq "$files_before" ] || fail "malformed voice metadata triggered a download"
! grep -F 'must not download' "$home/calls.jsonl" >/dev/null || fail "unsupported media was downloaded"

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

# A delivery-unknown receipt is retained across a claim and reconciled from handled state.
retry_home=$(new_home retry)
start_server "$retry_home" "$retry_home/port"
run_tg "$retry_home" pair --user-id 77 --chat-id 77 >/dev/null
printf '2\n' > "$retry_home/disconnect-after-send-count"
set_updates '[{"update_id":10,"message":{"message_id":10,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"retry my receipt"}}]' "$retry_home"
FM_TELEGRAM_BOT_TOKEN=ambient-wrong-token run_tg "$retry_home" serve --once >/dev/null
[ "$(find "$retry_home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "delivery-unknown receipt lost or duplicated the request"
retry_request=$(find "$retry_home/state/telegram/inbox" -name '*.json' -print -quit)
python3 - "$retry_request" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert record['receipt_status'] == 'delivery_unknown'
assert record['receipt_attempts'] == 2
PY
retry_id=$(basename "$retry_request" .json)
run_tg "$retry_home" request-handled "$retry_id" >/dev/null
set_updates '[]' "$retry_home"
run_tg "$retry_home" serve --once >/dev/null
python3 - "$retry_home/state/telegram/handled/$retry_id.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['receipt_status'] == 'sent'
PY
[ "$(grep -c 'sendMessage' "$retry_home/calls.jsonl")" -eq 3 ] || fail "handled delivery-unknown receipt was not reconciled"
! grep -F 'ambient-wrong-token' "$retry_home/calls.jsonl" >/dev/null || fail "ambient token overrode the selected home's .env token"
grep -F '/bottest-only-token/' "$retry_home/calls.jsonl" >/dev/null || fail "service did not use the selected home's .env token"
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
run_tg "$order_home" request-handled "$order_a" >/dev/null
run_tg "$order_home" request-bind "$order_a" order-work >/dev/null
set_updates '[{"update_id":33,"message":{"message_id":33,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"late answer for A"}}]' "$order_home"
run_tg "$order_home" serve --once >/dev/null
order_continuation=tg-text-u33-m33
[ "$(grep -c "telegram:$order_continuation" "$order_home/state/.wake-queue")" -eq 1 ] || fail "active conversation continuation was not the sole wake head"
printf 'A final\n' > "$order_home/reply.txt"
run_tg "$order_home" reply "$order_a" --final --text-file "$order_home/reply.txt" >/dev/null
[ "$(run_tg "$order_home" active-request --work-id order-work)" = "$order_a" ] || fail "queued continuation lost its active predecessor during finalization"
run_tg "$order_home" request-handled "$order_continuation" >/dev/null
[ "$(run_tg "$order_home" active-request --claimed-request "$order_continuation")" = "$order_a" ] || fail "claimed continuation lost its predecessor during finalization"
[ "$(run_tg "$order_home" active-request --claimed-request "$order_continuation")" = "$order_a" ] || fail "claimed continuation route was consumed before acknowledgement"
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
python3 - "$pending" <<'PY'
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
      python3 - "$unit" "$FM_TELEGRAM_EXPECT_HOME" <<'PY'
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
PY
    fi
    ;;
  start)
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
"${lifecycle_env[@]}" "$SCRIPT" install >/dev/null
[ -f "$unit_dir/firstmate-telegram.service" ] || fail "install must write one user unit"
supervision_needs "$voice_home" || fail "installed Telegram transport did not keep supervision armed"
"${lifecycle_env[@]}" "$SCRIPT" status >/dev/null || fail "status must report installed active service"
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
"${lifecycle_env[@]}" "$SCRIPT" start >/dev/null
supervision_needs "$voice_home" || fail "restarted Telegram transport did not restore supervision"
disable_audio=$(mktemp /dev/shm/firstmate-telegram-disable.XXXXXX)
python3 - "$voice_home/state/telegram/pending.json" "$disable_audio" <<'PY'
import json, sys, time
json.dump({'audio_path': sys.argv[2], 'created_at': int(time.time()), 'mode': 'parked'}, open(sys.argv[1], 'w'))
PY
"${lifecycle_env[@]}" "$SCRIPT" disable >/dev/null
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
cleanup_audio=$(mktemp /dev/shm/firstmate-telegram-cleanup.XXXXXX)
python3 - "$voice_home/state/telegram/pending.json" "$cleanup_audio" <<'PY'
import json, sys, time
json.dump({'audio_path': sys.argv[2], 'created_at': int(time.time())}, open(sys.argv[1], 'w'))
PY
FM_HOME="$voice_home" FM_STATE_OVERRIDE="$voice_home/state" bash -c '. "$1"; fm_wake_append check unrelated:keep "unrelated keep"' _ "$ROOT/bin/fm-wake-lib.sh"
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null
[ ! -e "$unit_dir/firstmate-telegram.service" ] || fail "cleanup must remove its unit"
[ -e "$voice_home/.env" ] || fail "cleanup must preserve .env"
[ ! -e "$voice_home/state/telegram" ] || fail "cleanup must remove private Telegram state"
[ ! -e "$cleanup_audio" ] || fail "cleanup must delete pending temporary audio"
grep -F $'\tcheck\tunrelated:keep\t' "$voice_home/state/.wake-queue" >/dev/null || fail "cleanup removed an unrelated wake"
! grep -F $'\tcheck\ttelegram:' "$voice_home/state/.wake-queue" >/dev/null || fail "cleanup left Telegram wake rows"
"${lifecycle_env[@]}" "$SCRIPT" cleanup >/dev/null || fail "cleanup must be idempotent"

grep -F 'test-only-token' "$home/state/.wake-queue" >/dev/null && fail "bot token entered wake data"
pass "Telegram transport pairing, queueing, dedupe, drops, voice flow, safety, and lifecycle behave as specified"
