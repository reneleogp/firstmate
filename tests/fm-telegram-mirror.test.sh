#!/usr/bin/env bash
# Public-interface regression tests for the bounded Telegram mirror contract.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-mirror)
SCRIPT="$ROOT/bin/fm-telegram.py"
PYTHON=${PYTHON:-python3}

new_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state/telegram/inbox" "$home/state/telegram/handled" "$home/state/telegram/responses"
  printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' >"$home/.env"
  chmod 600 "$home/.env"
  cat >"$home/config/telegram.json" <<'JSON'
{"user_id":77,"chat_id":77,"bot_id":9901}
JSON
  chmod 600 "$home/config/telegram.json"
}

home="$TMP_ROOT/home"
new_home "$home"
printf 'on\n' >"$home/config/telegram-mirror"
chmod 600 "$home/config/telegram-mirror"
printf '%s\n' '{"request_id":"tg-text-u1-m1","origin":"telegram","text":"same text","chat_id":77,"status":"queued"}' >"$home/state/telegram/inbox/tg-text-u1-m1.json"

if FM_HOME="$home" "$SCRIPT" mirror-next --owner-pid "$$" --capability-fd 3 3</dev/null >/dev/null 2>&1; then
  fail "mirror queue access succeeded without an opened extension capability"
fi
cat >"$TMP_ROOT/attacker.py" <<'PY'
import os, subprocess, sys
script, home = sys.argv[1:]
reader, writer = os.pipe()
os.write(writer, b'c' * 64 + b'\n'); os.close(writer)
try:
    result = subprocess.run(
        [script, '--home', home, 'mirror-open', '--owner-pid', str(os.getpid()),
         '--capability-fd', str(reader)], pass_fds=(reader,), capture_output=True,
    )
finally:
    os.close(reader)
raise SystemExit(result.returncode)
PY
owner_script="$TMP_ROOT/owner.py"
cat >"$owner_script" <<PY
import json, os, subprocess, sys
from pathlib import Path
script = sys.argv[1]; home = sys.argv[2]; attacker = sys.argv[3]
owner = os.getpid(); capability = b'a' * 64 + b'\\n'
Path(home, 'state', '.lock').write_text(str(owner) + '\\n')
mode_path = Path(home, 'config', 'telegram-mirror')
def run(*args):
    reader, writer = os.pipe()
    os.write(writer, capability); os.close(writer)
    try:
        return subprocess.run(
            [script, '--home', home, *args, '--owner-pid', str(owner),
             '--capability-fd', str(reader)], text=True, capture_output=True,
            pass_fds=(reader,),
        )
    finally:
        os.close(reader)
opened = run('mirror-open')
assert opened.returncode == 0, opened.stderr
stolen = subprocess.run([sys.executable, attacker, script, home])
assert stolen.returncode != 0
next_request = run('mirror-next')
assert next_request.returncode == 0 and next_request.stdout.strip() == 'tg-text-u1-m1'
claimed = run('mirror-claim', 'tg-text-u1-m1')
assert claimed.returncode == 0, claimed.stderr
body = run('mirror-read', 'tg-text-u1-m1')
assert body.returncode == 0 and body.stdout == 'same text'
reservation_body = Path(home, 'terminal-reservation.txt')
reservation_body.write_text('You · Terminal\\n\\nreserved only')
reserved = run('mirror-reserve', 'user-terminal-reserved', '--text-file', str(reservation_body))
assert reserved.returncode == 0, reserved.stderr
reservation = Path(home, 'state', 'telegram', 'deliveries', 'user-terminal-reserved.json')
assert json.loads(reservation.read_text())['status'] == 'reserved'
reported = run(
    'mirror-reconcile', '--preserve-request', 'tg-text-u1-m1',
    '--report-delivery', 'user-terminal-reserved',
)
assert reported.returncode == 0, reported.stderr
assert 'delivery\tuser-terminal-reserved\treserved' in reported.stdout.splitlines()
assert run('mirror-cancel', 'user-terminal-reserved').returncode == 0
assert not reservation.exists()
missing = run(
    'mirror-reconcile', '--preserve-request', 'tg-text-u1-m1',
    '--report-delivery', 'user-terminal-reserved',
)
assert missing.returncode == 0, missing.stderr
assert 'delivery-missing\tuser-terminal-reserved' in missing.stdout.splitlines()
second = Path(home, 'state', 'telegram', 'inbox', 'tg-text-u2-m2.json')
second.write_text('{"request_id":"tg-text-u2-m2","origin":"telegram","text":"off","status":"queued"}')
mode_path.write_text('off\\n')
refused = run('mirror-claim', 'tg-text-u2-m2')
assert refused.returncode != 0 and 'mode is off' in refused.stderr
refused_reservation = run(
    'mirror-reserve', 'user-terminal-mode-off', '--text-file', str(reservation_body),
)
assert refused_reservation.returncode != 0 and 'mode is off' in refused_reservation.stderr
PY
override_config="$TMP_ROOT/override-config"
mkdir -p "$override_config"
printf 'on\n' >"$override_config/telegram-mirror"
FM_CONFIG_OVERRIDE="$override_config" $PYTHON "$owner_script" "$SCRIPT" "$home" "$TMP_ROOT/attacker.py" \
  || fail "private mirror capability claim/read interface failed"

printf 'off\n' >"$home/config/telegram-mirror"
[ "$(cat "$home/config/telegram-mirror")" = off ] || fail "mode preference did not persist"
[ ! -e "$home/state/telegram/handled/tg-text-u1-m1.json" ] || fail "live mirror claim moved content into a second route"

rm -f "$owner_script"
pass "bounded mirror queue, mode preference, and single-primary claim interface"
