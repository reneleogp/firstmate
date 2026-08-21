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
FAKE_LAUNCHD_SERVICE="$TMP_ROOT/fake-launchd-service.py"
FAKE_PLUTIL="$TMP_ROOT/fake-plutil.py"

cat >"$FAKE_LAUNCHD_SERVICE" <<'PY'
#!/usr/bin/env python3
import fcntl, os, signal, sys, time
from pathlib import Path
home = Path(sys.argv[1])
launchd_dir = Path(sys.argv[2])
stopping = False
def stop(*_):
    global stopping
    stopping = True
signal.signal(signal.SIGTERM, stop)
streams = []
def acquire(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    stream = path.open('a+')
    os.chmod(path, 0o600)
    while not stopping:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            streams.append(stream)
            return True
        except BlockingIOError:
            time.sleep(0.02)
    stream.close()
    return False
pid_path = home / 'fake-service.pid'
ready_path = home / 'fake-service-ready'
enabled = home / 'state' / 'telegram' / 'enabled'
activation = home / 'state' / '.telegram-service-activation'
try:
    pid_path.write_text(str(os.getpid()))
    if not acquire(launchd_dir / '.firstmate-telegram-service.lock'):
        raise SystemExit(0)
    if not acquire(home / 'state' / '.telegram-service.lock'):
        raise SystemExit(0)
    if not acquire(home / 'state' / '.telegram-lifecycle.lock'):
        raise SystemExit(0)
    deadline = time.monotonic() + 0.2
    while not stopping and time.monotonic() < deadline:
        time.sleep(0.01)
    if stopping:
        raise SystemExit(0)
    enabled.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = enabled.with_name('.enabled.fake')
    temporary.write_text('enabled\n')
    os.chmod(temporary, 0o600)
    os.replace(temporary, enabled)
    try:
        activation.unlink()
    except FileNotFoundError:
        pass
    lifecycle_stream = streams.pop()
    fcntl.flock(lifecycle_stream.fileno(), fcntl.LOCK_UN)
    lifecycle_stream.close()
    ready_path.write_text('ready\n')
    while not stopping:
        time.sleep(0.02)
finally:
    for path in (ready_path, enabled, pid_path):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
PY
chmod +x "$FAKE_LAUNCHD_SERVICE"

cat >"$FAKE_LAUNCHCTL" <<'PY'
#!/usr/bin/env python3
import json, os, plistlib, signal, subprocess, sys, time
from pathlib import Path
state_path = Path(os.environ['FM_FAKE_LAUNCHD_STATE'])
state = json.loads(state_path.read_text()) if state_path.exists() else {'loaded': False, 'active': False}
args = sys.argv[1:]
def save():
    state_path.write_text(json.dumps(state))
def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(113)
def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False
def child_running():
    pid = state.get('pid')
    pid_path = Path(state.get('home', '/')) / 'fake-service.pid'
    if not alive(pid):
        return False
    try:
        return int(pid_path.read_text()) == int(pid)
    except (OSError, TypeError, ValueError):
        return time.monotonic() - float(state.get('started_at', 0)) < 1

def stop_child():
    pid = state.get('pid')
    if alive(pid):
        os.kill(int(pid), signal.SIGTERM)
def refresh():
    if state.get('active') and not child_running():
        state['active'] = False
        state.pop('pid', None)
if not args:
    fail('missing launchctl command')
command = args[0]
refresh()
if command == 'bootstrap':
    path = Path(args[2]); value = plistlib.loads(path.read_bytes())
    if state.pop('race_bootstrap_once', False):
        state.update({'loaded': True, 'active': False, 'path': str(path), 'home': value['EnvironmentVariables']['FM_HOME'], 'disabled': False}); save()
        fail('service already bootstrapped')
    if state.get('loaded'):
        fail('service already bootstrapped')
    state.update({'loaded': True, 'active': False, 'path': str(path), 'home': value['EnvironmentVariables']['FM_HOME'], 'disabled': False})
    save()
elif command == 'print':
    remaining = int(state.get('kill_checks_remaining', 0))
    if remaining > 0:
        remaining -= 1
        state['kill_checks_remaining'] = remaining
        if remaining == 0:
            stop_child()
        save()
    refresh()
    if not state.get('loaded'):
        fail('Could not find service')
    print(f"{args[1]} = {{")
    print(f"path = {state['path']}")
    print(f"state = {'running' if state.get('active') else 'exited'}")
    if state.get('active'):
        print(f"pid = {state['pid']}")
    print('}')
elif command == 'kickstart':
    if not state.get('loaded') or state.get('disabled'):
        fail('service is not bootstrapped')
    stop_child()
    deadline = time.monotonic() + 2
    while child_running() and time.monotonic() < deadline:
        time.sleep(0.02)
    process = subprocess.Popen(
        [os.environ['FM_FAKE_LAUNCHD_SERVICE'], state['home'], str(Path(state['path']).parent)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    state.update({'active': True, 'pid': process.pid, 'started_at': time.monotonic()})
    state.pop('kill_checks_remaining', None)
    save()
elif command == 'kill':
    if not state.get('loaded'):
        fail('Could not find service')
    state['kill_checks_remaining'] = 2
    save()
elif command == 'disable':
    if not state.get('loaded'):
        fail('Could not find service')
    state['disabled'] = True; save()
elif command == 'enable':
    state['disabled'] = False; save()
elif command == 'bootout':
    if state.pop('race_bootout_once', False):
        stop_child(); state['loaded'] = False; state['active'] = False; state.pop('pid', None); save()
        fail('Could not find service')
    if not state.get('loaded'):
        fail('Could not find service')
    stop_child(); state['loaded'] = False; state['active'] = False; state.pop('pid', None); save()
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
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  if [ -d "$TMP_ROOT" ]; then
    while IFS= read -r pid_file; do
      kill "$(cat "$pid_file")" 2>/dev/null || true
    done < <(find "$TMP_ROOT" -name fake-service.pid -type f 2>/dev/null)
  fi
  fm_test_cleanup
}
trap cleanup EXIT

home="$TMP_ROOT/home<&>"
new_home "$home"
start_server "$home"
export FM_TELEGRAM_PLATFORM=darwin FM_TELEGRAM_LAUNCHD_DIR="$LAUNCHD_DIR"
export FM_TELEGRAM_AUDIO_DIR="$AUDIO_DIR" FM_FAKE_LAUNCHD_STATE="$LAUNCHD_STATE"
export FM_TELEGRAM_LAUNCHCTL="$FAKE_LAUNCHCTL" FM_FAKE_LAUNCHD_SERVICE="$FAKE_LAUNCHD_SERVICE"
export FM_TELEGRAM_PLUTIL="${FM_TELEGRAM_PLUTIL:-$FAKE_PLUTIL}"
run_tg() { env FM_HOME="$1" "$SCRIPT" --test-api-base "http://127.0.0.1:$(cat "$1/port")" "${@:2}"; }

# Install publishes one validated, owner-only plist with escaped paths and no private values.
run_tg "$home" install >/dev/null || fail "macOS install failed"
[ -f "$home/fake-service-ready" ] || fail "install returned before child readiness"
[ ! -e "$home/state/.telegram-service-activation" ] || fail "child did not consume activation"
[ -f "$home/state/telegram/enabled" ] || fail "child did not publish transport readiness"
plist="$LAUNCHD_DIR/com.reneleogp.firstmate.telegram.plist"
[ -f "$plist" ] || fail "LaunchAgent plist was not published"
"$PYTHON" - "$plist" <<'PY' || fail "LaunchAgent permissions were not private"
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
python3 - "$plist" "$home" <<'PY' || fail "LaunchAgent contents were unsafe"
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

# Pair-configured absolute commands convert Ogg/Opus without a shell and retry through local Whisper.
new_home "$TMP_ROOT/audio-home"
audio_home="$TMP_ROOT/audio-home"
OLD_SERVER_PID=$SERVER_PID
start_server "$audio_home"
kill "$OLD_SERVER_PID" 2>/dev/null || true
cat >"$TMP_ROOT/ffmpeg" <<'SH'
#!/bin/sh
[ "$(cat "$3")" = 'ogg-opus' ] || exit 2
printf 'converted-pcm\n' >"$7"
SH
cat >"$TMP_ROOT/parakeet" <<'SH'
#!/bin/sh
[ "$(cat "$1")" = 'converted-pcm' ] || exit 2
printf 'parakeet converted\n'
printf 'parakeet\n' >>"$FM_TRANSCRIBER_LOG"
SH
cat >"$TMP_ROOT/whisper" <<'SH'
#!/bin/sh
[ "$(cat "$1")" = 'converted-pcm' ] || exit 2
printf 'whisper converted\n'
printf 'whisper\n' >>"$FM_TRANSCRIBER_LOG"
SH
chmod +x "$TMP_ROOT/ffmpeg" "$TMP_ROOT/parakeet" "$TMP_ROOT/whisper"
export FM_TRANSCRIBER_LOG="$TMP_ROOT/transcriber.log"
printf '%s\n' '{"loaded":false,"active":false}' >"$LAUNCHD_STATE"
run_tg "$audio_home" pair --user-id 77 --chat-id 77 \
  --ffmpeg-command "$TMP_ROOT/ffmpeg" >/dev/null || fail "independent FFmpeg pairing failed"
run_tg "$audio_home" pair --user-id 77 --chat-id 77 \
  --parakeet-command "$TMP_ROOT/parakeet" --whisper-command "$TMP_ROOT/whisper" \
  >/dev/null || fail "transcriber pairing failed"
python3 - "$SCRIPT" "$audio_home" "$TMP_ROOT/ffmpeg" "$TMP_ROOT/parakeet" "$TMP_ROOT/whisper" <<'PY' || fail "audio retry state setup failed"
import importlib.util, json, os, stat, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('fm_telegram', sys.argv[1]); module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module; spec.loader.exec_module(module)
home = Path(sys.argv[2])
config = json.loads((home / 'config' / 'telegram.json').read_text())
assert config['ffmpeg_command'] == sys.argv[3]
assert config['parakeet_command'] == sys.argv[4]
assert config['whisper_command'] == sys.argv[5]
root = Path(os.environ['FM_TELEGRAM_AUDIO_DIR'])
root.mkdir(mode=0o700, parents=True, exist_ok=True); root.chmod(0o700)
audio = home / 'input.oga'; audio.write_bytes(b'ogg-opus')
assert module.transcribe(home, config, audio, 'parakeet') == 'parakeet converted'
assert not list(home.glob('firstmate-telegram-*.wav'))
active = module.new_audio_path(); active.write_bytes(b'ogg-opus'); os.chmod(active, 0o600)
stale = module.new_audio_path(); stale.write_bytes(b'crashed'); os.chmod(stale, 0o600)
assert stat.S_IMODE(active.stat().st_mode) == 0o600
assert stat.S_IMODE(root.stat().st_mode) == 0o700
pending = {
    'pending_id': 'voice-u5-m6', 'mode': 'retry', 'audio_path': str(active),
    'chat_id': 77, 'message_id': 6, 'update_id': 5,
    'created_at': module.now(), 'queued_at': module.now(), 'revision': 1,
    'completed_actions': ['retry-token'], 'retry_token': 'retry-token', 'text': 'old',
}
module.save_pending(home, pending)
module.set_mirror_mode(home, True)
(home / 'active-audio-path').write_text(str(active))
(home / 'stale-audio-path').write_text(str(stale))
PY
run_tg "$audio_home" serve --once --poll-timeout 0 >/dev/null || fail "crash retry replay failed"
python3 - "$audio_home" "$FM_TRANSCRIBER_LOG" <<'PY' || fail "Whisper retry replay was not preserved"
import json, sys
from pathlib import Path
home = Path(sys.argv[1])
pending = json.loads((home / 'state' / 'telegram' / 'pending.json').read_text())
active = Path((home / 'active-audio-path').read_text())
stale = Path((home / 'stale-audio-path').read_text())
assert pending['mode'] == 'confirm' and pending['revision'] == 2
assert pending['text'] == 'whisper converted'
assert active.is_file() and not stale.exists()
assert Path(sys.argv[2]).read_text().splitlines() == ['parakeet', 'whisper']
PY

# Cleanup removes the owned plist, private state, and every temporary audio artifact.
printf '%s\n' '{"loaded":false,"active":false}' >"$LAUNCHD_STATE"
active_audio=$(cat "$audio_home/active-audio-path")
run_tg "$audio_home" cleanup >/dev/null || fail "uninstall cleanup failed"
[ ! -e "$plist" ] || fail "cleanup left a LaunchAgent plist"
[ ! -e "$audio_home/state/telegram" ] || fail "cleanup left Telegram state"
[ ! -e "$active_audio" ] || fail "cleanup left retry audio"

pass "macOS LaunchAgent lifecycle, ownership, plist privacy, secure audio, conversion, and cleanup"
