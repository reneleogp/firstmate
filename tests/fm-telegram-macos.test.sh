#!/usr/bin/env bash
# Public semantic tests for the macOS LaunchAgent and private audio contract.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-macos)
PYTHON=${PYTHON:-python3}
SCRIPT="$ROOT/bin/fm-telegram.py"
LAUNCHD_DIR="$TMP_ROOT/LaunchAgents"
AUDIO_DIR="$TMP_ROOT/user-tmp"
LAUNCHD_STATE="$TMP_ROOT/launchd-state.json"
FAKE_LAUNCHCTL="$TMP_ROOT/fake-launchctl.py"
FAKE_PLUTIL="$TMP_ROOT/fake-plutil.py"

cat >"$FAKE_LAUNCHCTL" <<'PY'
#!/usr/bin/env python3
import json, plistlib, sys
from pathlib import Path
state_path = Path(__import__('os').environ['FM_FAKE_LAUNCHD_STATE'])
state = json.loads(state_path.read_text()) if state_path.exists() else {'loaded': False, 'active': False}
args = sys.argv[1:]
def save():
    state_path.write_text(json.dumps(state))
def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(113)
if not args:
    fail('missing launchctl command')
command = args[0]
if command == 'bootstrap':
    if state.pop('race_bootstrap_once', False):
        path = Path(args[2]); plistlib.loads(path.read_bytes())
        state.update({'loaded': True, 'active': False, 'path': str(path), 'disabled': False}); save()
        fail('service already bootstrapped')
    if state.get('loaded'):
        fail('service already bootstrapped')
    path = Path(args[2]); plistlib.loads(path.read_bytes())
    state.update({'loaded': True, 'active': False, 'path': str(path), 'disabled': False})
    save()
elif command == 'print':
    if not state.get('loaded'):
        fail('Could not find service')
    print(f"{args[1]} = {{")
    print(f"path = {state['path']}")
    print(f"state = {'running' if state.get('active') else 'exited'}")
    print('}')
elif command == 'kickstart':
    if not state.get('loaded') or state.get('disabled'):
        fail('service is not bootstrapped')
    state['active'] = True; save()
elif command == 'kill':
    if not state.get('loaded'):
        fail('Could not find service')
    state['active'] = False; save()
elif command == 'disable':
    if not state.get('loaded'):
        fail('Could not find service')
    state['disabled'] = True; save()
elif command == 'enable':
    state['disabled'] = False; save()
elif command == 'bootout':
    if state.pop('race_bootout_once', False):
        state['loaded'] = False; state['active'] = False; save()
        fail('Could not find service')
    if not state.get('loaded'):
        fail('Could not find service')
    state['loaded'] = False; state['active'] = False; save()
else:
    fail('unsupported launchctl command')
PY
chmod +x "$FAKE_LAUNCHCTL"

cat >"$FAKE_PLUTIL" <<'PY'
#!/usr/bin/env python3
import plistlib, sys
from pathlib import Path
try:
    plistlib.loads(Path(sys.argv[-1]).read_bytes())
except Exception as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
print('OK')
PY
chmod +x "$FAKE_PLUTIL"
printf '%s\n' '{"loaded":false,"active":false}' >"$LAUNCHD_STATE"

new_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state/telegram/inbox" "$home/state/telegram/handled" \
    "$home/state/telegram/responses" "$home/state/telegram/deliveries"
  printf 'FM_TELEGRAM_BOT_TOKEN=secret-token-never-in-plist\n' >"$home/.env"
  chmod 600 "$home/.env"
  cat >"$home/config/telegram.json" <<'JSON'
{"user_id":77,"chat_id":77,"bot_id":9901}
JSON
  chmod 600 "$home/config/telegram.json"
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
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0')); params = json.loads(self.rfile.read(size) or b'{}')
        method = self.path.rsplit('/', 1)[-1]
        if method == 'getMe': result = {'id': 9901, 'is_bot': True}
        elif method == 'getChat': result = {'id': params.get('chat_id'), 'type': 'private'}
        elif method == 'getUpdates': result = []
        else: result = {}
        body = json.dumps({'ok': True, 'result': result}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
server = HTTPServer(('127.0.0.1', 0), Handler)
(home / 'port').write_text(str(server.server_port)); server.serve_forever()
PY
  SERVER_PID=$!
  for _ in $(seq 1 50); do [ -s "$home/port" ] && return; sleep .02; done
  fail "fake Telegram server did not start"
}

