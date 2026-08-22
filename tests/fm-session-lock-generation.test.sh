#!/usr/bin/env bash
# tests/fm-session-lock-generation.test.sh - the session lock's kernel
# process-generation identity (bin/fm-session-lock-lib.sh, bin/fm-lock.sh,
# bin/fm-session-lock-check.sh).
#
# Why this file exists: a pid identifies nothing durable. When a session dies and
# the kernel hands its pid to another process that still answers to a harness
# name - another genuine Pi-family process is the realistic case - every
# name-based check keeps passing, so a stale record reads as a live owner. The
# next real session is then refused the home and runs read-only forever, and the
# turn-end integrations stand down for a session that no longer exists.
#
# Every case here drives REAL processes and the real published record, so the
# assertions are about behavior rather than about the shape of the code. The
# recycled generation is produced by publishing a record for a live process whose
# generation is one token apart from the live one, which is exactly what a
# recycled pid presents to a validator: same pid, same name, same liveness,
# different process generation. A genuine kernel pid recycle needs a private PID
# namespace and root inside it, which CI cannot assume; this construction is the
# portable counterpart and pins the same verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-generation)
LIB="$ROOT/bin/fm-session-lock-lib.sh"
LOCK_SH="$ROOT/bin/fm-lock.sh"
CHECK_SH="$ROOT/bin/fm-session-lock-check.sh"

# A real process that answers to a verified harness name, so the harness
# identity layer is satisfied and only the generation binding is under test.
HARNESS_BIN="$TMP_ROOT/pi"
cp /bin/bash "$HARNESS_BIN"
chmod +x "$HARNESS_BIN"

LIVE_PIDS=()
start_harness() {  # -> pid on stdout
  # `; :` keeps bash from exec-ing the final command, which would replace this
  # process with `sleep` and lose the harness name the identity layer reads. The
  # stream redirect matters just as much: these starters are called through
  # command substitution, and a background child left holding that pipe does not
  # survive it.
  "$HARNESS_BIN" -c 'sleep 120; :' >/dev/null 2>&1 &
  local pid=$!
  LIVE_PIDS+=("$pid")
  printf '%s\n' "$pid"
}

