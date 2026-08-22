#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, is that still the same process generation, and does the current process
# descend from it?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# SESSION-LOCK RECORD FORMAT (state/.lock), owned here and nowhere else:
#
#   line 1: <pid>          the session's verified-harness pid, unchanged since
#                          the lock's first format, so every first-line reader
#                          keeps working across the transition
#   line 2: gen=<token>    that pid's kernel process-generation identity as of
#                          publication (current format; see fm_process_generation)
#
# A pid alone identifies nothing durable: pids are recycled, and the replacement
# can be another genuine Pi-family process that satisfies every name-based
# harness check. Binding the record to the kernel's own generation identity for
# that pid is what makes "is this still the process that published the lock?"
# answerable instead of guessed.
#
# A record in any other shape - a non-numeric pid, a second line that is not a
# well-formed gen=, an empty token, or a third line - is malformed and grants
# nothing. Callers read the binding through fm_session_lock_generation_verdict:
#
#   bound     current-format record whose recorded generation still matches the
#             live pid; the only positive proof of identity
#   compat    legacy single-line record that lock-mtime evidence proves was NOT
#             written by a later recycled pid (see fm_session_lock_legacy_verdict)
#   unbound   legacy single-line record on a host that exposes no process-start
#             evidence, so neither proof nor disproof is available
#   mismatch  a proven or unverifiable identity change; never grants authority
#
# COMPATIBILITY PATH: a home whose lock predates this format keeps working. Its
# legacy record is accepted for that home's OWN ancestry-proven ownership
# (bound/compat/unbound) and is rewritten in the current format the next time its
# true owner runs bin/fm-lock.sh, which is every session start. External peer
# authorization is stricter and takes only bound or compat, so an unprovable
# legacy record can never authorize a process outside the session's ancestry.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {  # [start-pid]
  local pid=${1:-$$} comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# --- kernel process-generation identity --------------------------------------

# Linux exposes process starts in clock ticks from boot while lock mtimes have
# one-second portable precision. One second admits the precision boundary only.
FM_SESSION_LOCK_TIME_TOLERANCE_SECONDS=1

# procfs root. FM_TELEGRAM_PROC_ROOT is the older name for the same override and
# is still honored so existing Telegram-side callers keep working.
fm_session_lock_proc_root() {
  printf '%s' "${FM_SESSION_LOCK_PROC_ROOT:-${FM_TELEGRAM_PROC_ROOT:-/proc}}"
}

