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

# Confirmed voice Send while mode is on becomes one normal queued Telegram-origin request.
set_updates '[{"update_id":5,"callback_query":{"id":"callback-send-on","from":{"id":77},"message":{"message_id":40,"date":1,"chat":{"id":77,"type":"private"},"text":"confirmed voice text"},"data":"send:voice-u4-m4:1"}}]' "$home"
run_tg "$home" serve --once >/dev/null
voice_request="$home/state/telegram/inbox/tg-voice-u4-m4.json"
[ -f "$voice_request" ] || fail "mode-on confirmed voice was not queued"
python3 - "$voice_request" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert record['origin'] == 'telegram' and record['source'] == 'voice'
assert record['confirmed'] is True and record['text'] == 'confirmed voice text'
PY

# A second pending voice supplies a stale cleanup control for the mode-off path.
set_updates '[{"update_id":6,"message":{"message_id":6,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-6","duration":2,"file_size":10}}}]' "$home"
run_tg "$home" serve --once >/dev/null

# Exact off command is deterministic and leaves ordinary queued content untouched.
set_updates '[{"update_id":7,"message":{"message_id":7,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"/telegram off"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(cat "$home/config/telegram-mirror")" = off ] || fail "bot /telegram off did not persist mode"

# A stale voice Send button cannot admit content after mode is turned off, while Cancel still cleans it up.
set_updates '[{"update_id":8,"callback_query":{"id":"callback-send-off","from":{"id":77},"message":{"message_id":60,"date":1,"chat":{"id":77,"type":"private"},"text":"confirmed voice text"},"data":"send:voice-u6-m6:1"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ ! -e "$home/state/telegram/inbox/tg-voice-u6-m6.json" ] || fail "mode-off voice callback admitted content"
[ -e "$home/state/telegram/pending.json" ] || fail "mode-off refusal removed the pending voice cleanup control"
set_updates '[{"update_id":9,"callback_query":{"id":"callback-cancel","from":{"id":77},"message":{"message_id":60,"date":1,"chat":{"id":77,"type":"private"},"text":"confirmed voice text"},"data":"cancel:voice-u6-m6:1"}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ ! -e "$home/state/telegram/pending.json" ] || fail "mode-off Cancel did not clean up pending voice state"

# The real mirror delivery interface chunks Unicode safely, retries definite rejection, and completes only sent requests.
printf 'on\n' >"$home/config/telegram-mirror"
rm -f "$home/state/telegram/.mirror-migration-v2"
printf '1\t1\tcheck\ttelegram:legacy-request\ttelegram legacy-request\n' >"$home/state/.wake-queue"
owner_script="$TMP_ROOT/mirror-owner.py"
cat >"$owner_script" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
script, home, base = sys.argv[1:]
owner = str(os.getpid()); capability = b'b' * 64 + b'\n'
Path(home, 'state', '.lock').write_text(owner + '\n')
def run(*args, api=base):
    reader, writer = os.pipe()
    os.write(writer, capability); os.close(writer)
    try:
        return subprocess.run(
            [script, '--home', home, '--test-api-base', api, *args,
             '--owner-pid', owner, '--capability-fd', str(reader)],
            text=True, capture_output=True, pass_fds=(reader,),
        )
    finally:
        os.close(reader)
request = 'tg-text-u3-m3'
assert run('mirror-open').returncode == 0
inbox = Path(home, 'state', 'telegram', 'inbox')
expired_id = 'tg-text-u899-m899'
expired_path = Path(inbox, expired_id + '.json')
expired_path.write_text(json.dumps({
    'request_id': expired_id, 'origin': 'telegram', 'text': 'expired while service stopped',
    'chat_id': 77, 'message_id': 899, 'update_id': 899,
    'created_at': 1, 'admission_sequence': 899, 'status': 'queued',
    'receipt_text': 'queued', 'receipt_status': 'pending',
}))
assert run('mirror-reconcile').returncode == 0
assert not expired_path.exists()
Path(home, 'state', '.wake-queue').write_text(
    '2\t2\tcheck\ttelegram:late-legacy\ttelegram late-legacy\n')
assert run('mirror-next').returncode == 0
assert 'telegram:late-legacy' in Path(home, 'state', '.wake-queue').read_text()
assert run('mirror-reconcile').returncode == 0
assert 'telegram:' not in Path(home, 'state', '.wake-queue').read_text()
stale_owner = subprocess.Popen(['sleep', '30'])
stale_id = 'tg-text-u900-m900'
stale_path = Path(inbox, stale_id + '.json')
stale_path.write_text(json.dumps({
    'request_id': stale_id, 'origin': 'telegram', 'text': 'stale pid claim',
    'chat_id': 77, 'message_id': 900, 'update_id': 900,
    'created_at': int(time.time()), 'admission_sequence': 900,
    'status': 'claimed', 'claim_owner_pid': stale_owner.pid,
    'claim_owner_identity': f'proc:{stale_owner.pid}:reused',
    'receipt_text': 'queued', 'receipt_status': 'pending',
}))
try:
    assert run('mirror-reconcile').returncode == 0
    stale_record = json.loads(stale_path.read_text())
    assert stale_record['status'] == 'queued'
    assert 'claim_owner_pid' not in stale_record and 'claim_owner_identity' not in stale_record
