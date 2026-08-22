#!/usr/bin/env bash
# tests/fm-telegram-macos-service.test.sh - the macOS LaunchAgent lifecycle of
# bin/fm-telegram.py.
#
# Every case drives the real service commands. Where readiness is the subject
# the LaunchAgent runs the REAL bot, so the marker an installer waits for is the
# one the bot itself publishes once its socket is listening. Where the subject
# is a start that fails or a process that refuses to stop, it runs a fixture
# that takes exactly that shape.
#
# launchd itself is stood in for by tests/fixtures/telegram-mirror/fake-launchctl.py
# on hosts that have none; that fixture's header states exactly which launchd
# semantics it models. What it cannot stand in for - real launchd, real plutil,
# and macOS's own peer-credential options - is listed in docs/telegram.md as
# work only the captain's Mac can accept.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found for the Telegram service test"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-telegram-macos-service)
BOT="$ROOT/bin/fm-telegram.py"
FIXTURES="$ROOT/tests/fixtures/telegram-mirror"
LABEL="com.firstmate.telegram"
# A placeholder that stands for the captain's real token: every assertion below
# is that this string never leaves the private env file.
PLACEHOLDER_TOKEN="000000:placeholder-not-a-real-token"

# The waits below are deliberately shortened, and the bot only ever accepts a
# shortening: the production bounds themselves are pinned by the last case.
READY_TIMEOUT=${READY_TIMEOUT:-15}
STOP_TIMEOUT=${STOP_TIMEOUT:-5}

CASE_INDEX=0
CASE_HOME=
CASE_DIR=
PLIST=

# One disposable installation: its own private directory, its own fake HOME for
# ~/Library/LaunchAgents, and its own launchd state.
new_case() {
  CASE_INDEX=$((CASE_INDEX + 1))
  CASE_DIR="$TMP_ROOT/case$CASE_INDEX"
  CASE_HOME="$CASE_DIR/private"
  mkdir -p "$CASE_HOME" "$CASE_DIR/home/Library/LaunchAgents" "$CASE_DIR/fmhome"
  chmod 700 "$CASE_HOME"
  PLIST="$CASE_DIR/home/Library/LaunchAgents/$LABEL.plist"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$PLACEHOLDER_TOKEN" >"$CASE_HOME/env"
  chmod 600 "$CASE_HOME/env"
  # A pairing the real bot accepts, pointed at a port nothing answers: the bot
  # starts, serves its socket, and simply logs failed polls.
  cat >"$CASE_HOME/config.json" <<'JSON'
{
  "chat_id": 9797,
  "confirmations": true,
  "user_id": 4242
}
JSON
  chmod 600 "$CASE_HOME/config.json"
  printf '{}\n' >"$CASE_DIR/launchd.json"
}

# Run one service command against this case's disposable installation.
service() {  # <command> [mode]
  local command=$1 mode=${2:-real} program=()
  if [ "$mode" != real ]; then
    program=("FM_TELEGRAM_SERVICE_PROGRAM=$(command -v python3) $FIXTURES/fake-service.py run")
  fi
  env -u WSL_DISTRO_NAME \
    HOME="$CASE_DIR/home" \
    FM_TELEGRAM_DIR="$CASE_HOME" \
    FM_HOME="$CASE_DIR/fmhome" \
    FM_TELEGRAM_API_BASE="http://127.0.0.1:9" \
    FM_TELEGRAM_ASSUME_PLATFORM=macos \
    FM_TELEGRAM_TESTING=1 \
    FM_TELEGRAM_LAUNCHCTL="$FIXTURES/fake-launchctl.py" \
    FM_FAKE_LAUNCHD_STATE="$CASE_DIR/launchd.json" \
    FM_TELEGRAM_FAKE_MODE="$mode" \
    FM_TELEGRAM_READY_TIMEOUT="$READY_TIMEOUT" \
    FM_TELEGRAM_STOP_TIMEOUT="$STOP_TIMEOUT" \
    "${program[@]}" \
    python3 "$BOT" "$command" 2>&1
}

