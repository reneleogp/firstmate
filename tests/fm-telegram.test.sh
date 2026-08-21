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
        if method == 'sendMessage':
            next_id = int((home / 'next-message-id').read_text()) if (home / 'next-message-id').exists() else 1000
            (home / 'next-message-id').write_text(str(next_id + 1))
            with (home / 'sent.jsonl').open('a') as stream:
                stream.write(json.dumps({'params': params, 'message_id': next_id}) + '\n')
            return self.reply({'message_id': next_id, 'chat': {'id': params.get('chat_id')}})
        if method in {'editMessageText', 'editMessageReplyMarkup'}:
            return self.reply({'message_id': params.get('message_id'), 'chat': {'id': params.get('chat_id')}})
        if method == 'answerCallbackQuery':
            return self.reply(True)
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
sent = [x for x in calls if x['path'].endswith('/sendMessage')]
assert sent[-1]['params']['text'].startswith('Bot · Telegram mirror mode is off')
assert sent[-1]['params']['reply_parameters'] == {'message_id': 1}
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
sent = [x for x in calls if x['path'].endswith('/sendMessage')]
queued = [x for x in sent if x['params']['text'] == 'Bot · Queued for Firstmate.'][-1]
assert queued['params']['reply_parameters'] == {'message_id': 3}
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
expired_held_id = 'tg-text-u898-m898'
expired_held_path = Path(inbox, expired_held_id + '.json')
expired_held_path.write_text(json.dumps({
    'request_id': expired_held_id, 'origin': 'telegram', 'text': 'expired held request',
    'chat_id': 77, 'message_id': 898, 'update_id': 898,
    'created_at': 1, 'admission_sequence': 898, 'status': 'held',
    'held_turn_id': 'expired-held-turn', 'held_at': 1,
    'receipt_text': 'queued', 'receipt_status': 'pending',
}))
assert run('mirror-reconcile', '--preserve-request', expired_held_id).returncode == 0
assert not expired_path.exists()
assert not expired_held_path.exists()
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
assert run('mirror-delivered', request).returncode == 0
owned = run('mirror-reconcile', '--preserve-request', request)
assert owned.returncode == 0 and f'owned\t{request}' in owned.stdout
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
terminal_body = 'You · Terminal\n\nreserved until Pi acceptance'
terminal_path = os.path.join(home, 'terminal-reserved.txt')
open(terminal_path, 'w').write(terminal_body)
delivery_root = os.path.join(home, 'state', 'telegram', 'deliveries')
records_before_validation = list(Path(delivery_root).glob('*.json')) if Path(delivery_root).exists() else []
validated = run('mirror-validate', '--text-file', terminal_path)
assert validated.returncode == 0, validated.stderr
oversized_path = os.path.join(home, 'terminal-oversized.txt')
open(oversized_path, 'w').write('You · Terminal\n\n' + ('x' * (256 * 1024)))
oversized = run('mirror-validate', '--text-file', oversized_path)
assert oversized.returncode != 0 and 'response limit' in oversized.stderr
records_after_validation = list(Path(delivery_root).glob('*.json')) if Path(delivery_root).exists() else []
assert records_after_validation == records_before_validation
calls_path = Path(home, 'calls.jsonl')
def send_count():
    return sum(1 for line in calls_path.read_text().splitlines()
               if json.loads(line)['path'].endswith('/sendMessage'))
before_reservation = send_count()
reserved = run('mirror-reserve', 'user-terminal-accepted', '--text-file', terminal_path)
assert reserved.returncode == 0, reserved.stderr
assert send_count() == before_reservation
sent_reservation = run('mirror-reply', 'user-terminal-accepted', '--text-file', terminal_path)
assert sent_reservation.returncode == 0, sent_reservation.stderr
assert send_count() == before_reservation + 1
body = 'Firstmate · ' + ('😀' * 3000)
body_path = os.path.join(home, 'long-reply.txt')
open(body_path, 'w').write(body)
open(os.path.join(home, 'reject-send'), 'w').close()
first = run('mirror-reply', 'delivery-long', '--request-id', request, '--text-file', body_path)
assert first.returncode == 0, first.stderr
second = run('mirror-reply', 'delivery-long', '--request-id', request, '--text-file', body_path)
assert second.returncode == 0, second.stderr
try:
    owner_fields = Path(f'/proc/{owner}/stat').read_text().rsplit(')', 1)[1].split()
    owner_identity = f'proc:{owner}:{owner_fields[19]}'
