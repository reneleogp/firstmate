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
unsafe_root = Path(sys.argv[4])
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
external_deliveries = unsafe_root / 'external-deliveries'
external_deliveries.mkdir(parents=True)
delivery_root = Path(home, 'state', 'telegram', 'deliveries')
delivery_root.rmdir()
delivery_root.symlink_to(external_deliveries, target_is_directory=True)
redirected_delivery = run(
    'mirror-reserve', 'user-terminal-redirected', '--text-file', str(reservation_body),
    '--accepted-input',
)
assert redirected_delivery.returncode != 0
assert not list(external_deliveries.iterdir())
delivery_root.unlink()
delivery_root.mkdir(mode=0o700)
external_mode = unsafe_root / 'external-telegram-mirror'
external_mode.write_text('on\\n')
mode_path.unlink()
mode_path.symlink_to(external_mode)
redirected_mode = run('mirror-mode', 'status')
assert redirected_mode.returncode != 0
assert external_mode.read_text() == 'on\\n'
mode_path.unlink()
mode_path.write_text('off\\n')
mode_path.chmod(0o600)
PY
override_config="$TMP_ROOT/override-config"
mkdir -p "$override_config"
printf 'on\n' >"$override_config/telegram-mirror"
FM_CONFIG_OVERRIDE="$override_config" $PYTHON "$owner_script" "$SCRIPT" "$home" \
  "$TMP_ROOT/attacker.py" "$TMP_ROOT/unsafe" \
  || fail "private mirror capability claim/read interface failed"

printf 'off\n' >"$home/config/telegram-mirror"
[ "$(cat "$home/config/telegram-mirror")" = off ] || fail "mode preference did not persist"
[ ! -e "$home/state/telegram/handled/tg-text-u1-m1.json" ] || fail "live mirror claim moved content into a second route"

rm -f "$owner_script"

# Legacy routed records are terminal history, not new Telegram work.
legacy_home="$TMP_ROOT/legacy-home"
mkdir -p "$legacy_home/config" "$legacy_home/state/telegram/inbox" "$legacy_home/state/telegram/handled"
printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' >"$legacy_home/.env"
chmod 600 "$legacy_home/.env"
cat >"$legacy_home/config/telegram.json" <<'JSON'
{"user_id":77,"chat_id":77,"bot_id":9901}
JSON
chmod 600 "$legacy_home/config/telegram.json"
printf 'on\n' >"$legacy_home/config/telegram-mirror"
chmod 600 "$legacy_home/config/telegram-mirror"
python3 - "$legacy_home" <<'PY'
import json, sys, time
from pathlib import Path
home = Path(sys.argv[1]); inbox = home / 'state' / 'telegram' / 'inbox'; handled = home / 'state' / 'telegram' / 'handled'
def write(directory, name, record):
    (directory / (name + '.json')).write_text(json.dumps(record))
base = {'origin': 'telegram', 'chat_id': 77, 'message_id': 9, 'update_id': 9,
        'created_at': int(time.time()), 'text': 'old', 'status': 'queued'}
routed = dict(base, request_id='tg-text-u9-m9', continuation_routing='routed', continuation_routed_at=10, admission_sequence=1)
published = dict(base, request_id='tg-text-u10-m10', work_published=True, admission_sequence=2)
handled_old = dict(base, request_id='tg-text-u11-m11', final_sent=True, admission_sequence=3)
new_a = dict(base, request_id='tg-text-u103-m103', message_id=103, update_id=103, admission_sequence=103)
new_b = dict(base, request_id='tg-text-u106-m106', message_id=106, update_id=106, admission_sequence=106)
write(inbox, 'tg-text-u9-m9', routed); write(inbox, 'tg-text-u10-m10', published)
write(handled, 'tg-text-u11-m11', handled_old); write(inbox, 'tg-text-u103-m103', new_a); write(inbox, 'tg-text-u106-m106', new_b)
PY
legacy_owner="$TMP_ROOT/legacy-owner.py"
cat >"$legacy_owner" <<'PY'
import os, subprocess, sys
from pathlib import Path
script, home = sys.argv[1:]
owner = os.getpid(); Path(home, 'state', '.lock').write_text(str(owner) + '\n')
def run(*args):
    reader, writer = os.pipe(); os.write(writer, b'a' * 64 + b'\n'); os.close(writer)
    try:
        return subprocess.run([script, '--home', home, *args, '--owner-pid', str(owner),
                               '--capability-fd', str(reader)], text=True, capture_output=True,
                              pass_fds=(reader,))
    finally:
        os.close(reader)
opened = run('mirror-open')
assert opened.returncode == 0, opened.stderr
reconciled = run('mirror-reconcile')
assert reconciled.returncode == 0, reconciled.stderr
next_request = run('mirror-next')
assert next_request.returncode == 0 and next_request.stdout.strip() == 'tg-text-u103-m103', next_request.stdout
assert run('mirror-claim', 'tg-text-u103-m103').returncode == 0
read_new = run('mirror-read', 'tg-text-u103-m103')
assert read_new.returncode == 0 and read_new.stdout == 'old'
PY
FM_CONFIG_OVERRIDE="$legacy_home/config" "$PYTHON" "$legacy_owner" "$SCRIPT" "$legacy_home" \
  || fail "legacy Telegram migration regression failed"
[ ! -e "$legacy_home/state/telegram/inbox/tg-text-u9-m9.json" ] || fail "routed legacy request remained injectable"
[ ! -e "$legacy_home/state/telegram/inbox/tg-text-u10-m10.json" ] || fail "published legacy request remained injectable"
[ -e "$legacy_home/state/telegram/handled/tg-text-u9-m9.json" ] || fail "routed legacy request was not retired"
[ -e "$legacy_home/state/telegram/handled/tg-text-u10-m10.json" ] || fail "published legacy request was not retired"
[ -e "$legacy_home/state/telegram/handled/tg-text-u11-m11.json" ] || fail "old handled record disappeared"
[ -e "$legacy_home/state/telegram/inbox/tg-text-u103-m103.json" ] || fail "new queued request was not preserved"
[ -e "$legacy_home/state/telegram/inbox/tg-text-u106-m106.json" ] || fail "second new queued request was not preserved"
pass "bounded mirror queue, mode preference, single-primary claim, and legacy migration"