SERVER_PID=
cleanup() { [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT

home="$TMP_ROOT/home<&>"
new_home "$home"
start_server "$home"
export FM_TELEGRAM_PLATFORM=darwin FM_TELEGRAM_LAUNCHD_DIR="$LAUNCHD_DIR"
export FM_TELEGRAM_AUDIO_DIR="$AUDIO_DIR" FM_FAKE_LAUNCHD_STATE="$LAUNCHD_STATE"
export FM_TELEGRAM_LAUNCHCTL="$FAKE_LAUNCHCTL" FM_TELEGRAM_PLUTIL="${FM_TELEGRAM_PLUTIL:-$FAKE_PLUTIL}"
run_tg() { env FM_HOME="$1" "$SCRIPT" --test-api-base "http://127.0.0.1:$(cat "$1/port")" "${@:2}"; }

# Install publishes one validated, owner-only plist with escaped paths and no private values.
run_tg "$home" install >/dev/null || fail "macOS install failed"
plist="$LAUNCHD_DIR/com.reneleogp.firstmate.telegram.plist"
[ -f "$plist" ] || fail "LaunchAgent plist was not published"
"$PYTHON" - "$plist" <<'PY'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
python3 - "$plist" "$home" <<'PY'
import plistlib, sys
value = plistlib.loads(open(sys.argv[1], 'rb').read())
home = sys.argv[2]
assert value['Label'] == 'com.reneleogp.firstmate.telegram'
assert value['ProgramArguments'][2] == '--home' and value['ProgramArguments'][3] == home
assert value['ProgramArguments'][-1] == '--launchd-service'
raw = open(sys.argv[1], 'rb').read()
assert b'secret-token' not in raw and b'9901' not in raw and b'77' not in raw
assert value['EnvironmentVariables'] == {'FM_HOME': home}
PY
run_tg "$home" status >/dev/null || fail "active LaunchAgent status failed"
run_tg "$home" install >/dev/null || fail "already-active install was not idempotent"

# Stop/start exercise SIGTERM, inactive verification, kickstart, and ordered lifecycle state.
run_tg "$home" stop >/dev/null || fail "stop did not verify inactive"
if run_tg "$home" status >/dev/null 2>&1; then fail "inactive status unexpectedly passed"; fi
run_tg "$home" start >/dev/null || fail "kickstart did not reactivate service"
run_tg "$home" disable >/dev/null || fail "disable/bootout failed"
# A verified same-owner bootout/bootstrap race converges without touching a foreign unit.
printf '%s\n' "{\"loaded\":true,\"active\":false,\"path\":\"$plist\",\"race_bootout_once\":true}" >"$LAUNCHD_STATE"
run_tg "$home" install >/dev/null || fail "verified bootout race did not converge"
run_tg "$home" disable >/dev/null || fail "second disable failed"
printf '%s\n' "{\"loaded\":false,\"active\":false,\"race_bootstrap_once\":true}" >"$LAUNCHD_STATE"
run_tg "$home" install >/dev/null || fail "verified bootstrap race did not converge"
run_tg "$home" disable >/dev/null || fail "race cleanup disable failed"
[ ! -e "$home/state/telegram/enabled" ] || fail "disable left transport active"

# Foreign same-label units and malformed plist files are never replaced or booted out.
foreign="$TMP_ROOT/foreign"
new_home "$foreign"
OLD_SERVER_PID=$SERVER_PID
start_server "$foreign"
kill "$OLD_SERVER_PID" 2>/dev/null || true
printf '%s\n' '<not-a-plist>' >"$plist"
printf '%s\n' '{"loaded":false,"active":false}' >"$LAUNCHD_STATE"
if run_tg "$foreign" install >/dev/null 2>&1; then fail "foreign plist was replaced"; fi
[ "$(cat "$plist")" = '<not-a-plist>' ] || fail "malformed foreign plist changed"
printf '%s\n' '{"loaded":true,"active":true,"path":"/other/foreign.plist"}' >"$LAUNCHD_STATE"
rm -f "$plist"
if run_tg "$foreign" cleanup >/dev/null 2>&1; then fail "foreign loaded label was cleaned"; fi

# Crash reconciliation removes orphaned audio while preserving secure active retry audio.
new_home "$TMP_ROOT/audio-home"
audio_home="$TMP_ROOT/audio-home"
OLD_SERVER_PID=$SERVER_PID
start_server "$audio_home"
kill "$OLD_SERVER_PID" 2>/dev/null || true
python3 - "$SCRIPT" "$audio_home" <<'PY'
import importlib.util, os, stat, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('fm_telegram', sys.argv[1]); module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module; spec.loader.exec_module(module)
root = Path(os.environ['FM_TELEGRAM_AUDIO_DIR']); root.mkdir(mode=0o700, parents=True, exist_ok=True); root.chmod(0o700)
path = module.new_audio_path(); fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.close(fd)
assert stat.S_IMODE(path.stat().st_mode) == 0o600 and stat.S_IMODE(root.stat().st_mode) == 0o700
module.remove_audio({'audio_path': str(path)}); assert not path.exists()
stale = module.new_audio_path(); Path(stale).write_bytes(b'crashed'); os.chmod(stale, 0o600)
module.bounded_cleanup(Path(sys.argv[2])); assert not stale.exists()
PY

# Pair-configured absolute commands convert Ogg/Opus without a shell and retry through local Whisper.
cat >"$TMP_ROOT/ffmpeg" <<'SH'
#!/bin/sh
cp "$3" "$8"
SH
cat >"$TMP_ROOT/transcriber" <<'SH'
#!/bin/sh
[ -f "$1" ] || exit 1
printf 'local transcript\n'
SH
chmod +x "$TMP_ROOT/ffmpeg" "$TMP_ROOT/transcriber"
python3 - "$SCRIPT" "$audio_home" "$TMP_ROOT/ffmpeg" "$TMP_ROOT/transcriber" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('fm_telegram', sys.argv[1]); module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module; spec.loader.exec_module(module)
audio = Path(sys.argv[2]) / 'input.oga'; audio.write_bytes(b'ogg-opus')
config = {'ffmpeg_command': sys.argv[3], 'parakeet_command': sys.argv[4], 'whisper_command': sys.argv[4]}
assert module.transcribe(Path(sys.argv[2]), config, audio, 'parakeet') == 'local transcript'
assert not list(Path(sys.argv[2]).glob('firstmate-telegram-*.wav'))
PY

# Cleanup removes the owned plist, private state, and every temporary audio artifact.
printf '%s\n' '{"loaded":false,"active":false}' >"$LAUNCHD_STATE"
run_tg "$audio_home" cleanup >/dev/null || fail "uninstall cleanup failed"
[ ! -e "$plist" ] || fail "cleanup left a LaunchAgent plist"
[ ! -e "$audio_home/state/telegram" ] || fail "cleanup left Telegram state"

pass "macOS LaunchAgent lifecycle, ownership, plist privacy, secure audio, conversion, and cleanup"
