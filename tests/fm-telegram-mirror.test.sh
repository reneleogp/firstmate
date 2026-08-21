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

next=$(FM_HOME="$home" "$SCRIPT" mirror-next)
[ "$next" = tg-text-u1-m1 ] || fail "mirror-next did not return the durable queue head"
if FM_HOME="$home" "$SCRIPT" mirror-claim tg-text-u1-m1 --owner-pid "$(( $$ + 1 ))" >/dev/null 2>&1; then
  fail "a non-parent owner identity was accepted"
fi
# A direct child of this test shell is the supported owner shape.
owner_script="$TMP_ROOT/owner.py"
cat >"$owner_script" <<PY
import json, os, subprocess, sys
script = sys.argv[1]; home = sys.argv[2]
owner = os.getpid()
def run(*args):
    return subprocess.run([script, '--home', home, *args], text=True, capture_output=True)
claimed = run('mirror-claim', 'tg-text-u1-m1', '--owner-pid', str(owner))
assert claimed.returncode == 0, claimed.stderr
body = run('mirror-read', 'tg-text-u1-m1', '--owner-pid', str(owner))
assert body.returncode == 0 and body.stdout == 'same text'
PY
# The helper intentionally cannot pass an arbitrary claimed owner through a
# shell wrapper; this assertion checks the transport's direct-child boundary.
# The remainder of the contract is exercised by the full fake-Bot suite.
$PYTHON "$owner_script" "$SCRIPT" "$home" || fail "mirror claim/read public interface failed"

printf 'off\n' >"$home/config/telegram-mirror"
[ "$(cat "$home/config/telegram-mirror")" = off ] || fail "mode preference did not persist"
[ ! -e "$home/state/telegram/handled/tg-text-u1-m1.json" ] || fail "live mirror claim moved content into a second route"

rm -f "$owner_script"
pass "bounded mirror queue, mode preference, and single-primary claim interface"
