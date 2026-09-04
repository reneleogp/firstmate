#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/bin/fm-parent-channel-lib.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-parent-channel.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

valid="$TMP/valid.status"
printf '%s' 'done [corr=ABCDEF0123456789]: old event\ndone: [key=api-shape] old keyed event\nfailed: old failure\n' > "$valid"
fm_parent_channel_append_once "$valid" 'working: current event'
[ "$(cat "$valid")" = $'done [corr=ABCDEF0123456789]: old event\ndone: [key=api-shape] old keyed event\nfailed: old failure\nworking: current event' ]
[ "$(cat "$valid.legacy-backup")" = 'done [corr=ABCDEF0123456789]: old event\ndone: [key=api-shape] old keyed event\nfailed: old failure\n' ]
fm_parent_channel_append_once "$valid" 'working: current event'
[ "$(grep -c '^working: current event$' "$valid")" -eq 1 ]

malformed="$TMP/malformed.status"
printf '%s' 'doneevil: arbitrary\\n' > "$malformed"
cp "$malformed" "$TMP/malformed.before"
if fm_parent_channel_append_once "$malformed" 'working: ignored' 2>"$TMP/malformed.err"; then
  printf '%s\n' 'malformed framing unexpectedly succeeded' >&2
  exit 1
fi
cmp -s "$malformed" "$TMP/malformed.before"
grep -q 'invalid framing' "$TMP/malformed.err"

current="$TMP/current.status"
printf '%s\n' 'done: current event' > "$current"
fm_parent_channel_append_once "$current" 'failed: another event'
[ ! -e "$current.legacy-backup" ]

ambiguous="$TMP/ambiguous.status"
printf '%s\n' 'done: one\nfailed: two' > "$ambiguous"
cp "$ambiguous" "$TMP/ambiguous.before"
if fm_parent_channel_append_once "$ambiguous" 'working: ignored' 2>"$TMP/ambiguous.err"; then
  fail='ambiguous framing unexpectedly succeeded'
  printf '%s\n' "$fail" >&2
  exit 1
fi
cmp -s "$ambiguous" "$TMP/ambiguous.before"
grep -q 'ambiguous framing' "$TMP/ambiguous.err"

invalid="$TMP/invalid.status"
printf '%s' 'not-a-record\n' > "$invalid"
cp "$invalid" "$TMP/invalid.before"
if fm_parent_channel_append_once "$invalid" 'working: appended separately' 2>"$TMP/invalid.err"; then
  printf '%s\n' 'invalid framing unexpectedly succeeded' >&2
  exit 1
fi
cmp -s "$invalid" "$TMP/invalid.before"
grep -q 'invalid framing' "$TMP/invalid.err"

fifo="$TMP/fifo.status"
printf '%s' 'done: blocked backup\\n' > "$fifo"
mkfifo "$fifo.legacy-backup"
cp "$fifo" "$TMP/fifo.before"
if fm_parent_channel_append_once "$fifo" 'working: ignored' 2>"$TMP/fifo.err"; then
  printf '%s\n' 'FIFO backup unexpectedly succeeded' >&2
  exit 1
fi
cmp -s "$fifo" "$TMP/fifo.before"
grep -q 'backup is not a regular file' "$TMP/fifo.err"

interrupted="$TMP/interrupted.status"
printf '%s' 'done: retry me\n' > "$interrupted"
printf '%s' 'done: retry me\n' > "$interrupted.legacy-backup"
fm_parent_channel_append_once "$interrupted" 'failed: retry complete'
[ "$(cat "$interrupted")" = $'done: retry me\nfailed: retry complete' ]

printf '%s\n' 'parent-channel migration tests passed'