# Print pid $1's start time in clock ticks since boot, from procfs, or return 1.
# The command name is skipped through the LAST ") " because it can itself contain
# spaces and parentheses; starttime is field 22 overall, i.e. index 19 of what
# remains.
fm_proc_start_ticks() {  # <pid>
  local pid=$1 stat fields ticks
  local -a field_array
  stat=$(cat "$(fm_session_lock_proc_root)/$pid/stat" 2>/dev/null) || return 1
  fields=${stat##*) }
  [ "$fields" != "$stat" ] || return 1
  read -r -a field_array <<< "$fields"
  [ "${#field_array[@]}" -ge 20 ] || return 1
  ticks=${field_array[19]}
  case "$ticks" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$ticks"
}

# Print a per-boot anchor for tick-based start times, or return 1. Boot ticks are
# meaningless across reboots, so the anchor is what keeps a token from matching a
# same-pid same-tick process on the other side of a restart.
fm_proc_boot_anchor() {
  local proc boot
  proc=$(fm_session_lock_proc_root)
  boot=$(cat "$proc/sys/kernel/random/boot_id" 2>/dev/null) || boot=''
  boot=$(printf '%s' "$boot" | tr -cd 'A-Za-z0-9-')
  if [ -n "$boot" ]; then
    printf 'boot-%s' "$boot"
    return 0
  fi
  boot=$(awk '$1 == "btime" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit } END { if (!found) exit 1 }' \
    "$proc/stat" 2>/dev/null) || return 1
  printf 'btime-%s' "$boot"
}

# Print pid $1's kernel process-generation identity as one opaque token, or
# return 1 when this host exposes neither source.
#
# proc:<boot-anchor>:<start-ticks> is the portable positive source currently
# available to this repository. ps lstart is deliberately not an identity
# source: its one-second resolution lets a same-second recycled pid inherit the
# token. A host without positive higher-resolution evidence uses the explicit
# legacy compatibility path instead of publishing an unverifiable generation.
fm_process_generation() {  # <pid>
  local pid=$1 ticks anchor
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if ticks=$(fm_proc_start_ticks "$pid") && anchor=$(fm_proc_boot_anchor); then
    printf 'proc:%s:%s' "$anchor" "$ticks"
    return 0
  fi
  return 1
}

# Print pid $1's start time in whole epoch seconds, or return 1. procfs only:
# this is used exclusively for the legacy-record disproof below, and every host
# that lacks procfs simply has no such evidence to offer.
fm_process_start_epoch() {  # <pid>
  local pid=$1 ticks btime hz
  ticks=$(fm_proc_start_ticks "$pid") || return 1
  btime=$(awk '$1 == "btime" && $2 ~ /^[0-9]+$/ { print $2; found=1; exit } END { if (!found) exit 1 }' \
    "$(fm_session_lock_proc_root)/stat" 2>/dev/null) || return 1
  hz=$(getconf CLK_TCK 2>/dev/null) || return 1
  case "$hz" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$hz" -gt 0 ] 2>/dev/null || return 1
  awk -v boot="$btime" -v ticks="$ticks" -v hz="$hz" 'BEGIN { printf "%d", boot + (ticks / hz) }'
}

# Print file $1's mtime in epoch seconds, or return 1. GNU stat first, BSD stat
# second, so both supported platforms answer.
fm_file_mtime_epoch() {  # <path>
  local path=$1 mtime
  mtime=$(stat -c %Y -- "$path" 2>/dev/null) || mtime=$(stat -f %m -- "$path" 2>/dev/null) || return 1
  case "$mtime" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$mtime"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- session-lock record -----------------------------------------------------

# Parse state dir $1's session lock. On success sets, for the caller to read:
#   FM_SESSION_LOCK_PID     the recorded harness pid
#   FM_SESSION_LOCK_GEN     the recorded generation token, empty when legacy
#   FM_SESSION_LOCK_FORMAT  current | legacy
# A missing, non-regular, symlinked, unreadable, or malformed record returns 1
# with all three cleared, so no caller can act on a half-read lock.
# shellcheck disable=SC2034 # read by callers after the function returns
FM_SESSION_LOCK_PID=''
# shellcheck disable=SC2034 # read by callers after the function returns
FM_SESSION_LOCK_GEN=''
# shellcheck disable=SC2034 # read by callers after the function returns
FM_SESSION_LOCK_FORMAT=''
fm_session_lock_parse() {  # <state>
  local state=$1 lock pid_line gen_line token line
  local -a lines
  FM_SESSION_LOCK_PID=''
  FM_SESSION_LOCK_GEN=''
  FM_SESSION_LOCK_FORMAT=''
  lock="$state/.lock"
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done < "$lock" 2>/dev/null || return 1
  case "${#lines[@]}" in
    1) pid_line=${lines[0]}; gen_line='' ;;
    2) pid_line=${lines[0]}; gen_line=${lines[1]} ;;
    *) return 1 ;;
  esac
  case "$pid_line" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pid_line" -gt 1 ] 2>/dev/null || return 1
  if [ "${#lines[@]}" -eq 1 ]; then
    FM_SESSION_LOCK_PID=$pid_line
    FM_SESSION_LOCK_FORMAT=legacy
    return 0
  fi
  case "$gen_line" in
    gen=*) token=${gen_line#gen=} ;;
    *) return 1 ;;
  esac
  [ -n "$token" ] || return 1
  case "$token" in
    *[!A-Za-z0-9:_.+-]*) return 1 ;;
  esac
  FM_SESSION_LOCK_PID=$pid_line
  FM_SESSION_LOCK_GEN=$token
  FM_SESSION_LOCK_FORMAT=current
}

# Print state dir $1's recorded owner pid, or return 1 on any record the parser
# rejects. Every reader that needs the pid goes through this rather than reading
# the file, so the record's shape has exactly one owner.
fm_session_lock_pid() {  # <state>
  fm_session_lock_parse "$1" || return 1
  printf '%s' "$FM_SESSION_LOCK_PID"
}

# Print the record bin/fm-lock.sh publishes for harness pid $1.
# Exit 0 when the generation could be recorded, 2 when this host exposes no
# generation source and the caller must publish the legacy shape and say so,
# and 1 when the pid itself is unusable.
fm_session_lock_record() {  # <pid>
  local pid=$1 gen
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$pid" -gt 1 ] 2>/dev/null || return 1
  if gen=$(fm_process_generation "$pid") && [ -n "$gen" ]; then
    printf '%s\ngen=%s' "$pid" "$gen"
    return 0
  fi
  printf '%s' "$pid"
  return 2
}

# Verdict for a legacy single-line record in state dir $1 naming pid $2:
# compat when the lock file is at least as old as the live process, mismatch
# when the process provably started after the lock was written, unbound when
# this host offers no start-time evidence either way.
#
# The disproof is exact rather than heuristic: at the moment the record was
# written, that pid belonged to the publishing session, so any OTHER process
# holding it now must have started after that write. Only clock precision
# blurs the boundary, which is what the one-second tolerance absorbs.
fm_session_lock_legacy_verdict() {  # <state> <pid>
  local state=$1 pid=$2 start mtime
  start=$(fm_process_start_epoch "$pid") || { printf 'unbound'; return 0; }
  mtime=$(fm_file_mtime_epoch "$state/.lock") || { printf 'unbound'; return 0; }
  if [ "$start" -le $((mtime + FM_SESSION_LOCK_TIME_TOLERANCE_SECONDS)) ]; then
    printf 'compat'
  else
    printf 'mismatch'
  fi
}

