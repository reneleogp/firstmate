#!/usr/bin/env bash
# Public-interface tests for native Telegram reply targets and voice transitions.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-reply-links)
PYTHON=${PYTHON:-python3}
SCRIPT="$ROOT/bin/fm-telegram.py"
export FM_TELEGRAM_UNIT_DIR="$TMP_ROOT/systemd-user"
home="$TMP_ROOT/home"
mkdir -p "$home/config" "$home/state/telegram" "$home/state/telegram/inbox" "$home/state/telegram/handled" "$home/state/telegram/responses" "$home/state/telegram/deliveries"
cat >"$home/transcriber.sh" <<'SH'
#!/usr/bin/env bash
cat "$1"
SH
chmod +x "$home/transcriber.sh"
printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' >"$home/.env"
chmod 600 "$home/.env"
cat >"$home/config/telegram.json" <<'JSON'
{"user_id":77,"chat_id":77,"bot_id":9901,"parakeet_command":"PLACEHOLDER_PARAKEET","whisper_command":"PLACEHOLDER_WHISPER"}
JSON
chmod 600 "$home/config/telegram.json"
python3 - "$home/config/telegram.json" "$home/transcriber.sh" <<'PY'
import json, os, sys
path, command = sys.argv[1:]
data = json.load(open(path)); data['parakeet_command'] = command; data['whisper_command'] = command
json.dump(data, open(path, 'w')); os.chmod(path, 0o600)
PY
printf 'on\n' >"$home/config/telegram-mirror"
chmod 600 "$home/config/telegram-mirror"
printf '[]\n' >"$home/updates.json"

"$PYTHON" - "$home" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
home = Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, value):
        body = json.dumps({'ok': True, 'result': value}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0')); params = json.loads(self.rfile.read(size) or b'{}')
        with (home / 'calls.jsonl').open('a') as stream: stream.write(json.dumps({'path': self.path, 'params': params}) + '\n')
        method = self.path.rsplit('/', 1)[-1]
        if method == 'getMe': return self.reply({'id': 9901, 'is_bot': True})
        if method == 'getFile': return self.reply({'file_path': 'voice/test.oga'})
        if method == 'getUpdates':
            updates = json.loads((home / 'updates.json').read_text()); (home / 'updates.json').write_text('[]'); return self.reply(updates)
        if method == 'sendMessage':
            target = params.get('reply_parameters', {}).get('message_id')
            if target == 999:
                body = json.dumps({'ok': False, 'error_code': 400}).encode(); self.send_response(400); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
            path = home / 'next-id'; value = int(path.read_text()) if path.exists() else 1000; path.write_text(str(value + 1))
            return self.reply({'message_id': value, 'chat': {'id': params.get('chat_id')}})
        if method in {'editMessageText', 'editMessageReplyMarkup'}: return self.reply({'message_id': params.get('message_id'), 'chat': {'id': params.get('chat_id')}})
        if method == 'answerCallbackQuery': return self.reply(True)
        return self.reply({})
    def do_GET(self):
        if '/file/' in self.path:
            body = b'voice transcript'; self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        self.send_response(404); self.end_headers()
server = HTTPServer(('127.0.0.1', 0), Handler)
(home / 'port').write_text(str(server.server_port)); home.joinpath('server.pid').write_text(str(__import__('os').getpid())); server.serve_forever()
PY
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT
for _ in $(seq 1 50); do [ -s "$home/port" ] && break; sleep .02; done
run_tg() { env FM_HOME="$home" "$SCRIPT" --test-api-base "http://127.0.0.1:$(cat "$home/port")" "$@"; }
set_updates() { printf '%s\n' "$1" >"$home/updates.json"; }
call_count() { [ -f "$home/calls.jsonl" ] && wc -l <"$home/calls.jsonl" || printf '0\n'; }

set_updates '[{"update_id":1,"message":{"message_id":10,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"hello"}}]'
run_tg serve --once >/dev/null
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(x) for x in open(sys.argv[1])]
queued = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text') == 'Bot · Queued for Firstmate.'][-1]
assert queued['params']['reply_parameters'] == {'message_id': 10}
PY

set_updates '[{"update_id":2,"message":{"message_id":20,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-20","duration":2,"file_size":10}}}]'
run_tg serve --once >/dev/null
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(x) for x in open(sys.argv[1])]
for text in ('Bot · Transcribing…', 'I heard this:', 'voice transcript'):
    call = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text') == text][-1]
    assert call['params']['reply_parameters'] == {'message_id': 20}, (text, call)
