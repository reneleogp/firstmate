#!/usr/bin/env bash
# Verify that a process belongs to the live Pi session holding a home's session lock.
# Usage: fm-session-lock-check.sh <state-dir> <peer-pid>
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

lock_pid=$(cat "$1/.lock" 2>/dev/null) || exit 1
lock_comm=$(ps -o comm= -p "$lock_pid" 2>/dev/null) || exit 1
case "$(basename -- "$lock_comm")" in
  pi|pi-signed) exit 0 ;;
  *) exit 1 ;;
esac