fake_launchctl() {
  env -u WSL_DISTRO_NAME \
    HOME="$CASE_DIR/home" \
    FM_TELEGRAM_API_BASE="http://127.0.0.1:9" \
    FM_TELEGRAM_TESTING=1 \
    FM_FAKE_LAUNCHD_STATE="$CASE_DIR/launchd.json" \
    "$FIXTURES/fake-launchctl.py" "$@" 2>&1
}

# One question about the launchd state, by name.
launchd_query() {  # <loaded|launches|disabled|pid|pids>
  python3 - "$CASE_DIR/launchd.json" "$LABEL" "$1" <<'PY'
import json
import sys

path, label, question = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, json.JSONDecodeError):
    state = {}
job = state.get("jobs", {}).get(label, {})
answers = {
    "loaded": lambda: "yes" if label in state.get("jobs", {}) else "no",
    "launches": lambda: str(len(state.get("launches", []))),
    "disabled": lambda: "yes" if state.get("disabled", {}).get(label) else "no",
    "pid": lambda: str(job.get("pid") or 0),
    "pids": lambda: " ".join(str(entry["pid"]) for entry in state.get("launches", [])),
}
print(answers[question]())
PY
}

job_loaded() {
  [ "$(launchd_query loaded)" = yes ]
}

launch_count() {
  launchd_query launches
}

label_disabled() {
  [ "$(launchd_query disabled)" = yes ]
}

running_pid() {
  launchd_query pid
}

stop_everything() {
  local pids pid remaining waited
  pids=$(launchd_query pids 2>/dev/null || true)
  for pid in $pids; do
    kill -9 "$pid" 2>/dev/null || true
  done
  # Every launch of every case, so nothing is still writing into the fixture
  # root when it is removed.
  waited=0
  while [ "$waited" -lt 30 ]; do
    remaining=0
    for pid in $pids; do
      kill -0 "$pid" 2>/dev/null && remaining=1
    done
    [ "$remaining" = 0 ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  sleep 0.2
}

cleanup_all() {
  local index
  index=1
  while [ "$index" -le "$CASE_INDEX" ]; do
    CASE_DIR="$TMP_ROOT/case$index"
    stop_everything
    index=$((index + 1))
  done
  fm_test_cleanup
}

trap cleanup_all EXIT

# --- installation -----------------------------------------------------------

test_install_starts_one_service_and_waits_for_that_child() {
  local out pid marker_pid marker_id plist_id
  new_case
  out=$(service install-service) || fail "install-service failed: $out"
  job_loaded || fail "install reported success without a loaded job: $out"
  [ "$(launch_count)" = 1 ] \
    || fail "install started $(launch_count) processes; exactly one service process may run"
  pid=$(running_pid)
  marker_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' \
    "$CASE_HOME/service-ready.json")
  [ "$marker_pid" = "$pid" ] \
    || fail "readiness was accepted for pid $marker_pid while launchd runs $pid"
  marker_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["launch_id"])' \
    "$CASE_HOME/service-ready.json")
  plist_id=$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["EnvironmentVariables"]["FM_TELEGRAM_LAUNCH_ID"])' "$PLIST")
  [ -n "$marker_id" ] && [ "$marker_id" = "$plist_id" ] \
    || fail "the child that reported ready was not the generation this install launched"
  [ -S "$CASE_HOME/bot.sock" ] || fail "the started service is not serving its socket"
  [ -f "$CASE_HOME/service.log" ] && [ ! -L "$CASE_HOME/service.log" ] \
    || fail "the started service did not open its private log as a regular file"
  [ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$CASE_HOME/service.log")" = 0o600 ] \
    || fail "the started service log is not owner-only"
  pass "telegram macOS: install starts exactly one service and waits for that child to serve"
}

