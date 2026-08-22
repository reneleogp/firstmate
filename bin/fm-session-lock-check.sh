#!/usr/bin/env bash
# Verify that a process belongs to the live harness holding a home's session lock.
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
fm_session_lock_owned_by_pid "$1" "$2"
