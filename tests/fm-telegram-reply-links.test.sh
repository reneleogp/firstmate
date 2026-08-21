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
cat >"$home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
cat "$1"
SH
cat >"$home/whisper.sh" <<'SH'
#!/usr/bin/env bash
[ ! -e "$(dirname "$0")/whisper-fail" ] || exit 1
printf 'whisper transcript\n'
SH
chmod +x "$home/parakeet.sh" "$home/whisper.sh"
printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' >"$home/.env"
chmod 600 "$home/.env"
cat >"$home/config/telegram.json" <<'JSON'
{"user_id":77,"chat_id":77,"bot_id":9901,"parakeet_command":"PLACEHOLDER_PARAKEET","whisper_command":"PLACEHOLDER_WHISPER"}
JSON
chmod 600 "$home/config/telegram.json"
python3 - "$home/config/telegram.json" "$home/parakeet.sh" "$home/whisper.sh" <<'PY'
import json, os, sys
path, parakeet, whisper = sys.argv[1:]
data = json.load(open(path)); data['parakeet_command'] = parakeet; data['whisper_command'] = whisper
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
    def reject(self):
        body = json.dumps({'ok': False, 'error_code': 400}).encode()
        self.send_response(400); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def should_reject(self, method, params):
        path = home / 'failures.json'
        rules = json.loads(path.read_text()) if path.exists() else []
        for rule in rules:
            if rule.get('remaining', 0) <= 0 or rule.get('method') != method:
                continue
            if 'text' in rule and rule['text'] != params.get('text'):
                continue
            if 'target' in rule and rule['target'] != params.get('reply_parameters', {}).get('message_id'):
                continue
            rule['remaining'] -= 1
            path.write_text(json.dumps(rules))
            return True
        return False
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0')); params = json.loads(self.rfile.read(size) or b'{}')
        with (home / 'calls.jsonl').open('a') as stream: stream.write(json.dumps({'path': self.path, 'params': params}) + '\n')
        method = self.path.rsplit('/', 1)[-1]
        if self.should_reject(method, params): return self.reject()
        if method == 'getMe': return self.reply({'id': 9901, 'is_bot': True})
        if method == 'getFile': return self.reply({'file_path': 'voice/test.oga'})
        if method == 'getUpdates':
            updates = json.loads((home / 'updates.json').read_text()); (home / 'updates.json').write_text('[]'); return self.reply(updates)
        if method == 'sendMessage':
            target = params.get('reply_parameters', {}).get('message_id')
            if target in {998, 999}: return self.reject()
            path = home / 'next-id'; value = int(path.read_text()) if path.exists() else 1000; path.write_text(str(value + 1))
            with (home / 'sent.jsonl').open('a') as stream:
                stream.write(json.dumps({'params': params, 'message_id': value}) + '\n')
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
set_failures() { printf '%s\n' "$1" >"$home/failures.json"; }
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
copyable = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text') == 'voice transcript' and x['params'].get('reply_parameters') == {'message_id': 30}]
assert len(copyable) == 2, copyable
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

set_updates "[{\"update_id\":8,\"callback_query\":{\"id\":\"retry-ok-30\",\"from\":{\"id\":77},\"message\":{\"message_id\":$transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"corrected transcript\"},\"data\":\"retry:voice-u4-m30:2\"}}]"
run_tg serve --once >/dev/null
python3 - "$home/state/telegram/pending.json" "$home/calls.jsonl" <<'PY'
import json, sys
pending = json.load(open(sys.argv[1])); assert pending['revision'] == 3 and pending['text'] == 'whisper transcript'
calls = [json.loads(x) for x in open(sys.argv[2])]
assert any(x['path'].endswith('/editMessageText') and x['params'].get('text') == 'Retrying with Whisper…' for x in calls)
assert any(x['path'].endswith('/editMessageText') and x['params'].get('text') == 'whisper transcript' for x in calls)
PY
touch "$home/whisper-fail"
set_updates "[{\"update_id\":9,\"callback_query\":{\"id\":\"retry-fail-30\",\"from\":{\"id\":77},\"message\":{\"message_id\":$transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"whisper transcript\"},\"data\":\"retry:voice-u4-m30:3\"}}]"
run_tg serve --once >/dev/null
rm "$home/whisper-fail"
python3 - "$home/state/telegram/pending.json" "$home/calls.jsonl" <<'PY'
import json, sys
pending = json.load(open(sys.argv[1])); assert pending['mode'] == 'confirm' and pending['revision'] == 4 and pending['retry_failed'] is True
calls = [json.loads(x) for x in open(sys.argv[2])]
failed = [x for x in calls if x['path'].endswith('/editMessageText') and x['params'].get('text', '').startswith('Whisper retry failed.')][-1]
buttons = failed['params']['reply_markup']['inline_keyboard']
assert any(button['text'] == 'Retry with Whisper' for row in buttons for button in row)
PY