except OSError:
    owner_started = subprocess.run(
        ['ps', '-o', 'lstart=', '-p', owner], text=True, capture_output=True,
    ).stdout.strip()
    owner_identity = f'ps:{owner}:{owner_started}'
capacity_ids = []
for index in range(255):
    delivery_id = f'capacity-reservation-{index}'
    capacity_ids.append(delivery_id)
    text = f'capacity reservation {index}'
    Path(delivery_root, delivery_id + '.txt').write_text(text)
    Path(delivery_root, delivery_id + '.json').write_text(json.dumps({
        'delivery_id': delivery_id,
        'sha256': __import__('hashlib').sha256(text.encode()).hexdigest(),
        'status': 'reserved', 'created_at': int(time.time()), 'chunks': [],
        'reservation_owner_pid': int(owner),
        'reservation_owner_identity': owner_identity,
    }))
capacity = run('mirror-reserve', 'capacity-overflow', '--text-file', terminal_path)
assert capacity.returncode != 0 and 'no bounded free slot' in capacity.stderr
assert Path(delivery_root, 'delivery-long.json').exists()
complete = run('mirror-complete', request, 'delivery-long')
assert complete.returncode == 0, complete.stderr
completed_delivery = json.loads(Path(delivery_root, 'delivery-long.json').read_text())
assert 'completion_request_id' not in completed_delivery
abandoned_request = 'tg-text-u200-m200'
abandoned_path = Path(home, 'state', 'telegram', 'inbox', abandoned_request + '.json')
abandoned_path.write_text(json.dumps({
    'request_id': abandoned_request, 'origin': 'telegram', 'text': 'undeliverable response',
    'chat_id': 77, 'status': 'claimed', 'created_at': int(time.time()),
    'claim_owner_pid': int(owner), 'claim_owner_identity': owner_identity,
}))
abandoned = run('mirror-abandon', abandoned_request, 'assistant-undeliverable')
assert abandoned.returncode == 0, abandoned.stderr
assert not abandoned_path.exists()
abandoned_record = json.loads(Path(
    home, 'state', 'telegram', 'handled', abandoned_request + '.json'
).read_text())
assert abandoned_record['status'] == 'abandoned'
assert abandoned_record['failure_delivery_id'] == 'assistant-undeliverable'
for delivery_id in capacity_ids:
    Path(delivery_root, delivery_id + '.json').unlink()
    Path(delivery_root, delivery_id + '.txt').unlink()
for path in Path(delivery_root).glob('*'):
    path.unlink()
fallback_request = 'tg-text-u300-m300'
fallback_request_path = Path(home, 'state', 'telegram', 'inbox', fallback_request + '.json')
fallback_request_path.write_text(json.dumps({
    'request_id': fallback_request, 'origin': 'telegram', 'text': 'fallback capacity race',
    'chat_id': 77, 'status': 'claimed', 'created_at': int(time.time()),
    'claim_owner_pid': int(owner), 'claim_owner_identity': owner_identity,
}))
failed_delivery = 'assistant-capacity-rejected'
failed_text = 'Firstmate · rejected before fallback'
Path(delivery_root, failed_delivery + '.txt').write_text(failed_text)
Path(delivery_root, failed_delivery + '.json').write_text(json.dumps({
    'delivery_id': failed_delivery,
    'sha256': __import__('hashlib').sha256(failed_text.encode()).hexdigest(),
    'status': 'rejected', 'created_at': int(time.time()), 'chunks': [],
    'completion_request_id': fallback_request,
}))
fallback_capacity_ids = []
for index in range(255):
    delivery_id = f'fallback-capacity-{index}'
    fallback_capacity_ids.append(delivery_id)
    text = f'protected fallback capacity {index}'
    Path(delivery_root, delivery_id + '.txt').write_text(text)
    Path(delivery_root, delivery_id + '.json').write_text(json.dumps({
        'delivery_id': delivery_id,
        'sha256': __import__('hashlib').sha256(text.encode()).hexdigest(),
        'status': 'reserved', 'created_at': int(time.time()), 'chunks': [],
        'reservation_owner_pid': int(owner),
        'reservation_owner_identity': owner_identity,
    }))