# Print state dir $1's generation verdict (bound|compat|unbound|mismatch), or
# return 1 when the record cannot be parsed at all. A current-format record whose
# live generation cannot be computed reads mismatch, not unbound: a binding that
# cannot be checked must never be treated as holding.
fm_session_lock_generation_verdict() {  # <state>
  local state=$1 pid recorded live
  fm_session_lock_parse "$state" || return 1
  pid=$FM_SESSION_LOCK_PID
  recorded=$FM_SESSION_LOCK_GEN
  if [ "$FM_SESSION_LOCK_FORMAT" = legacy ]; then
    fm_session_lock_legacy_verdict "$state" "$pid"
    return 0
  fi
  live=$(fm_process_generation "$pid") || { printf 'mismatch'; return 0; }
  if [ -n "$live" ] && [ "$live" = "$recorded" ]; then
    printf 'bound'
  else
    printf 'mismatch'
  fi
}

# True when state dir $1's record still binds to its pid well enough for this
# home's own session to act on it: proven (bound), disproved-recycled (compat),
# or a legacy record no evidence can decide (unbound, the pre-generation posture
# this migration must not regress).
fm_session_lock_generation_holds() {  # <state>
  local verdict
  verdict=$(fm_session_lock_generation_verdict "$1") || return 1
  case "$verdict" in
    bound|compat|unbound) return 0 ;;
  esac
  return 1
}

# True only when state dir $1's record carries positive identity evidence.
# Authorization of a process OUTSIDE the session's own ancestry uses this, so an
# undecidable legacy record authorizes nothing.
fm_session_lock_generation_verified() {  # <state>
  local verdict
  verdict=$(fm_session_lock_generation_verdict "$1") || return 1
  case "$verdict" in
    bound|compat) return 0 ;;
  esac
  return 1
}

# Print one canonical snapshot of state dir $1's complete validated lock
# identity. Consumers that defer mutation carry this opaque value and ask this
# owner whether it still holds, so replacing a lock with the same recycled pid
# cannot preserve authority.
fm_session_lock_identity() {  # <state>
  local state=$1 verdict pid gen
  fm_session_lock_parse "$state" || return 1
  pid=$FM_SESSION_LOCK_PID
  gen=$FM_SESSION_LOCK_GEN
  verdict=$(fm_session_lock_generation_verdict "$state") || return 1
  case "$verdict" in
    bound) printf 'v1:%s:%s' "$pid" "$gen" ;;
    compat|unbound) printf 'legacy:%s' "$pid" ;;
    *) return 1 ;;
  esac
}

# True only while state dir $1 still has exactly opaque identity $2.
fm_session_lock_identity_holds() {  # <state> <identity>
  local current
  [ -n "$2" ] || return 1
  current=$(fm_session_lock_identity "$1") || return 1
  [ "$current" = "$2" ]
}

# True when state dir $1's lock names a live verified harness that is still the
# same process generation, i.e. some session genuinely holds this home right now.
# This is the predicate that separates "another live session owns the home" from
# "a dead session left its pid behind and something else now answers to it".
fm_session_lock_holder_live() {  # <state>
  local state=$1 pid
  pid=$(fm_session_lock_pid "$state") || return 1
  fm_harness_pid_alive "$pid" || return 1
  fm_session_lock_generation_holds "$state"
}

# True when state dir $1 holds a regular, non-symlink session lock naming a
# live verified harness, still in its recorded process generation, in process
# $2's own harness ancestry. Membership is the honest test of that question,
# because the lock owner sits at an unknown depth in a contiguous Claude run - it
# is the outermost pid when a hook fires inside the session's nested worker
# chain, and an inner pid when a harness-named daemon parents the session. A
# stale, recycled, malformed, or non-regular lock and an ancestry that cannot be
# resolved all fail closed.
fm_session_lock_owned_by_pid() {  # <state> <start-pid>
  local state=$1 start_pid=$2 lock_pid pids pid
  fm_session_lock_holder_live "$state" || return 1
  lock_pid=$(fm_session_lock_pid "$state") || return 1
  pids=$(fm_harness_ancestry_pids "$start_pid") || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# True when this process descends from the verified harness holding $1's lock.
fm_session_lock_owned_by_self() {
  fm_session_lock_owned_by_pid "$1" "$$"
}