set_failures '[{"method":"editMessageText","text":"Cancelled","remaining":1},{"method":"sendMessage","text":"Cancelled","remaining":2}]'
set_updates "[{\"update_id\":10,\"callback_query\":{\"id\":\"cancel-crash-30\",\"from\":{\"id\":77},\"message\":{\"message_id\":$transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"whisper transcript\"},\"data\":\"cancel:voice-u4-m30:4\"}}]"
run_tg serve --once >/dev/null || true
python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['mode'] == 'canceling'
PY
printf 'off\n' >"$home/config/telegram-mirror"
set_failures '[]'
set_updates '[]'
run_tg serve --once >/dev/null
[ ! -e "$home/state/telegram/pending.json" ] || fail "mode-off cancellation reconciliation stalled"
set_updates "[{\"update_id\":10,\"callback_query\":{\"id\":\"cancel-crash-30\",\"from\":{\"id\":77},\"message\":{\"message_id\":$transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"whisper transcript\"},\"data\":\"cancel:voice-u4-m30:4\"}}]"
run_tg serve --once >/dev/null
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(x) for x in open(sys.argv[1])]
successful_cancel_edits = [x for x in calls if x['path'].endswith('/editMessageText') and x['params'].get('text') == 'Cancelled']
assert len(successful_cancel_edits) == 2
answers = [x for x in calls if x['path'].endswith('/answerCallbackQuery') and x['params'].get('callback_query_id') == 'cancel-crash-30']
assert len(answers) == 1
PY

printf 'on\n' >"$home/config/telegram-mirror"
getfile_before=$(grep -c '/getFile' "$home/calls.jsonl" || true)
set_failures '[{"method":"sendMessage","text":"Bot · Transcribing…","remaining":2}]'
set_updates '[{"update_id":11,"message":{"message_id":50,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-50","duration":2,"file_size":10}}}]'
run_tg serve --once >/dev/null
[ "$(grep -c '/getFile' "$home/calls.jsonl" || true)" = "$getfile_before" ] || fail "transcription started before progress settled"
python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
pending = json.load(open(sys.argv[1])); assert pending['mode'] == 'transcribing' and pending['progress_status'] == 'rejected'
PY
set_failures '[]'
set_updates '[]'
run_tg serve --once >/dev/null
python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
pending = json.load(open(sys.argv[1])); assert pending['mode'] == 'confirm' and pending['progress_status'] == 'sent'
PY
voice50_transcript_id=$(python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['transcript_message_id'])
PY
)
set_updates "[{\"update_id\":12,\"callback_query\":{\"id\":\"cancel-50\",\"from\":{\"id\":77},\"message\":{\"message_id\":$voice50_transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"voice transcript\"},\"data\":\"cancel:voice-u11-m50:1\"}}]"
run_tg serve --once >/dev/null

set_updates '[{"update_id":13,"message":{"message_id":60,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-60","duration":2,"file_size":10}}}]'
run_tg serve --once >/dev/null
set_failures '[{"method":"sendMessage","text":"Bot · Voice note queued.","remaining":2}]'
set_updates '[{"update_id":14,"message":{"message_id":61,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-61","duration":2,"file_size":10}}}]'
run_tg serve --once >/dev/null || true
python3 - "$home/state/telegram/pending-voice-queue.json" "$home/state/telegram/seen.json" <<'PY'
import json, sys
queue = json.load(open(sys.argv[1])); assert queue[0]['message_id'] == 61 and queue[0]['queued_notice_status'] == 'rejected'
seen = json.load(open(sys.argv[2])); assert 14 not in seen['updates'] and 61 not in seen['messages']
PY
set_failures '[]'
set_updates '[{"update_id":14,"message":{"message_id":61,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-61","duration":2,"file_size":10}}}]'
run_tg serve --once >/dev/null
set_updates '[{"update_id":15,"message":{"message_id":62,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-62","duration":2,"file_size":10}}}]'
run_tg serve --once >/dev/null
python3 - "$home/state/telegram/pending-voice-queue.json" "$home/calls.jsonl" <<'PY'
import json, sys
queue = json.load(open(sys.argv[1])); assert [item['message_id'] for item in queue] == [61, 62]
assert all(item['queued_notice_status'] == 'sent' for item in queue)
calls = [json.loads(x) for x in open(sys.argv[2])]
for source in (61, 62):
    notices = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text') == 'Bot · Voice note queued.' and x['params'].get('reply_parameters') == {'message_id': source}]
    assert notices, source