test_the_published_definition_carries_no_secret() {
  local out environment
  new_case
  out=$(service install-service) || fail "install-service failed: $out"
  assert_no_grep "$PLACEHOLDER_TOKEN" "$PLIST" \
    "the published LaunchAgent carries the bot token"
  assert_no_grep "9797" "$PLIST" "the published LaunchAgent carries the paired chat"
  assert_no_grep "4242" "$PLIST" "the published LaunchAgent carries the paired account"
  environment=$(python3 -c 'import plistlib,sys; print(",".join(sorted(plistlib.load(open(sys.argv[1],"rb"))["EnvironmentVariables"])))' "$PLIST")
  [ "$environment" = "FM_HOME,FM_TELEGRAM_DIR,FM_TELEGRAM_LAUNCH_ID" ] \
    || fail "the LaunchAgent environment is not only local paths and a launch id: $environment"
  python3 -c 'import plistlib,sys; data=plistlib.load(open(sys.argv[1],"rb")); assert data["RunAtLoad"] is True' "$PLIST" \
    || fail "the LaunchAgent does not start the bot at login"
  if [ -f "$CASE_HOME/service.log" ]; then
    assert_no_grep "$PLACEHOLDER_TOKEN" "$CASE_HOME/service.log" \
      "the service log carries the bot token"
  fi
  pass "telegram macOS: the published LaunchAgent starts at login and carries only local paths"
}

test_install_refuses_a_service_log_symlink() {
  local out victim
  new_case
  victim="$CASE_DIR/victim.log"
  printf 'do not overwrite\n' >"$victim"
  ln -s "$victim" "$CASE_HOME/service.log"
  if out=$(service install-service); then
    fail "install followed a service-log symlink: $out"
  fi
  [ "$(cat "$victim")" = "do not overwrite" ] \
    || fail "install wrote through the service-log symlink"
  [ -L "$CASE_HOME/service.log" ] || fail "install replaced the refusing symlink"
  assert_absent "$PLIST" "a service-log refusal still published a LaunchAgent"
  job_loaded && fail "a service-log refusal still started a job"
  pass "telegram macOS: install refuses a service-log symlink before publication"
}

test_a_login_launch_refuses_a_swapped_service_log_symlink() {
  local out victim pid attempts
  new_case
  out=$(service install-service) || fail "install-service failed: $out"
  out=$(service stop-service) || fail "stop-service failed: $out"
  victim="$CASE_DIR/victim.log"
  printf 'do not overwrite\n' >"$victim"
  rm -f "$CASE_HOME/service.log"
  ln -s "$victim" "$CASE_HOME/service.log"
  out=$(fake_launchctl bootstrap "gui/$(id -u)" "$PLIST") \
    || fail "the simulated login could not load the published LaunchAgent: $out"
  [ "$(launch_count)" = 2 ] \
    || fail "the simulated login did not launch the installed child"
  pid=$(running_pid)
  attempts=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 50 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  sleep 0.2
  out=$(fake_launchctl print "gui/$(id -u)/$LABEL") \
    || fail "the simulated login job disappeared before its refusal was observed: $out"
  case "$out" in
    *"last exit code = 1"*) : ;;
    *) fail "the launched child did not refuse the swapped service-log symlink: $out" ;;
  esac
  [ "$(cat "$victim")" = "do not overwrite" ] \
    || fail "a login launch wrote through the swapped service-log symlink"
  [ -L "$CASE_HOME/service.log" ] \
    || fail "a login launch replaced the swapped service-log symlink"
  pass "telegram macOS: every login launch refuses a swapped service-log symlink"
}

test_update_relaunches_once_and_ignores_the_previous_marker() {
  local out first second before
  new_case
  out=$(service install-service) || fail "first install failed: $out"
  first=$(running_pid)
  before=$(cat "$CASE_HOME/service-ready.json")
  out=$(service install-service) || fail "update failed: $out"
  second=$(running_pid)
  [ "$first" != "$second" ] || fail "the update did not replace the running service"
  [ "$(launch_count)" = 2 ] \
    || fail "the update produced $(launch_count) launches in total; each starts exactly one"
  [ "$before" != "$(cat "$CASE_HOME/service-ready.json")" ] \
    || fail "the update accepted the previous child's readiness marker"
  pass "telegram macOS: an update relaunches once and never accepts the replaced child's marker"
}