fallback_body_path = Path(home, 'fallback-capacity.txt')
fallback_body_path.write_text('Firstmate · Response could not be mirrored; view it in the terminal.')
fallback_delivery = 'assistant-fallback-capacity'
fallback = run(
    'mirror-reply', fallback_delivery, '--request-id', fallback_request,
    '--text-file', str(fallback_body_path),
)
assert fallback.returncode == 0, fallback.stderr
assert fallback_request_path.exists(), 'fallback admission evicted its live request'
assert not Path(delivery_root, failed_delivery + '.json').exists()
assert not Path(delivery_root, failed_delivery + '.txt').exists()
fallback_record = json.loads(Path(delivery_root, fallback_delivery + '.json').read_text())
assert fallback_record['status'] == 'sent'
assert fallback_record['completion_request_id'] == fallback_request
assert run('mirror-complete', fallback_request, fallback_delivery).returncode == 0
for path in Path(delivery_root).glob('*'):
    path.unlink()
orphan_delivery = 'assistant-orphaned-completion'
orphan_text = 'Firstmate · paired request vanished'
Path(delivery_root, orphan_delivery + '.txt').write_text(orphan_text)
Path(delivery_root, orphan_delivery + '.json').write_text(json.dumps({
    'delivery_id': orphan_delivery,
    'sha256': __import__('hashlib').sha256(orphan_text.encode()).hexdigest(),
    'status': 'sent', 'created_at': int(time.time()), 'chunks': [],
    'completion_request_id': 'tg-text-u301-m301',
}))
orphan_report = run('mirror-reconcile', '--report-delivery', orphan_delivery)
assert orphan_report.returncode == 0, orphan_report.stderr
assert f'request-missing\t{orphan_delivery}\ttg-text-u301-m301' in orphan_report.stdout.splitlines()
Path(delivery_root, orphan_delivery + '.json').unlink()
Path(delivery_root, orphan_delivery + '.txt').unlink()
for index, status in enumerate(('rejected', 'delivery_unknown'), start=201):
    request_id = f'tg-text-u{index}-m{index}'
    request_path = Path(home, 'state', 'telegram', 'inbox', request_id + '.json')
    request_path.write_text(json.dumps({
        'request_id': request_id, 'origin': 'telegram', 'text': 'expired failed response',
        'chat_id': 77, 'status': 'claimed', 'created_at': 1,
        'claim_owner_pid': int(owner), 'claim_owner_identity': owner_identity,
    }))
    delivery_id = f'expired-{status}'
    delivery_text = f'Firstmate · expired {status}'
    Path(delivery_root, delivery_id + '.txt').write_text(delivery_text)
    Path(delivery_root, delivery_id + '.json').write_text(json.dumps({
        'delivery_id': delivery_id,
        'sha256': __import__('hashlib').sha256(delivery_text.encode()).hexdigest(),
        'status': status, 'created_at': 1, 'chunks': [],
        'completion_request_id': request_id,
    }))
    cleaned = run('mirror-reconcile', '--preserve-request', request_id)
    assert cleaned.returncode == 0, cleaned.stderr
    assert not request_path.exists(), f'expired {status} request remained claimed'
    assert not Path(delivery_root, delivery_id + '.json').exists()
    assert not Path(delivery_root, delivery_id + '.txt').exists()
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
python3 - "$home/calls.jsonl" "$home/sent.jsonl" "$home/long-reply.txt" <<'PY' || fail "Telegram response reply chain was malformed"
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
sent = [json.loads(line) for line in open(sys.argv[2])]
body = open(sys.argv[3]).read()
fallback = 'Firstmate · Response could not be mirrored; view it in the terminal.'
chunks = [call['params']['text'] for call in calls if call['path'].endswith('/sendMessage') and call['params']['text'] != fallback and call['params']['text'].startswith(('Firstmate · ', '😀'))]
assert len(chunks) == 3
assert ''.join(chunks[1:]) == body
assert all(len(chunk.encode('utf-16-le')) // 2 <= 4096 for chunk in chunks)
pi = [item for item in sent if item['params'].get('text') == 'Pi · Delivered to Firstmate.'][-1]
assert pi['params']['reply_parameters'] == {'message_id': 3}
chain = [item for item in sent if item['params'].get('text') != fallback and item['params'].get('text', '').startswith(('Firstmate · ', '😀'))]
assert ''.join(item['params']['text'] for item in chain) == body
first_attempt = [call for call in calls if call['path'].endswith('/sendMessage') and call['params'].get('text') == chain[0]['params']['text']][0]
assert first_attempt['params']['reply_parameters'] == {'message_id': 3}
assert 'reply_parameters' not in chain[0]['params']
for previous, current in zip(chain, chain[1:]):
    assert current['params']['reply_parameters'] == {'message_id': previous['message_id']}
PY

# Every bounded reconciliation consumes legacy Telegram wakes, including rows published after migration.
if grep -q $'\ttelegram:' "$home/state/.wake-queue"; then
  fail "legacy Telegram wake survived bounded reconciliation"
fi

race_harness="$TMP_ROOT/mode-admission-race.py"
cat >"$race_harness" <<'PY'
import fcntl, importlib.util, os, subprocess, sys, time
from pathlib import Path

script, home_arg, base, role, kind = sys.argv[1:]
home = Path(home_arg)
ready = home / f'{kind}-race-ready'
result = home / f'{kind}-race-result'
if role == 'child':
    spec = importlib.util.spec_from_file_location('fm_telegram_race', script)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module.configure_test_api_base(home, base)
    config = module.load_config(home)
    ready.write_text('ready\n')
    if kind == 'text':
        handled = module.handle_text(
            home, config, {'text': 'mode race text', 'message_id': 901}, 901,
        )
    else:
        handled = module.handle_voice(home, config, {
            'message_id': 902,
            'voice': {'file_id': 'mode-race-voice', 'duration': 2, 'file_size': 10},
        }, 902)
    result.write_text(repr(handled) + '\n')
    raise SystemExit(0)

mode_path = home / 'config' / 'telegram-mirror'
lock_path = home / 'state' / '.telegram-state.lock'
for target in (ready, result):
    target.unlink(missing_ok=True)
mode_path.write_text('on\n')
with lock_path.open('a+') as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    child = subprocess.Popen([sys.executable, __file__, script, str(home), base, 'child', kind])
    for _ in range(100):
        if ready.exists():
            break
        time.sleep(0.01)
    else:
        child.kill()
        raise AssertionError(f'{kind} admission child did not start')
    time.sleep(0.2)
    temporary = mode_path.with_name(f'.{mode_path.name}.{os.getpid()}')
    temporary.write_text('off\n')
    os.replace(temporary, mode_path)
    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
assert child.wait(timeout=10) == 0
assert result.read_text().strip() == 'True'
if kind == 'text':
    assert not (home / 'state' / 'telegram' / 'inbox' / 'tg-text-u901-m901.json').exists()
else:
    queue = home / 'state' / 'telegram' / 'pending-voice-queue.json'
    if queue.exists():
        import json
        records = json.loads(queue.read_text())
        assert all(item.get('pending_id') != 'voice-u902-m902' for item in records)
PY
base="http://127.0.0.1:$(cat "$home/port")"
"$PYTHON" "$race_harness" "$SCRIPT" "$home" "$base" parent text \
  || fail "mode-off text admission race was not refused atomically"
"$PYTHON" "$race_harness" "$SCRIPT" "$home" "$base" parent voice \
  || fail "mode-off voice admission race was not refused atomically"

pass "Telegram mode, queue, voice, chunked delivery, completion, uncertainty, migration, and admission races"