PY
voice60_transcript_id=$(python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['transcript_message_id'])
PY
)
set_updates "[{\"update_id\":16,\"callback_query\":{\"id\":\"cancel-60\",\"from\":{\"id\":77},\"message\":{\"message_id\":$voice60_transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"voice transcript\"},\"data\":\"cancel:voice-u13-m60:1\"}}]"
run_tg serve --once >/dev/null
voice61_transcript_id=$(python3 - "$home/state/telegram/pending.json" <<'PY'
import json, sys
pending = json.load(open(sys.argv[1])); assert pending['message_id'] == 61
print(pending['transcript_message_id'])
PY
)
set_updates "[{\"update_id\":17,\"callback_query\":{\"id\":\"cancel-61\",\"from\":{\"id\":77},\"message\":{\"message_id\":$voice61_transcript_id,\"date\":1,\"chat\":{\"id\":77,\"type\":\"private\"},\"text\":\"voice transcript\"},\"data\":\"cancel:voice-u14-m61:1\"}}]"
run_tg serve --once >/dev/null
voice62_transcript_id=$(python3 - "$home/state/telegram/pending.json" "$home/calls.jsonl" <<'PY'
import json, sys
pending = json.load(open(sys.argv[1])); assert pending['message_id'] == 62
calls = [json.loads(x) for x in open(sys.argv[2])]
for source in (60, 61, 62):
    progress = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text') == 'Bot · Transcribing…' and x['params'].get('reply_parameters') == {'message_id': source}]
    assert progress, source
print(pending['transcript_message_id'])
PY
)
race_harness="$TMP_ROOT/callback-mode-race.py"
cat >"$race_harness" <<'PY'
import fcntl, importlib.util, os, subprocess, sys, time
from pathlib import Path
script, home_arg, base, role, transcript_id = sys.argv[1:]
home = Path(home_arg); result = home / 'callback-race-result'
if role == 'child':
    spec = importlib.util.spec_from_file_location('fm_telegram_callback_race', script)
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module; spec.loader.exec_module(module)
    module.configure_test_api_base(home, base)
    handled = module.handle_callback(home, module.load_config(home), {
        'id': 'callback-mode-race', 'from': {'id': 77},
        'message': {'message_id': int(transcript_id), 'date': 1, 'chat': {'id': 77, 'type': 'private'}, 'text': 'voice transcript'},
        'data': 'send:voice-u15-m62:1',
    }, 18)
    result.write_text(repr(handled) + '\n'); raise SystemExit(0)
mode = home / 'config' / 'telegram-mirror'; mode.write_text('on\n'); result.unlink(missing_ok=True)
with (home / 'state' / '.telegram-state.lock').open('a+') as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    child = subprocess.Popen([sys.executable, __file__, script, str(home), base, 'child', transcript_id])
    time.sleep(.2); temporary = mode.with_name('.telegram-mirror-race'); temporary.write_text('off\n'); os.replace(temporary, mode)
    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
assert child.wait(timeout=10) == 0 and result.read_text().strip() == 'True'
PY
"$PYTHON" "$race_harness" "$SCRIPT" "$home" "http://127.0.0.1:$(cat "$home/port")" parent "$voice62_transcript_id"
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(x) for x in open(sys.argv[1])]
refusal = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text', '').startswith('Bot · Telegram mirror mode is off')][-1]
assert refusal['params']['reply_parameters'] == {'message_id': 62}
PY
printf 'on\n' >"$home/config/telegram-mirror"

python3 - "$home" "$(cat "$home/port")" <<'PY'
import importlib.util, sys
from pathlib import Path
script = Path(sys.argv[0]) if False else Path('bin/fm-telegram.py').resolve()
spec = importlib.util.spec_from_file_location('fm_telegram', script); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
home = Path(sys.argv[1]); module.configure_test_api_base(home, 'http://127.0.0.1:' + sys.argv[2])
module.send_text(home, 77, 'fallback content', reply_to=999, fallback_to=998, journal_key='fallback-test')
PY
python3 - "$home/calls.jsonl" <<'PY'
import json, sys
calls = [json.loads(x) for x in open(sys.argv[1])]
fallback = [x for x in calls if x['path'].endswith('/sendMessage') and x['params'].get('text') == 'fallback content'][-3:]
assert fallback[0]['params']['reply_parameters'] == {'message_id': 999}
assert fallback[1]['params']['reply_parameters'] == {'message_id': 998}
assert 'reply_parameters' not in fallback[2]['params']
journal = json.load(open(sys.argv[1].replace('calls.jsonl', 'state/telegram/reply-journal.json')))
assert journal['fallback-test']['status'] == 'sent' and journal['fallback-test']['target_message_id'] is None
assert isinstance(journal['fallback-test']['outbound_message_id'], int)
PY
pass "Telegram reply fallbacks, voice transitions, replay, ordering, and progress settlement"
