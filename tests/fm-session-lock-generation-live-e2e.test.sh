#!/usr/bin/env bash
# tests/fm-session-lock-generation-live-e2e.test.sh - opt-in guard proving the
# session lock's kernel process-generation identity resolves for every INSTALLED
# harness, and that a record published for one is refused once that exact process
# is gone (bin/fm-session-lock-lib.sh, bin/fm-lock.sh).
#
# Why this file exists: the generation identity is read from the running harness
# process itself. A harness that re-execs, relaunches itself under a different
# process, or hides behind a launcher can change what the kernel reports for the
# pid firstmate publishes, and a stub agent cannot show that - only the real
# binary can. A silently unavailable generation would degrade the whole fleet to
# the weaker legacy pid binding without anyone noticing.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. The launch uses whatever credentials the harness already has; an
# unauthenticated harness still starts a process, which is all this reads.
#
# Standard CI has no harness binaries, so this is opt-in and on-demand. The
# portable counterpart tests/fm-session-lock-generation.test.sh pins the same
# contract in CI with ordinary processes. Run this guard after any harness
# upgrade and before trusting refreshed per-harness evidence.
set -u

if [ "${FM_SESSION_LOCK_GENERATION_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SESSION_LOCK_GENERATION_LIVE_E2E=1 to run the installed-harness session-lock identity guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found, so no harness can be given the terminal it needs"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-session-lock-generation-$$"
SESSION=identity
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-lock-generation-live.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/wt"
# Every harness here is a terminal program: launched without a terminal it exits
# immediately, and an exited process can prove nothing about live identity.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"

# Mirror bin/fm-spawn.sh's own resolution order, so this guard covers the same
# binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  return 1
}

CHECKED=0
SKIPPED=

# The harnesses that can be a firstmate PRIMARY, i.e. the ones that publish a
# session lock. muse is crew-only and never holds a home's lock.
for harness in claude codex opencode pi pi-signed grok kimi cursor; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its identity is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  # cursor blocks on a workspace-trust prompt in a directory it has never seen;
  # --trust is the same flag fm-spawn passes for the same reason.
  launch_args=""
  [ "$harness" = cursor ] && launch_args="--trust"
  target="$SESSION:$harness"
  # shellcheck disable=SC2086  # deliberate: an empty value must add no argument
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" $launch_args \
    || fail "$harness ($version): could not launch a window for the identity probe"

  pid=
  generation=
  for _ in $(seq 1 150); do
    pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_pid}' 2>/dev/null | tr -d '[:space:]')
    case "$pid" in
      ''|*[!0-9]*) sleep 0.2; continue ;;
    esac
    fm_harness_pid_alive "$pid" || { sleep 0.2; continue; }
    generation=$(fm_process_generation "$pid" 2>/dev/null || true)
    [ -n "$generation" ] && break
    sleep 0.2
  done

  case "$pid" in
    ''|*[!0-9]*) fail "$harness ($version): no live process could be resolved for the identity probe" ;;
  esac
  fm_harness_pid_alive "$pid" || fail \
    "$harness ($version): pid $pid is not classified as a live harness, so this guard proved nothing for it"
  [ -n "$generation" ] || fail \
    "SESSION-LOCK IDENTITY UNAVAILABLE: $harness $version is running as pid $pid but the kernel exposes no process generation for it. Every session lock this harness publishes would fall back to the weaker legacy pid binding. Teach bin/fm-session-lock-lib.sh's fm_process_generation the source this platform and release actually provide."

  state="$LAB/$harness-state"
  mkdir -p "$state"
  record=$(fm_session_lock_record "$pid") || fail "$harness ($version): no session-lock record could be built"
  printf '%s\n' "$record" > "$state/.lock"
  verdict=$(fm_session_lock_generation_verdict "$state") || fail \
    "$harness ($version): the published record did not parse"
  [ "$verdict" = bound ] || fail \
    "$harness ($version): a record published for the live process read '$verdict', not 'bound'"
  fm_session_lock_holder_live "$state" \
    || fail "$harness ($version): the live process was not recognized as the holder of its own record"

  note "$harness $version: pid=$pid generation=$generation"

  # The same record, once that exact process is gone, must never hold again -
  # which is what stops a later pid reuse from inheriting the home.
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && fail "$harness ($version): the probe process could not be stopped"
  if fm_session_lock_holder_live "$state"; then
    fail "$harness ($version): the record still read as held after the publishing process exited"
  fi

  pass "session-lock identity: $harness $version publishes a bound record that retires with its process"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no primary-capable harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
