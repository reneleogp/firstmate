#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Publishes the harness (agent) process found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written - together
# with that process's kernel generation identity, so a recycled pid can never
# inherit the record. bin/fm-session-lock-lib.sh owns the record format, the
# generation identity, and every verdict this script prints.
# Usage: fm-lock.sh                   acquire; exit 1 unless ownership is verified
#        fm-lock.sh status            print holder and liveness; always exits 0
#        fm-lock.sh generation-check  exit 0 only while the record's identity
#                                     binding still holds (for validators that
#                                     must not re-derive the binding themselves)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  if ! old=$(fm_session_lock_pid "$STATE"); then
    echo "lock: unreadable or malformed"
    exit 0
  fi
  if fm_session_lock_holder_live "$STATE"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old is dead, not a harness, or a different process generation than the one that published this lock)"
  fi
  exit 0
fi

if [ "${1:-}" = "generation-check" ]; then
  fm_session_lock_generation_holds "$STATE" || exit 1
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
RECORD=$(fm_session_lock_record "$me")
RECORD_RC=$?
if [ "$RECORD_RC" -eq 1 ]; then
  echo "error: cannot build a session-lock record for harness pid $me; operate read-only until resolved" >&2
  exit 1
fi
# One announcement shape for both acquisition paths. A host that exposes no
# process-generation source still gets a lock, and is told plainly that the
# recycled-pid protection is the weaker legacy one until it can be recorded.
announce_acquired() {
  echo "lock acquired: harness pid $me"
  [ "$RECORD_RC" -eq 2 ] || return 0
  echo "lock: process generation is unavailable on this host, so this record keeps only the legacy pid binding"
}
# One refusal test for both claim paths: a record only blocks this session when
# it names a DIFFERENT live session. A record naming this same harness pid is
# ours to replace whichever generation wrote it, because no other live process
# can be holding this pid - that is what makes upgrading a pre-generation record
# safe without ever evicting a competitor.
REFUSED_PID=
another_live_session_holds() {
  local lock_pid
  lock_pid=$(fm_session_lock_pid "$STATE") || return 1
  [ "$lock_pid" != "$me" ] || return 1
  fm_session_lock_holder_live "$STATE" || return 1
  REFUSED_PID=$lock_pid
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  # Byte-identical to what this process would publish means the record already
  # names this pid AND this generation, so there is nothing to rewrite.
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$RECORD" ]; then
    announce_acquired
    exit 0
  fi
  if another_live_session_holds; then
    echo "error: another live firstmate session holds the lock (pid $REFUSED_PID); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$RECORD" ] && another_live_session_holds; then
    echo "error: another live firstmate session holds the lock (pid $REFUSED_PID); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$RECORD" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$RECORD" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
# Publication is only complete when the record VALIDATES through the same owner
# every later reader uses; a record that cannot be read back as still binding is
# no better than no lock at all.
if ! fm_session_lock_generation_holds "$STATE"; then
  echo "error: session lock identity binding did not verify after publication; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
announce_acquired
