#!/usr/bin/env bash
# Public behavior tests for Python Telegram transport.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-tests)
export FM_TELEGRAM_UNIT_DIR="$TMP_ROOT/systemd-user"
PYTHON=${PYTHON:-python3}
SCRIPT="$ROOT/bin/fm-telegram.py"

new_home() {
  local home=$1
  mkdir -p "$home"
  printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' >"$home/.env"
  chmod 600 "$home/.env"
  printf '[]\n' >"$home/updates.json"
}

start_server() {
  local home=$1
  "$PYTHON" - "$home" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
home = Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, value):
        body = json.dumps({'ok': True, 'result': value}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        params = json.loads(self.rfile.read(size) or b'{}')
        with (home / 'calls.jsonl').open('a') as stream:
            stream.write(json.dumps({'path': self.path, 'params': params}) + '\n')
        method = self.path.rsplit('/', 1)[-1]
        if method == 'getMe': return self.reply({'id': 9901, 'is_bot': True})
        if method == 'getChat': return self.reply({'id': params.get('chat_id'), 'type': 'private'})
        if method == 'getFile': return self.reply({'file_path': 'voice/test.oga'})
        if method == 'getUpdates':
            updates = json.loads((home / 'updates.json').read_text())
            (home / 'updates.json').write_text('[]')
            return self.reply(updates)
        return self.reply({})
    def do_GET(self):
        if '/file/' in self.path:
            body = b'fake voice'
            self.send_response(200); self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        self.send_response(404); self.end_headers()
server = HTTPServer(('127.0.0.1', 0), Handler)
(home / 'port').write_text(str(server.server_port))
(home / 'server.pid').write_text(str(__import__('os').getpid()))
server.serve_forever()
PY
  SERVER_PID=$!
  for _ in $(seq 1 50); do [ -s "$home/port" ] && return; sleep .02; done
  fail "fake Telegram server did not start"
}

SERVER_PID=
cleanup() { [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT
run_tg() { env FM_HOME="$1" "$SCRIPT" --test-api-base "http://127.0.0.1:$(cat "$1/port")" "${@:2}"; }
set_updates() { printf '%s\n' "$1" >"$2/updates.json"; }

home="$TMP_ROOT/home"
new_home "$home"
start_server "$home"
run_tg "$home" pair --user-id 77 --chat-id 77 >/dev/null
[ "$(stat -c %a "$home/config/telegram.json")" = 600 ] || fail "pairing was not private"

# Mode-off ordinary input is answered deterministically and never queued.
set_updates '[{"update_id":1,"message":{"message_id":1,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"must stay local"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(find "$home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 0 ] || fail "mode-off input was queued"
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
sent = [x['params']['text'] for x in calls if x['path'].endswith('/sendMessage')]
assert sent[-1].startswith('Bot · Telegram mirror mode is off')
PY

# Exact bot command works without a model and enables the private preference.
set_updates '[{"update_id":2,"message":{"message_id":2,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"/telegram on"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(cat "$home/config/telegram-mirror")" = on ] || fail "bot /telegram on did not persist mode"

set_updates '[{"update_id":3,"message":{"message_id":3,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"hello from Telegram"}}]' "$home"
run_tg "$home" serve --once >/dev/null
request="$home/state/telegram/inbox/tg-text-u3-m3.json"
[ -f "$request" ] || fail "mode-on text was not durably queued"
python3 - "$request" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['text'] == 'hello from Telegram'
PY
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
sent = [x['params']['text'] for x in calls if x['path'].endswith('/sendMessage')]
assert 'Bot · Queued for Firstmate.' in sent
PY

# Replayed Bot API delivery is deduplicated by update/message identity.
set_updates '[{"update_id":3,"message":{"message_id":3,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"hello from Telegram"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(find "$home/state/telegram/inbox" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "replayed update created a second request"

# Voice admission remains authenticated and emits the progress state only when it starts.
cat >"$home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
printf 'confirmed voice text\n'
SH
chmod +x "$home/parakeet.sh"
python3 - "$home/config/telegram.json" "$home/parakeet.sh" <<'PY'
import json, shlex, sys
path, command = sys.argv[1:]
data = json.load(open(path)); data['parakeet_command'] = shlex.quote(command); data['whisper_command'] = shlex.quote(command)
json.dump(data, open(path, 'w')); __import__('os').chmod(path, 0o600)
PY
set_updates '[{"update_id":4,"message":{"message_id":4,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-4","duration":2,"file_size":10}}}]' "$home"
run_tg "$home" serve --once >/dev/null
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
sent = [x['params']['text'] for x in calls if x['path'].endswith('/sendMessage')]
assert 'Bot · Transcribing…' in sent
PY

# Exact off command is deterministic and leaves ordinary queued content untouched.
set_updates '[{"update_id":5,"message":{"message_id":5,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"/telegram off"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(cat "$home/config/telegram-mirror")" = off ] || fail "bot /telegram off did not persist mode"
pass "Telegram pairing, mode-off refusal, exact mode commands, queueing, deduplication, and voice progress behavior"