test_a_stale_marker_never_reports_a_new_launch_ready() {
  local out
  new_case
  # The child publishes a marker for a generation this install never launched,
  # which is exactly the shape a leftover marker takes.
  if out=$(service install-service stale); then
    fail "install accepted a marker from another launch generation: $out"
  fi
  case "$out" in
    *"did not report itself ready"*) : ;;
    *) fail "install did not report the readiness timeout: $out" ;;
  esac
  assert_absent "$PLIST" "a failed fresh install left a LaunchAgent that starts at login"
  pass "telegram macOS: a marker from another generation never reports a launch ready"
}

# --- failure and rollback ---------------------------------------------------

test_a_failed_install_leaves_nothing_that_starts_at_login() {
  local out
  new_case
  if out=$(service install-service fail); then
    fail "install reported success for a service that refuses to start: $out"
  fi
  assert_absent "$PLIST" "a failed fresh install left its LaunchAgent published"
  job_loaded && fail "a failed install left the job loaded"
  case "$out" in
    *"exited with status 3"*|*"did not report itself ready"*) : ;;
    *) fail "install did not report why the service never started: $out" ;;
  esac
  pass "telegram macOS: a failed install rolls back and leaves nothing to start at login"
}

test_a_failed_update_restores_the_previous_definition_and_child() {
  local out before after previous_pid restored_pid
  new_case
  out=$(service install-service) || fail "first install failed: $out"
  before=$(cat "$PLIST")
  previous_pid=$(running_pid)
  if out=$(service install-service fail); then
    fail "an update to a broken service reported success: $out"
  fi
  after=$(cat "$PLIST")
  [ "$before" = "$after" ] \
    || fail "a failed update left a different LaunchAgent published"
  job_loaded || fail "a failed update left the previously loaded service down"
  restored_pid=$(running_pid)
  [ "$restored_pid" != 0 ] && [ "$restored_pid" != "$previous_pid" ] \
    || fail "a failed update did not restart exactly one replacement for the prior child"
  [ "$(launch_count)" = 3 ] \
    || fail "a failed update launched $(launch_count) children instead of old, failed, restored"
  case "$out" in
    *"the previous state was restored"*) : ;;
    *) fail "a complete rollback was not reported as restored: $out" ;;
  esac
  pass "telegram macOS: a failed update restores its definition and one running child"
}

test_an_incomplete_update_rollback_is_reported() {
  local out
  new_case
  out=$(service install-service) || fail "first install failed: $out"
  if out=$(FM_FAKE_LAUNCHD_FAIL_BOOTSTRAP_CALL=3 service install-service fail); then
    fail "an update with a failed rollback reported success: $out"
  fi
  case "$out" in
    *"rollback was incomplete"*) : ;;
    *) fail "an incomplete rollback claimed the previous state was restored: $out" ;;
  esac
  case "$out" in
    *"the previous state was restored"*)
      fail "an incomplete rollback claimed success: $out"
      ;;
    *) : ;;
  esac
  job_loaded && fail "the failed rollback unexpectedly left a loaded prior service"
  pass "telegram macOS: an incomplete rollback is surfaced instead of claiming restoration"
}

test_a_failed_install_restores_a_previous_disable() {
  local out
  new_case
  out=$(service install-service) || fail "first install failed: $out"
  out=$(service disable-service) || fail "disable-service failed: $out"
  label_disabled || fail "disable-service did not record the disable"
  if out=$(service install-service fail); then
    fail "an install of a broken service reported success: $out"
  fi
  label_disabled \
    || fail "a failed install left a disabled service enabled again"
  pass "telegram macOS: a failed install restores the disable it had to lift"
}