# A harness process that publishes <home>'s lock the way a session does - from
# inside itself, so the ancestry walk resolves it as the owner - and then stays
# alive, so the record it published still names a running process.
start_publishing_harness() {  # <home> <out-file> -> pid on stdout
  local home=$1 out=$2 pid i
  "$HARNESS_BIN" -c "FM_HOME='$home' '$LOCK_SH' > '$out' 2>&1; sleep 120; :" >/dev/null 2>&1 &
  pid=$!
  LIVE_PIDS+=("$pid")
  i=0
  while [ "$i" -lt 200 ] && [ ! -s "$out" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

stop_harnesses() {
  local pid
  for pid in "${LIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  LIVE_PIDS=()
}
trap stop_harnesses EXIT

# A long-lived harness process that runs <script> as its own child every time
# <trigger> appears, recording the output and exit status. That is how a real
# session re-acquires its home at a later session start, and how a helper process
# runs INSIDE that session's ancestry, without the session process changing.
start_scriptable_harness() {  # <script> <trigger> <out> -> pid on stdout
  local script=$1 trigger=$2 out=$3 pid
  "$HARNESS_BIN" -c "
    for _ in \$(seq 1 2400); do
      if [ -f '$trigger' ]; then
        rm -f '$trigger'
        '$script' > '$out' 2>&1
        printf '%s\n' \"\$?\" > '$out.rc'
      fi
      sleep 0.05
    done
    :" >/dev/null 2>&1 &
  pid=$!
  LIVE_PIDS+=("$pid")
  printf '%s\n' "$pid"
}

# Fire one run inside that session and print its exit status; output lands in
# <out>. A run that never reports back is a fixture failure, not a verdict.
harness_run() {  # <trigger> <out> -> exit status on stdout
  local trigger=$1 out=$2 i=0
  rm -f "$out" "$out.rc"
  : > "$trigger"
  while [ "$i" -lt 400 ] && [ ! -s "$out.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$out.rc" ] || fail "the harness session never ran its triggered command"
  tr -d '[:space:]' < "$out.rc"
}

# Evaluate one library expression against the real process table.
lib_eval() {  # <expression>
  bash -c '. "$0"; '"$1" "$LIB"
}

generation_of() {  # <pid>
  lib_eval "fm_process_generation '$1'"
}

# --- publication -------------------------------------------------------------

test_publication_binds_the_record_to_the_publishing_generation() {
  local home pid out record line1 line2 gen
  home="$TMP_ROOT/publication"
  mkdir -p "$home/state"
  pid=$(start_publishing_harness "$home" "$home/publish.out")
  out=$(cat "$home/publish.out")
  assert_contains "$out" "lock acquired: harness pid $pid" \
    "publication from a real harness process did not name that process: $out"

  record=$(cat "$home/state/.lock")
  line1=$(printf '%s\n' "$record" | sed -n '1p')
  line2=$(printf '%s\n' "$record" | sed -n '2p')
  [ "$line1" = "$pid" ] || fail "the record's first line is not the publishing pid: '$line1' vs '$pid'"
  case "$line2" in
    gen=*) : ;;
    *) fail "publication recorded no process generation (line 2 was '$line2')" ;;
  esac
  gen=${line2#gen=}
  [ -n "$gen" ] || fail "publication recorded an empty process generation"
  [ "$gen" = "$(generation_of "$pid")" ] \
    || fail "the recorded generation is not the publishing process's own"

  lib_eval "fm_session_lock_generation_verdict '$home/state'" | grep -qx bound \
    || fail "a freshly published record did not read as bound to its publisher"
  lib_eval "fm_session_lock_owned_by_pid '$home/state' '$pid'" \
    || fail "the publishing session was not recognized as the owner of its own record"
  pass "session-lock generation: publication records the publishing process's kernel generation"
}

test_publication_replaces_a_dead_owners_record() {
  local home first second
  home="$TMP_ROOT/stale-cleanup"
  mkdir -p "$home/state"
  "$HARNESS_BIN" -c "FM_HOME='$home' '$LOCK_SH' >/dev/null 2>&1; :"
  first=$(cat "$home/state/.lock")

  assert_contains "$(FM_HOME="$home" "$LOCK_SH" status)" "lock: stale" \
    "a record whose publishing session has exited must read as stale"

  "$HARNESS_BIN" -c "FM_HOME='$home' '$LOCK_SH' >/dev/null 2>&1; :"
  second=$(cat "$home/state/.lock")
  [ "$second" != "$first" ] || fail "a new session did not replace the dead owner's record"
  assert_contains "$second" "gen=" "stale cleanup republished a record with no generation binding"
  pass "session-lock generation: a dead owner's record is reclaimed and republished"
}

# --- the recycled-pid boundary ----------------------------------------------

test_recycled_pid_is_rejected_while_the_true_owner_is_accepted() {
  local home pid gen identity state out
  home="$TMP_ROOT/recycled"
  state="$home/state"
  mkdir -p "$state"
  pid=$(start_harness)
  gen=$(generation_of "$pid") || fail "no process generation is available for a live process on this platform"

  # The legitimate current owner: pid, name, liveness, and generation all agree.
  printf '%s\ngen=%s\n' "$pid" "$gen" > "$state/.lock"
  lib_eval "fm_session_lock_holder_live '$state'" \
    || fail "the genuine publishing process was not recognized as the live holder"
  lib_eval "fm_session_lock_owned_by_pid '$state' '$pid'" \
    || fail "the genuine owner's own process was refused ownership"
  identity=$(lib_eval "fm_session_lock_identity '$state'") \
    || fail "the genuine publisher had no complete lock identity"
  assert_contains "$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status)" "lock: held by live harness pid $pid" \
    "the genuine owner was not reported as holding the lock"

  # The smallest counterfactual: the SAME live harness process, one process
  # generation apart. Nothing else about the process or the record changes.
  printf '%s\ngen=%sX\n' "$pid" "$gen" > "$state/.lock"
  if lib_eval "fm_session_lock_holder_live '$state'"; then
    fail "a live same-name process in a different generation was accepted as the lock holder"
  fi
  if lib_eval "fm_session_lock_owned_by_pid '$state' '$pid'"; then
    fail "a recycled pid authorized its own process as the lock owner"
  fi
  if lib_eval "fm_session_lock_identity_holds '$state' '$identity'"; then
    fail "a deferred worker retained authority after same-pid generation replacement"
  fi
  [ "$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" ownership "$pid")" = missing ] \
    || fail "the owning executable reported a recycled pid as owned or competing"
  assert_contains "$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status)" "lock: stale" \
    "a recycled pid was still reported as a live holder"

  # The end-user consequence: the next real session must be able to take the
  # home instead of being refused into a read-only session.
  out=$("$HARNESS_BIN" -c "FM_STATE_OVERRIDE='$state' FM_HOME='$home' '$LOCK_SH' 2>&1; :")
  assert_contains "$out" "lock acquired: harness pid" \
    "a new session was refused the home by a stale record whose pid had been recycled: $out"
  assert_not_contains "$out" "another live firstmate session" \
    "a recycled pid still looked like a competing live session"
  pass "session-lock generation: a recycled pid never inherits the record, while its true owner keeps it"
}

test_a_live_owner_is_never_evicted() {
  local home pid gen out
  home="$TMP_ROOT/live-owner"
  mkdir -p "$home/state"
  pid=$(start_harness)
  gen=$(generation_of "$pid")
  printf '%s\ngen=%s\n' "$pid" "$gen" > "$home/state/.lock"

  out=$("$HARNESS_BIN" -c "FM_HOME='$home' '$LOCK_SH' 2>&1; :")
  assert_contains "$out" "another live firstmate session holds the lock (pid $pid)" \
    "a competing session took a home whose genuine owner is still running: $out"
  [ "$(sed -n '1p' "$home/state/.lock")" = "$pid" ] \
    || fail "the live owner's record was overwritten by a competing session"
  pass "session-lock generation: a genuinely live owner still refuses a competing session"
}

# --- malformed and missing generation data -----------------------------------

test_malformed_records_grant_nothing() {
  local home state pid case_label record
  home="$TMP_ROOT/malformed"
  state="$home/state"
  mkdir -p "$state"
  pid=$(start_harness)

  while IFS='|' read -r case_label record; do
    [ -n "$case_label" ] || continue
    printf '%b' "${record//PID/$pid}" > "$state/.lock"
    if lib_eval "fm_session_lock_pid '$state'" >/dev/null; then
      fail "$case_label: a malformed record was parsed into an owner pid"
    fi
    if lib_eval "fm_session_lock_holder_live '$state'"; then
      fail "$case_label: a malformed record was accepted as a live holder"
    fi
    if lib_eval "fm_session_lock_owned_by_pid '$state' '$pid'"; then
      fail "$case_label: a malformed record granted ownership"
    fi
    if lib_eval "fm_session_lock_generation_verdict '$state'" >/dev/null; then
      fail "$case_label: a malformed record produced a generation verdict"
    fi
    assert_contains "$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status)" "lock: unreadable or malformed" \
      "$case_label: status did not report the record as malformed"
  done <<'EOF'
empty generation|PID\ngen=\n
unknown key|PID\ngeneration=proc:x:1\n
bare second line|PID\nproc:x:1\n
whitespace in token|PID\ngen=proc x 1\n
extra line|PID\ngen=proc:x:1\nextra\n
trailing blank line|PID\ngen=proc:x:1\n\n
legacy trailing blank line|PID\n\n
non-numeric pid|not-a-pid\ngen=proc:x:1\n
init pid|1\ngen=proc:x:1\n
EOF

  rm -f "$state/.lock"
  printf '%s\ngen=x\n' "$pid" > "$home/elsewhere"
  ln -s "$home/elsewhere" "$state/.lock"
  if lib_eval "fm_session_lock_pid '$state'" >/dev/null; then
    fail "a symlinked record was parsed into an owner pid"
  fi
  if lib_eval "fm_session_lock_owned_by_pid '$state' '$pid'"; then
    fail "a symlinked record granted ownership"
  fi
  rm -f "$state/.lock"
  pass "session-lock generation: malformed, mis-keyed, over-long, and symlinked records grant nothing"
}

test_unverifiable_current_record_is_never_treated_as_bound() {
  local home state pid
  home="$TMP_ROOT/unverifiable"
  state="$home/state"
  mkdir -p "$state" "$home/emptyproc"
  pid=$(start_harness)
  printf '%s\ngen=proc:btime-1:1\n' "$pid" > "$state/.lock"

  # A current-format record whose live generation cannot be recomputed is
  # unverifiable, which is a refusal - never a fall back to the legacy posture.
  lib_eval "fm_session_lock_generation_verdict '$state'" | grep -qx mismatch \
    || fail "a current-format record with an unmatchable generation did not read as a mismatch"
  if lib_eval "fm_session_lock_holder_live '$state'"; then
    fail "a current-format record that cannot be verified was accepted as a live holder"
  fi
  pass "session-lock generation: a current-format record that cannot be verified never grants authority"
}

# --- compatibility with pre-generation records -------------------------------

test_legacy_record_keeps_serving_its_own_session_and_is_upgraded() {
  local home state pid record out rc
  home="$TMP_ROOT/legacy"
  state="$home/state"
  mkdir -p "$state"
  cat > "$home/acquire.sh" <<SH
#!/usr/bin/env bash
FM_HOME='$home' FM_STATE_OVERRIDE='$state' exec '$LOCK_SH'
SH
  chmod +x "$home/acquire.sh"
  pid=$(start_scriptable_harness "$home/acquire.sh" "$home/trigger" "$home/out")

  # Exactly what a home running the previous firstmate published: pid only.
  printf '%s\n' "$pid" > "$state/.lock"
  lib_eval "fm_session_lock_holder_live '$state'" \
    || fail "a legacy record naming a live harness stopped being honored, stranding an existing home"
  lib_eval "fm_session_lock_owned_by_pid '$state' '$pid'" \
    || fail "a legacy record refused its own live owner"
  assert_contains "$(FM_STATE_OVERRIDE="$state" "$LOCK_SH" status)" "lock: held by live harness pid $pid" \
    "a legacy record's live owner was not reported as holding the lock"

  # That same session's next acquisition upgrades the record in place.
  rc=$(harness_run "$home/trigger" "$home/out")
  out=$(cat "$home/out")
  expect_code 0 "$rc" "the legacy record's own session could not re-acquire its home: $out"
  assert_contains "$out" "lock acquired: harness pid $pid" \
    "re-acquisition did not name the same session: $out"
  record=$(cat "$state/.lock")
  assert_contains "$record" "gen=" "a legacy record was not upgraded to the bound format on the next acquisition"
  [ "$(sed -n '1p' "$state/.lock")" = "$pid" ] || fail "the upgraded record no longer names the same session"
  lib_eval "fm_session_lock_generation_verdict '$state'" | grep -qx bound \
    || fail "the upgraded record is not bound to the session that published it"
  pass "session-lock generation: a pre-generation record still serves its home and is upgraded on acquisition"
}

test_legacy_record_is_rejected_once_the_process_postdates_it() {
  local home state pid
  home="$TMP_ROOT/legacy-recycled"
  state="$home/state"
  mkdir -p "$state"
  pid=$(start_harness)
  if ! lib_eval "fm_process_start_epoch '$pid'" >/dev/null; then
    pass "session-lock generation: legacy disproof skipped - this platform exposes no process start times (SKIPPED)"
    return 0
  fi

  # A legacy record written BEFORE this process existed cannot have been written
  # by it, which is precisely the recycled-pid case for a pre-generation home.
  printf '%s\n' "$pid" > "$state/.lock"
  touch -d '@1000000000' "$state/.lock" 2>/dev/null || touch -t 200109090146.40 "$state/.lock"
  lib_eval "fm_session_lock_generation_verdict '$state'" | grep -qx mismatch \
    || fail "a legacy record older than the process now holding its pid was not disproved"
  if lib_eval "fm_session_lock_owned_by_pid '$state' '$pid'"; then
    fail "a recycled pid inherited a legacy record"
  fi
  pass "session-lock generation: a legacy record is disproved once its pid belongs to a later process"
}

# --- external peer authorization --------------------------------------------

test_peer_authorization_requires_positive_identity_evidence() {
  local home state pid gen rc
  home="$TMP_ROOT/peer"
  state="$home/state"
  mkdir -p "$state" "$home/emptyproc"
  cat > "$home/peer.sh" <<SH
#!/usr/bin/env bash
exec '$CHECK_SH' '$state' "\$\$"
SH
  chmod +x "$home/peer.sh"
  # The peer runs INSIDE this session, which is what the checker's ancestry test
  # requires; only the record's identity evidence varies below.
  pid=$(start_scriptable_harness "$home/peer.sh" "$home/trigger" "$home/out")
  gen=$(generation_of "$pid")

  printf '%s\ngen=%s\n' "$pid" "$gen" > "$state/.lock"
  rc=$(harness_run "$home/trigger" "$home/out")
  expect_code 0 "$rc" "a peer inside the bound owner's session was refused authorization"

  # The smallest counterfactual again: same live session, one generation apart.
  printf '%s\ngen=%sX\n' "$pid" "$gen" > "$state/.lock"
  rc=$(harness_run "$home/trigger" "$home/out")
  expect_code 1 "$rc" "a peer was authorized against a record whose pid had been recycled"

  # A legacy record no evidence can decide authorizes nothing outside the
  # session, even though the same record still serves that session itself.
  printf '%s\n' "$pid" > "$state/.lock"
  FM_SESSION_LOCK_PROC_ROOT="$home/emptyproc" FM_SESSION_LOCK_PS_COMMAND=false \
    lib_eval "fm_session_lock_generation_verdict '$state'" \
    | grep -qx unbound || fail "a legacy record with no start-time evidence did not read as unbound"
  if FM_SESSION_LOCK_PROC_ROOT="$home/emptyproc" FM_SESSION_LOCK_PS_COMMAND=false \
    "$CHECK_SH" "$state" "$pid"; then
    fail "an undecidable legacy record authorized a peer"
  fi
  FM_SESSION_LOCK_PROC_ROOT="$home/emptyproc" FM_SESSION_LOCK_PS_COMMAND=false \
    lib_eval "fm_session_lock_owned_by_pid '$state' '$pid'" \
    || fail "an undecidable legacy record stopped serving its own session"
  pass "session-lock generation: peer authorization takes positive identity evidence, session ownership keeps compatibility"
}

# --- supported-platform behavior ---------------------------------------------

test_publication_without_generation_sources_is_explicitly_legacy() {
  local home state out record
  home="$TMP_ROOT/no-generation-sources"
  state="$home/state"
  mkdir -p "$state" "$home/empty-proc"

  out=$(FM_SESSION_LOCK_PROC_ROOT="$home/empty-proc" FM_SESSION_LOCK_PS_COMMAND=false \
    "$HARNESS_BIN" -c "FM_HOME='$home' '$LOCK_SH' 2>&1; :")
  assert_contains "$out" "lock acquired: harness pid" \
    "a host exposing neither generation source was refused a session lock: $out"
  assert_contains "$out" "only the legacy pid binding" \
    "legacy-only publication did not plainly explain its weaker binding: $out"
  record=$(cat "$state/.lock")
  case "$record" in
    *$'\n'*) fail "legacy-only publication unexpectedly wrote a multi-line record: $record" ;;
  esac
  case "$record" in
    ''|*[!0-9]*) fail "legacy-only publication did not persist the harness pid: $record" ;;
  esac
  pass "session-lock generation: a host with neither source gets a plainly announced legacy lock"
}