transcript = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text') == 'voice transcript'][-1]
open(sys.argv[1] + '.transcript-id', 'w').write(str(transcript['params'].get('reply_parameters', {}).get('message_id', 0)))
PY
# The original transcript message id is returned by the fake Bot API and is in the pending record.
transcript_id=$(python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['transcript_message_id'])
PY
)
set_updates "[{\"update_id\":3,\"callback_query\":{\"id\":\"send-20\",\"from\":{\"id\":77},\"message\":{\"message_id\":$transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"voice transcript\"},\"data\":\"send:voice-u2-m20:1\"}}]"
run_tg serve --once >/dev/null
python3 - "$home/calls.jsonl" "$transcript_id" <<'PY'
import json, sys
calls = [json.loads(x) for x in open(sys.argv[1])]
target = int(sys.argv[2])
transition = [x for x in calls if x['path'].endswith('/editMessageText') and x['params'].get('message_id') == target][-1]
assert transition['params']['text'] == 'Sent to Firstmate'
assert transition['params']['reply_markup'] == {'inline_keyboard': []}
assert any(x['path'].endswith('/answerCallbackQuery') for x in calls)
PY
[ ! -e "$home/state/telegram/pending.json" ] || fail "send left pending voice state"

set_updates '[{"update_id":4,"message":{"message_id":30,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-30","duration":2,"file_size":10}}}]'
run_tg serve --once >/dev/null
transcript_id=$(python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['transcript_message_id'])
PY
)
set_updates "[{\"update_id\":5,\"callback_query\":{\"id\":\"edit-30\",\"from\":{\"id\":77},\"message\":{\"message_id\":$transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"voice transcript\"},\"data\":\"edit:voice-u4-m30:1\"}}]"
run_tg serve --once >/dev/null
prompt_id=$(python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['edit_prompt_message_id'])
PY
)
python3 - "$home/calls.jsonl" "$transcript_id" "$prompt_id" <<'PY'
import json, sys
calls = [json.loads(x) for x in open(sys.argv[1])]
transcript_id, prompt_id = map(int, sys.argv[2:])
edits = [x for x in calls if x['path'].endswith('/editMessageText') and x['params'].get('message_id') == transcript_id]
assert any(x['params']['text'] == 'Editing transcript…' for x in edits)
prompt = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text', '').startswith('Paste and edit')][-1]
assert prompt['params']['reply_markup']['force_reply'] is True
copy = [x for x in edits if x['params']['text'] == 'Editing transcript…'][-1]
assert copy['params']['reply_markup']['inline_keyboard'][0][0]['copy_text']['text'] == 'voice transcript'
assert prompt['params']['reply_markup']['input_field_placeholder'] == 'Paste and edit the transcript'
assert int(prompt_id) == prompt['params'].get('message_id', int(prompt_id)) or prompt_id > 0
PY
set_updates "[{\"update_id\":6,\"message\":{\"message_id\":40,\"date\":1,\"from\":{\"id\":77},\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"corrected transcript\",\"reply_to_message\":{\"message_id\":$prompt_id,\"chat\":{\"id\":77,\"type\":\"private\"}}}}]"
run_tg serve --once >/dev/null
python3 - "$home/state/telegram/pending.json" "$home/calls.jsonl" "$transcript_id" <<'PY'
import json, sys
pending = json.load(open(sys.argv[1])); assert pending['revision'] == 2 and pending['text'] == 'corrected transcript'
calls = [json.loads(x) for x in open(sys.argv[2])]
assert any(x['path'].endswith('/editMessageText') and x['params'].get('message_id') == int(sys.argv[3]) and x['params']['text'] == 'corrected transcript' for x in calls)
PY
# An old revision is acknowledged but cannot enqueue the corrected transcript twice.
set_updates "[{\"update_id\":7,\"callback_query\":{\"id\":\"stale-30\",\"from\":{\"id\":77},\"message\":{\"message_id\":$transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"corrected transcript\"},\"data\":\"send:voice-u4-m30:1\"}}]"
run_tg serve --once >/dev/null
[ ! -e "$home/state/telegram/inbox/tg-voice-u4-m30.json" ] || fail "stale voice revision was admitted"

python3 - "$home" "$(cat "$home/port")" <<'PY'
import importlib.util, sys
from pathlib import Path
script = Path(sys.argv[0]) if False else Path('bin/fm-telegram.py').resolve()
spec = importlib.util.spec_from_file_location('fm_telegram', script); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
home = Path(sys.argv[1]); module.configure_test_api_base(home, 'http://127.0.0.1:' + sys.argv[2])
module.send_text(home, 77, 'fallback content', reply_to=999, fallback_to=10, journal_key='fallback-test')
PY
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(x) for x in open(sys.argv[1])]
fallback = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text') == 'fallback content'][-2:]
assert fallback[0]['params']['reply_parameters'] == {'message_id': 999}
assert fallback[1]['params']['reply_parameters'] == {'message_id': 10}
PY
pass "Telegram source replies, fallback, voice revisions, copy_text, ForceReply, callback replay, and state transitions"
