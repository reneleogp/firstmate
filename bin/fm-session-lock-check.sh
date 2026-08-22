#!/usr/bin/env bash
# Verify that a process belongs to the live Pi session holding a home's session lock.
# Usage: fm-session-lock-check.sh <state-dir> <peer-pid>
#
# Environment:
#   FM_TELEGRAM_PLATFORM   linux or macos, overriding the uname verdict
#   FM_TELEGRAM_PROC_ROOT  /proc root to read (Linux only)
set -u

if [ "$#" -ne 2 ]; then
  echo "usage: fm-session-lock-check.sh <state-dir> <peer-pid>" >&2
  exit 2
fi
case "$2" in
  ''|*[!0-9]*) exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_lock_owned_by_pid "$1" "$2" || exit 1

lock_path=$1/.lock
lock_pid=$(cat "$lock_path" 2>/dev/null) || exit 1
lock_comm=$(ps -o comm= -p "$lock_pid" 2>/dev/null) || exit 1
case "$(basename -- "$lock_comm")" in
  pi|pi-signed) ;;
  *) exit 1 ;;
esac

# A lock names a pid, and a pid is reused. Refusing a lock older than the
# process that claims it is what keeps a recycled pid from inheriting an
# earlier session's authority. Both platforms answer the same question - did
# this process start at or before the lock was written - from whatever identity
# their kernel exposes: /proc on Linux, elapsed process time on macOS, which has
# no /proc at all.
#
# Linux exposes process starts in clock ticks from boot while lock mtimes have
# one-second portable precision, and macOS reports elapsed time floored to whole
# seconds. One second admits either precision boundary and nothing more.
LOCK_TIME_TOLERANCE_SECONDS=1

platform=${FM_TELEGRAM_PLATFORM:-}
if [ -z "$platform" ]; then
  case "$(uname -s 2>/dev/null)" in
    Darwin) platform=macos ;;
    *) platform=linux ;;
  esac
fi

case "$platform" in
  macos)
    elapsed=$(ps -o etime= -p "$lock_pid" 2>/dev/null) || exit 1
    now=$(date +%s) || exit 1
    lock_time=$(stat -f %m "$lock_path" 2>/dev/null) || exit 1
    case "$now:$lock_time" in
      *[!0-9:]*) exit 1 ;;
    esac
    awk -v elapsed="$elapsed" -v now="$now" -v lock="$lock_time" \
      -v tolerance="$LOCK_TIME_TOLERANCE_SECONDS" '
      BEGIN {
        gsub(/[[:space:]]/, "", elapsed)
        if (elapsed !~ /^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$/) exit 1
        days = 0
        rest = elapsed
        if (split(elapsed, parts, "-") == 2) { days = parts[1]; rest = parts[2] }
        count = split(rest, fields, ":")
        if (count == 3) seconds = fields[1] * 3600 + fields[2] * 60 + fields[3]
        else if (count == 2) seconds = fields[1] * 60 + fields[2]
        else exit 1
        exit !((now - (days * 86400 + seconds)) <= (lock + tolerance))
      }' || exit 1
    ;;
  *)
    PROC_ROOT=${FM_TELEGRAM_PROC_ROOT:-/proc}
    proc_stat=$(cat "$PROC_ROOT/$lock_pid/stat" 2>/dev/null) || exit 1
    proc_fields=${proc_stat##*) }
    read -r -a proc_field_array <<< "$proc_fields"
    [ "${#proc_field_array[@]}" -ge 20 ] || exit 1
    start_ticks=${proc_field_array[19]}
    boot_time=$(awk '$1 == "btime" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit } END { if (!found) exit 1 }' "$PROC_ROOT/stat" 2>/dev/null) || exit 1
    clock_ticks=$(getconf CLK_TCK 2>/dev/null) || exit 1
    lock_time=$(stat -c %Y -- "$lock_path" 2>/dev/null) || exit 1
    case "$start_ticks:$boot_time:$clock_ticks:$lock_time" in
      *[!0-9:]*) exit 1 ;;
    esac
    [ "$clock_ticks" -gt 0 ] 2>/dev/null || exit 1
    awk -v boot="$boot_time" -v ticks="$start_ticks" -v hz="$clock_ticks" \
      -v lock="$lock_time" -v tolerance="$LOCK_TIME_TOLERANCE_SECONDS" \
      'BEGIN { exit !((boot + (ticks / hz)) <= (lock + tolerance)) }' || exit 1
    ;;
esac
