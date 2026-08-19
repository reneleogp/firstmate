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
import json, os, sys
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
            updates = json.loads((home / 'updates.json').read_text()) if (home / 'updates.json').exists() else []
            return self._write(updates)
        return self._write({})
    def do_GET(self):
        if '/file/' in self.path:
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

home=$(new_home basic)
start_server "$home" "$home/port"
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
grep -F 'please inspect this' "$home/state/.wake-queue" >/dev/null && fail "raw Telegram text entered wake queue"
grep -F "telegram tg-" "$home/state/.wake-queue" >/dev/null || fail "wake did not carry local request id"
run_tg "$home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq 1 ] || fail "replayed text must not send a second receipt"
run_tg "$home" request-read "$(basename "$inbox" .json)" > "$home/read.txt"
grep -Fx 'please inspect this' "$home/read.txt" >/dev/null || fail "request-read must expose only queued request text"
run_tg "$home" request-handled "$(basename "$inbox" .json)"
[ ! -f "$inbox" ] || fail "request-handled must move the private request"
printf 'final answer\n' > "$home/reply.txt"
run_tg "$home" reply "$(basename "$inbox" .json)" --text-file "$home/reply.txt" >/dev/null

grep -F 'final answer' "$home/calls.jsonl" >/dev/null || fail "reply must use the pinned chat"

# Unsupported, malformed, and unpinned updates are dropped without a Bot API send.
before=$(grep -c 'sendMessage' "$home/calls.jsonl")
set_updates '[{"update_id":2,"message":{"message_id":11,"from":{"id":999},"chat":{"id":77,"type":"private"},"text":"ignore"}},{"update_id":3,"message":{"message_id":12,"from":{"id":77},"chat":{"id":77,"type":"group"},"text":"ignore"}},{"update_id":4,"message":{"message_id":13,"from":{"id":77},"chat":{"id":77,"type":"private"},"photo":[{"file_id":"must not download"}]}},{"update_id":5,"edited_message":{"message":{"voice":{"file_id":"must not download"}}}}]' "$home"
run_tg "$home" serve --once >/dev/null
[ "$(grep -c 'sendMessage' "$home/calls.jsonl")" -eq "$before" ] || fail "unsupported or unpinned updates must be silent"
! grep -F 'must not download' "$home/calls.jsonl" >/dev/null || fail "unsupported media was downloaded"

# A live primary changes only the deterministic transport wording and does not mirror terminal-originated text.
printf '%s\n' "$$" > "$home/state/.lock"
set_updates '[{"update_id":6,"message":{"message_id":14,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"terminal must not mirror"}}]' "$home"
run_tg "$home" serve --once >/dev/null
grep -F 'Message received.' "$home/calls.jsonl" >/dev/null || fail "live-primary receipt mismatch"
! grep -F 'terminal-originated' "$home/calls.jsonl" >/dev/null || fail "terminal-originated text was mirrored"

# Voice confirm, edit, retry, cancel, expiry, and temporary-audio cleanup.
voice_home=$(new_home voice)
start_server "$voice_home" "$voice_home/port"
cat > "$voice_home/parakeet.sh" <<'SH'
#!/usr/bin/env bash
printf 'parakeet transcript\n'
SH
cat > "$voice_home/whisper.sh" <<'SH'
#!/usr/bin/env bash
printf 'whisper transcript\n'
SH
chmod +x "$voice_home/parakeet.sh" "$voice_home/whisper.sh"
run_tg "$voice_home" pair --user-id 77 --chat-id 77 >/dev/null
python3 - "$voice_home/config/telegram.json" "$voice_home/parakeet.sh" "$voice_home/whisper.sh" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['parakeet_command']=sys.argv[2]; d['whisper_command']=sys.argv[3]; json.dump(d, open(p,'w'))
PY
chmod 600 "$voice_home/config/telegram.json"
set_updates '[{"update_id":20,"message":{"message_id":20,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-1","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
pending="$voice_home/state/telegram/pending.json"
[ -f "$pending" ] || fail "voice note must create pending confirmation"
audio=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["audio_path"])' "$pending")
[ -f "$audio" ] || fail "voice audio must be retained for confirmation"
grep -F 'I heard this:' "$voice_home/calls.jsonl" >/dev/null || fail "voice confirmation heading missing"
grep -F 'Send to Firstmate' "$voice_home/calls.jsonl" >/dev/null || fail "voice controls missing"

set_updates '[{"update_id":21,"callback_query":{"id":"cb-edit","from":{"id":77},"data":"edit:'"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_id"])' "$pending")"'","message":{"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
grep -F 'Reply with the corrected text.' "$voice_home/calls.jsonl" >/dev/null || fail "edit prompt missing"
set_updates '[{"update_id":22,"message":{"message_id":22,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"corrected voice text"}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
grep -F 'corrected voice text' "$voice_home/calls.jsonl" >/dev/null || fail "edit must reconfirm corrected text"

pending_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_id"])' "$pending")
set_updates '[{"update_id":23,"callback_query":{"id":"cb-retry","from":{"id":77},"data":"retry:'"$pending_id"'","message":{"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
grep -F 'whisper transcript' "$voice_home/calls.jsonl" >/dev/null || fail "retry must use Whisper transcript"
set_updates '[{"update_id":24,"callback_query":{"id":"cb-cancel","from":{"id":77},"data":"cancel:'"$pending_id"'","message":{"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$audio" ] || fail "cancel must delete temporary audio"
[ ! -e "$pending" ] || fail "cancel must delete pending state"

# Confirmed voice queues text, while an expired pending record deletes its audio.
set_updates '[{"update_id":25,"message":{"message_id":25,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-2","duration":2,"file_size":20}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
pending_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_id"])' "$pending")
set_updates '[{"update_id":26,"callback_query":{"id":"cb-send","from":{"id":77},"data":"send:'"$pending_id"'","message":{"chat":{"id":77,"type":"private"}}}}]' "$voice_home"
run_tg "$voice_home" serve --once >/dev/null
[ ! -e "$pending" ] || fail "send must clear pending voice state"
find "$voice_home/state/telegram/inbox" -name '*.json' -print -quit | grep . >/dev/null || fail "confirmed voice must queue text"
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

# Service lifecycle and cleanup are scoped to this home and leave .env intact.
unit_dir="$TMP_ROOT/units"; mkdir -p "$unit_dir"
systemctl_fake="$TMP_ROOT/systemctl"
cat > "$systemctl_fake" <<'SH'
#!/usr/bin/env bash
case "$*" in *'is-active'*) printf 'active\n' ;; esac
exit 0
SH
chmod +x "$systemctl_fake"
FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" run_tg "$voice_home" install >/dev/null
[ -f "$unit_dir/firstmate-telegram.service" ] || fail "install must write one user unit"
grep -F "FM_HOME=$voice_home" "$unit_dir/firstmate-telegram.service" >/dev/null || fail "unit must pin one home"
FM_TELEGRAM_SYSTEMCTL="$systemctl_fake" FM_TELEGRAM_UNIT_DIR="$unit_dir" run_tg "$voice_home" cleanup >/dev/null
[ ! -e "$unit_dir/firstmate-telegram.service" ] || fail "cleanup must remove its unit"
[ -e "$voice_home/.env" ] || fail "cleanup must preserve .env"
[ ! -e "$voice_home/state/telegram" ] || fail "cleanup must remove private Telegram state"

grep -F 'test-only-token' "$home/state/.wake-queue" >/dev/null && fail "bot token entered wake data"
pass "Telegram transport pairing, queueing, dedupe, drops, voice flow, safety, and lifecycle behave as specified"
