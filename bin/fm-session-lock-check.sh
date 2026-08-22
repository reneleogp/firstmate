#!/usr/bin/env bash
# Verify that a process belongs to the live Pi session holding a home's session lock.
# The lock record's shape, the kernel process-generation identity, and every
# ownership verdict are owned by bin/fm-session-lock-lib.sh; this script adds only
# the Pi-family restriction its Telegram caller needs.
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

# Authorizing a process outside the session's own ancestry takes positive
# identity evidence, so an undecidable legacy record authorizes nothing here even
# though it still serves that home's own session.
fm_session_lock_generation_verified "$1" || exit 1

lock_pid=$(fm_session_lock_pid "$1") || exit 1
lock_comm=$(ps -o comm= -p "$lock_pid" 2>/dev/null) || exit 1
case "$(basename -- "$lock_comm")" in
  pi|pi-signed) ;;
  *) exit 1 ;;
esac