# --- stopping ---------------------------------------------------------------

test_stop_escalates_past_a_service_that_ignores_it() {
  local out pid
  new_case
  out=$(service install-service wedge) || fail "install-service failed: $out"
  pid=$(running_pid)
  out=$(service stop-service wedge) || fail "stop-service failed: $out"
  job_loaded && fail "stop reported success while the job was still loaded"
  kill -0 "$pid" 2>/dev/null && fail "stop reported success while its process was still running"
  pass "telegram macOS: a bounded stop escalates past a service that ignores it"
}

test_stop_leaves_the_installation_in_place() {
  local out
  new_case
  out=$(service install-service) || fail "install-service failed: $out"
  out=$(service stop-service) || fail "stop-service failed: $out"
  [ -f "$PLIST" ] || fail "stop removed the installation"
  label_disabled && fail "stop disabled the service instead of only stopping it"
  out=$(service stop-service) || fail "stopping an already stopped service failed: $out"
  pass "telegram macOS: stop stops the service and leaves the installation alone"
}

# --- disable ----------------------------------------------------------------

test_disable_is_recorded_even_when_nothing_is_running() {
  local out
  new_case
  out=$(service install-service) || fail "install-service failed: $out"
  out=$(service stop-service) || fail "stop-service failed: $out"
  job_loaded && fail "the service was still loaded before disable"
  out=$(service disable-service) || fail "disable-service failed: $out"
  # The plist is still installed, so without a recorded disable launchd would
  # start it again at the next login.
  label_disabled || fail "disable did not record anything for an unloaded service"
  pass "telegram macOS: disable is recorded for an unloaded service, not skipped"
}

test_install_lifts_its_own_disable() {
  local out
  new_case
  out=$(service install-service) || fail "install-service failed: $out"
  out=$(service disable-service) || fail "disable-service failed: $out"
  out=$(service install-service) || fail "install after disable failed: $out"
  label_disabled && fail "install left the service disabled and unable to start at login"
  job_loaded || fail "install after disable did not start the service"
  pass "telegram macOS: an explicit install lifts the disable it recorded earlier"
}

# --- ownership --------------------------------------------------------------

test_a_foreign_definition_is_never_touched() {
  local out before
  new_case
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/echo</string><string>run</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_TELEGRAM_DIR</key><string>/somewhere/else</string>
  </dict>
</dict>
</plist>
PLIST
  before=$(cat "$PLIST")
  for command in install-service restart-service stop-service disable-service uninstall-service; do
    if out=$(service "$command"); then
      fail "$command mutated an installation it does not own: $out"
    fi
    case "$out" in
      *"another Telegram mirror installation"*) : ;;
      *) fail "$command did not say the installation is not its own: $out" ;;
    esac
  done
  [ "$before" = "$(cat "$PLIST")" ] || fail "a foreign LaunchAgent was rewritten"
  job_loaded && fail "a foreign LaunchAgent was loaded"
  pass "telegram macOS: an installation serving another home is reported, never replaced or removed"
}

test_a_job_loaded_from_another_definition_is_never_stopped() {
  local out elsewhere
  new_case
  elsewhere="$CASE_DIR/elsewhere.plist"
  out=$(service install-service) || fail "install-service failed: $out"
  # Same label, another published definition: launchd's job no longer matches
  # the file this installation owns.
  python3 - "$CASE_DIR/launchd.json" "$elsewhere" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
state["jobs"]["com.firstmate.telegram"]["path"] = sys.argv[2]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
  for command in install-service restart-service stop-service disable-service uninstall-service; do
    if out=$(service "$command"); then
      fail "$command acted on a job loaded from another definition: $out"
    fi
    case "$out" in
      *"does not own"*) : ;;
      *) fail "$command did not say the loaded job is not its own: $out" ;;
    esac
  done
  job_loaded || fail "a job loaded from another definition was booted out"
  pass "telegram macOS: a loaded job launchd read from another definition is left alone"
}