test_process_generation_sources_on_this_platform() {
  local first second other_pid other empty_root fallback fallback_second dead
  first=$(generation_of "$$") || fail "no process generation source is available on this platform"
  second=$(generation_of "$$")
  [ "$first" = "$second" ] || fail "the same process reported two different generations: '$first' then '$second'"

  other_pid=$(start_harness)
  other=$(generation_of "$other_pid")
  [ "$other" != "$first" ] || fail "two distinct live processes reported the same generation '$other'"

  case "$first" in
    proc:*) : ;;
    *) fail "unknown or insufficient-resolution generation scheme '$first'" ;;
  esac
  if [ -r /proc/$$/stat ]; then
    case "$first" in
      proc:*) : ;;
      *) fail "procfs is readable here but the higher-resolution scheme was not used: '$first'" ;;
    esac
  fi

  # With procfs unavailable, the portable macOS/BSD ps lstart source still
  # publishes a stable, self-contained generation token and start-time value.
  empty_root="$TMP_ROOT/empty-proc"
  mkdir -p "$empty_root"
  fallback=$(FM_SESSION_LOCK_PROC_ROOT="$empty_root" generation_of "$$") \
    || fail "the portable ps lstart generation source was unavailable"
  fallback_second=$(FM_SESSION_LOCK_PROC_ROOT="$empty_root" generation_of "$$")
  [ "$fallback" = "$fallback_second" ] \
    || fail "ps lstart reported two generations for one process: '$fallback' then '$fallback_second'"
  case "$fallback" in
    ps:*) : ;;
    *) fail "the no-procfs fallback did not identify itself as ps lstart: '$fallback'" ;;
  esac
  FM_SESSION_LOCK_PROC_ROOT="$empty_root" lib_eval "fm_process_start_epoch '$$'" >/dev/null \
    || fail "ps lstart could not support legacy lock-mtime disproof"

  # A host exposing neither source gets no generation token and therefore takes
  # the explicit legacy publication path.
  if FM_SESSION_LOCK_PROC_ROOT="$empty_root" FM_SESSION_LOCK_PS_COMMAND=false \
    generation_of "$$" >/dev/null; then
    fail "a host exposing neither supported process-generation source issued a token"
  fi

  # A dead pid has no generation at all, so a record naming one can never verify.
  dead=$(start_harness)
  kill "$dead" 2>/dev/null || true
  wait "$dead" 2>/dev/null || true
  if generation_of "$dead" >/dev/null; then
    fail "a dead pid still reported a process generation"
  fi
  pass "session-lock generation: procfs and portable ps sources bind, while a host with neither falls back"
}

test_publication_binds_the_record_to_the_publishing_generation
test_publication_replaces_a_dead_owners_record
test_recycled_pid_is_rejected_while_the_true_owner_is_accepted
test_a_live_owner_is_never_evicted
test_malformed_records_grant_nothing
test_unverifiable_current_record_is_never_treated_as_bound
test_legacy_record_keeps_serving_its_own_session_and_is_upgraded
test_legacy_record_is_rejected_once_the_process_postdates_it
test_peer_authorization_requires_positive_identity_evidence
test_publication_without_generation_sources_is_explicitly_legacy
test_process_generation_sources_on_this_platform
