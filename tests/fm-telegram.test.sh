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
        if method == 'sendMessage' and (home / 'reject-send').exists():
            (home / 'reject-send').unlink()
            body = json.dumps({'ok': False, 'error_code': 400}).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body); return
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
if [ -f "$home/state/.wake-queue" ] && grep -q $'\ttelegram:' "$home/state/.wake-queue"; then
  fail "mode-on admission published an obsolete model wake"
fi
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

# A stale voice Send button cannot admit content after mode is turned off, while Cancel still cleans it up.
set_updates '[{"update_id":6,"callback_query":{"id":"callback-send","from":{"id":77},"message":{"message_id":40,"date":1,"chat":{"id":77,"type":"private"},"text":"confirmed voice text"},"data":"send:voice-u4-m4:1"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ ! -e "$home/state/telegram/inbox/tg-voice-u4-m4.json" ] || fail "mode-off voice callback admitted content"
[ -e "$home/state/telegram/pending.json" ] || fail "mode-off refusal removed the pending voice cleanup control"
set_updates '[{"update_id":7,"callback_query":{"id":"callback-cancel","from":{"id":77},"message":{"message_id":40,"date":1,"chat":{"id":77,"type":"private"},"text":"confirmed voice text"},"data":"cancel:voice-u4-m4:1"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ ! -e "$home/state/telegram/pending.json" ] || fail "mode-off Cancel did not clean up pending voice state"

# The real mirror delivery interface chunks Unicode safely, retries definite rejection, and completes only sent requests.
owner_script="$TMP_ROOT/mirror-owner.py"
cat >"$owner_script" <<'PY'
import json, os, subprocess, sys, time
script, home, base = sys.argv[1:]
owner = str(os.getpid())
def run(*args, api=base):
    return subprocess.run([script, '--home', home, '--test-api-base', api, *args], text=True, capture_output=True)
request = 'tg-text-u3-m3'
assert run('mirror-reconcile', '--owner-pid', owner).returncode == 0
assert run('mirror-claim', request, '--owner-pid', owner).returncode == 0
body = 'Firstmate · ' + ('😀' * 3000)
body_path = os.path.join(home, 'long-reply.txt')
open(body_path, 'w').write(body)
open(os.path.join(home, 'reject-send'), 'w').close()
first = run('mirror-reply', 'delivery-long', '--owner-pid', owner, '--text-file', body_path)
assert first.returncode == 1, first.stderr
second = run('mirror-reply', 'delivery-long', '--owner-pid', owner, '--text-file', body_path)
assert second.returncode == 0, second.stderr
complete = run('mirror-complete', request, 'delivery-long', '--owner-pid', owner)
assert complete.returncode == 0, complete.stderr
delivery_root = os.path.join(home, 'state', 'telegram', 'deliveries')
for index in range(260):
    delivery_id = f'retained-{index}'
    text = f'retained {index}'
    open(os.path.join(delivery_root, delivery_id + '.txt'), 'w').write(text)
    json.dump({'delivery_id': delivery_id, 'sha256': __import__('hashlib').sha256(text.encode()).hexdigest(),
               'status': 'sent', 'created_at': int(time.time()), 'chunks': []},
              open(os.path.join(delivery_root, delivery_id + '.json'), 'w'))
unknown_path = os.path.join(home, 'unknown-reply.txt')
open(unknown_path, 'w').write('You · Terminal\n\nuncertain')
unknown = run('mirror-reply', 'delivery-unknown', '--owner-pid', owner,
              '--text-file', unknown_path, api='http://127.0.0.1:1')
assert unknown.returncode == 3, unknown.stderr
again = run('mirror-reply', 'delivery-unknown', '--owner-pid', owner,
            '--text-file', unknown_path)
assert again.returncode == 3, again.stderr
assert len([name for name in os.listdir(delivery_root) if name.endswith('.json')]) <= 256
PY
base="http://127.0.0.1:$(cat "$home/port")"
"$PYTHON" "$owner_script" "$SCRIPT" "$home" "$base" || fail "mirror delivery settlement interface failed"
[ ! -e "$home/state/telegram/inbox/tg-text-u3-m3.json" ] || fail "completed request remained queued"
[ -e "$home/state/telegram/handled/tg-text-u3-m3.json" ] || fail "completed request identity was not retained"
python3 - "$home/calls.jsonl" "$home/long-reply.txt" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
body = open(sys.argv[2]).read()
chunks = [call['params']['text'] for call in calls if call['path'].endswith('/sendMessage') and call['params']['text'].startswith(('Firstmate · ', '😀'))]
assert len(chunks) == 3
assert ''.join(chunks[1:]) == body
assert all(len(chunk.encode('utf-16-le')) // 2 <= 4096 for chunk in chunks)
PY

# One-time migration consumes legacy Telegram wakes without publishing replacements.
rm -f "$home/state/telegram/.mirror-migration-v2"
printf '1\t1\tcheck\ttelegram:legacy-request\ttelegram legacy-request\n' >"$home/state/.wake-queue"
run_tg "$home" mirror-reconcile >/dev/null
if grep -q $'\ttelegram:' "$home/state/.wake-queue"; then
  fail "legacy Telegram wake survived mirror migration"
fi

pass "Telegram mode, queue, voice, chunked delivery, completion, uncertainty, and migration behavior"