test_no_command_acts_on_a_job_it_cannot_prove_is_its_own() {
  local out
  new_case
  out=$(service install-service) || fail "install-service failed: $out"
  # The definition is gone but launchd still serves the label, so there is
  # nothing left to compare the running job against.
  rm -f "$PLIST"
  for command in install-service restart-service stop-service disable-service uninstall-service; do
    if out=$(service "$command"); then
      fail "$command acted on a job it could not prove is its own: $out"
    fi
    case "$out" in
      *"cannot prove"*) : ;;
      *) fail "$command did not say why it refused: $out" ;;
    esac
    case "$out" in
      *"launchctl print gui/"*) : ;;
      *) fail "$command did not name the command that inspects that job: $out" ;;
    esac
  done
  job_loaded || fail "a job whose ownership could not be proven was booted out"
  label_disabled && fail "a job whose ownership could not be proven was disabled"
  assert_absent "$PLIST" "a refusing command published a definition anyway"
  pass "telegram macOS: no command stops, disables, replaces, or removes a job it cannot prove is its own"
}

test_cleanup_removes_its_own_installation() {
  local out
  new_case
  out=$(service install-service) || fail "install-service failed: $out"
  out=$(service uninstall-service) || fail "uninstall-service failed: $out"
  assert_absent "$PLIST" "cleanup left its own LaunchAgent behind"
  job_loaded && fail "cleanup left its own job loaded"
  assert_absent "$CASE_HOME/service-ready.json" "cleanup left a readiness marker behind"
  label_disabled && fail "cleanup left a disable record that would suppress the next install"
  out=$(service uninstall-service) || fail "cleaning up an absent installation failed: $out"
  pass "telegram macOS: cleanup removes exactly its own installation and leaves no residue"
}

# --- validation -------------------------------------------------------------

test_a_rejected_definition_is_never_published() {
  local out refuser
  new_case
  refuser="$CASE_DIR/plutil"
  cat >"$refuser" <<'SH'
#!/usr/bin/env bash
echo "$2: property list is malformed"
exit 1
SH
  chmod +x "$refuser"
  if out=$(env -u WSL_DISTRO_NAME HOME="$CASE_DIR/home" FM_TELEGRAM_DIR="$CASE_HOME" \
    FM_HOME="$CASE_DIR/fmhome" FM_TELEGRAM_ASSUME_PLATFORM=macos FM_TELEGRAM_TESTING=1 \
    FM_TELEGRAM_LAUNCHCTL="$FIXTURES/fake-launchctl.py" \
    FM_FAKE_LAUNCHD_STATE="$CASE_DIR/launchd.json" \
    FM_TELEGRAM_PLUTIL="$refuser" \
    python3 "$BOT" install-service 2>&1); then
    fail "install published a definition the platform validator rejected: $out"
  fi
  case "$out" in
    *"plutil rejected"*) : ;;
    *) fail "install did not report the validator's refusal: $out" ;;
  esac
  assert_absent "$PLIST" "a rejected definition was published anyway"
  [ -z "$(find "$CASE_DIR/home/Library/LaunchAgents" -name '.*.plist' -print -quit)" ] \
    || fail "a rejected definition left its temporary file behind"
  pass "telegram macOS: a definition the platform validator rejects is never published"
}

test_status_reports_the_installation_without_a_secret() {
  local out
  new_case
  out=$(service status) || fail "status failed: $out"
  case "$out" in
    *"service definition: $PLIST (absent)"*) : ;;
    *) fail "status did not report an absent installation: $out" ;;
  esac
  out=$(service install-service) || fail "install-service failed: $out"
  out=$(service status) || fail "status failed after install: $out"
  case "$out" in
    *"(owned)"*) : ;;
    *) fail "status did not report the installation as its own: $out" ;;
  esac
  case "$out" in
    *"service enabled: yes"*) : ;;
    *) fail "status did not report the service as able to start at login: $out" ;;
  esac
  case "$out" in
    *"service: running (pid"*) : ;;
    *) fail "status did not report the running service: $out" ;;
  esac
  case "$out" in
    *"$PLACEHOLDER_TOKEN"*) fail "status printed the bot token" ;;
    *) : ;;
  esac
  pass "telegram macOS: status reports ownership, login state, and the running service"
}