finally:
    stale_owner.terminate(); stale_owner.wait()
stale_path.unlink()
assert run('mirror-claim', request).returncode == 0
for index in range(260):
    queued_id = f'tg-text-u{1000 + index}-m{1000 + index}'
    Path(inbox, queued_id + '.json').write_text(json.dumps({
        'request_id': queued_id, 'origin': 'telegram', 'text': f'queued {index}',
        'chat_id': 77, 'message_id': 1000 + index, 'update_id': 1000 + index,
        'created_at': int(time.time()), 'admission_sequence': 1000 + index,
        'status': 'queued', 'receipt_text': 'queued', 'receipt_status': 'pending',
    }))
cleaned = subprocess.run(
    [script, '--home', home, '--test-api-base', base, 'serve', '--once'],
    text=True, capture_output=True,
)
assert cleaned.returncode == 0, cleaned.stderr
claimed_record = json.loads(Path(inbox, request + '.json').read_text())
assert claimed_record['status'] == 'claimed' and claimed_record['claim_owner_pid'] == int(owner)
assert isinstance(claimed_record['claim_owner_identity'], str)
body = 'Firstmate · ' + ('😀' * 3000)
body_path = os.path.join(home, 'long-reply.txt')
open(body_path, 'w').write(body)
open(os.path.join(home, 'reject-send'), 'w').close()
first = run('mirror-reply', 'delivery-long', '--text-file', body_path)
assert first.returncode == 0, first.stderr
second = run('mirror-reply', 'delivery-long', '--text-file', body_path)
assert second.returncode == 0, second.stderr
complete = run('mirror-complete', request, 'delivery-long')
assert complete.returncode == 0, complete.stderr
delivery_root = os.path.join(home, 'state', 'telegram', 'deliveries')
for index in range(260):
    delivery_id = f'retained-{index}'
    text = f'retained {index}'
    open(os.path.join(delivery_root, delivery_id + '.txt'), 'w').write(text)
    json.dump({'delivery_id': delivery_id, 'sha256': __import__('hashlib').sha256(text.encode()).hexdigest(),
               'status': ('pending' if index % 2 else 'sent'),
               'created_at': int(time.time()), 'chunks': []},
              open(os.path.join(delivery_root, delivery_id + '.json'), 'w'))
protector = subprocess.Popen(['sleep', '30'])
try:
    fields = Path(f'/proc/{protector.pid}/stat').read_text().rsplit(')', 1)[1].split()
    protector_identity = f'proc:{protector.pid}:{fields[19]}'
except OSError:
    started = subprocess.run(
        ['ps', '-o', 'lstart=', '-p', str(protector.pid)], text=True, capture_output=True,
    ).stdout.strip()
    protector_identity = f'ps:{protector.pid}:{started}'
protected_id = 'retained-live-pending'
protected_text = 'protected pending delivery'
open(os.path.join(delivery_root, protected_id + '.txt'), 'w').write(protected_text)
json.dump({
    'delivery_id': protected_id,
    'sha256': __import__('hashlib').sha256(protected_text.encode()).hexdigest(),
    'status': 'pending', 'created_at': 1, 'chunks': [],
    'delivery_owner_pid': protector.pid,
    'delivery_owner_identity': protector_identity,
}, open(os.path.join(delivery_root, protected_id + '.json'), 'w'))
unknown_path = os.path.join(home, 'unknown-reply.txt')
open(unknown_path, 'w').write('You · Terminal\n\nuncertain')
unknown = run('mirror-reply', 'delivery-unknown',
              '--text-file', unknown_path, api='http://127.0.0.1:1')
assert unknown.returncode == 3, unknown.stderr
again = run('mirror-reply', 'delivery-unknown', '--text-file', unknown_path)
assert again.returncode == 3, again.stderr
assert os.path.exists(os.path.join(delivery_root, protected_id + '.json'))
protector.terminate(); protector.wait()
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

# Every bounded reconciliation consumes legacy Telegram wakes, including rows published after migration.
if grep -q $'\ttelegram:' "$home/state/.wake-queue"; then
  fail "legacy Telegram wake survived bounded reconciliation"
fi

pass "Telegram mode, queue, voice, chunked delivery, completion, uncertainty, and migration behavior"