# --- peer identity ----------------------------------------------------------

test_macos_peer_credentials_are_decoded_from_the_kernel_struct() {
  # macOS answers LOCAL_PEERCRED with struct xucred rather than Linux's
  # SO_PEERCRED. The option itself needs a real Mac; the decoding of what it
  # returns is decided here.
  python3 - "$BOT" <<'PY' || fail "the macOS peer-credential decoding is wrong"
import importlib.util
import struct
import sys

spec = importlib.util.spec_from_file_location("fm_telegram", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# struct xucred: u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[16]
supported = struct.pack("=IIh", 0, 501, 1) + b"\x00" * 66
assert module.decode_xucred(supported) == 501, "a valid xucred did not yield its uid"
# A layout this build does not understand must not be read as an identity.
future = struct.pack("=IIh", 7, 501, 1) + b"\x00" * 66
assert module.decode_xucred(future) is None, "an unknown xucred version was trusted"
assert module.decode_xucred(b"\x00\x00") is None, "a truncated xucred was trusted"
PY
  pass "telegram macOS: peer credentials are decoded from the kernel struct, and only a known one"
}

test_readiness_outlasts_the_bot_s_own_network_waits() {
  # The defect this bound exists for: a readiness wait shorter than the bot's
  # own longest network wait kills a healthy service for being slow. The stop
  # bound has the mirror-image job against the bot's own bounded shutdown.
  python3 - "$BOT" <<'PY' || fail "a service bound is shorter than the wait it has to outlast"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_telegram", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

longest_poll = module.POLL_TIMEOUT + 15
assert module.LAUNCHD_READY_TIMEOUT > longest_poll, (
    f"readiness waits {module.LAUNCHD_READY_TIMEOUT}s but the bot itself can "
    f"take {longest_poll}s before it is serving"
)
longest_stop = 2 * module.STOP_GRACE_SECONDS + module.TRANSCRIBE_STOP_GRACE
assert module.LAUNCHD_STOP_TIMEOUT > longest_stop, (
    f"the stop waits {module.LAUNCHD_STOP_TIMEOUT}s but the bot's own stop can "
    f"take {longest_stop}s"
)
assert module.LAUNCHD_EXIT_TIMEOUT >= longest_stop
PY
  pass "telegram macOS: the readiness and stop bounds outlast the waits the bot itself can take"
}

test_install_starts_one_service_and_waits_for_that_child
test_the_published_definition_carries_no_secret
test_install_refuses_a_service_log_symlink
test_a_login_launch_refuses_a_swapped_service_log_symlink
test_update_relaunches_once_and_ignores_the_previous_marker
test_a_stale_marker_never_reports_a_new_launch_ready
test_a_failed_install_leaves_nothing_that_starts_at_login
test_a_failed_update_restores_the_previous_definition_and_child
test_an_incomplete_update_rollback_is_reported
test_a_failed_install_restores_a_previous_disable
test_stop_escalates_past_a_service_that_ignores_it
test_stop_leaves_the_installation_in_place
test_disable_is_recorded_even_when_nothing_is_running
test_install_lifts_its_own_disable
test_a_foreign_definition_is_never_touched
test_a_job_loaded_from_another_definition_is_never_stopped
test_no_command_acts_on_a_job_it_cannot_prove_is_its_own
test_cleanup_removes_its_own_installation
test_a_rejected_definition_is_never_published
test_status_reports_the_installation_without_a_secret
test_macos_peer_credentials_are_decoded_from_the_kernel_struct
test_readiness_outlasts_the_bot_s_own_network_waits
