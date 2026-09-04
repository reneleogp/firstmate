#!/usr/bin/env bash
# fm-parent-channel-lib.sh - the one owner of a secondmate home's parent channel.
#
# WHY THIS EXISTS. A secondmate is a firstmate in its own home, and nobody reads
# its chat: the captain and the main firstmate see only what is appended to the
# parent channel. AGENTS.md tells every firstmate to reach the captain and to
# address the captain in every response, so a mate model reliably "reports" a
# PR-ready result, a finding, a decision, a blocker, or a failure in its own
# chat and skips the one status-file append that would actually deliver it.
# Four such misses were observed on 2026-09-02 across two mate homes; the
# watcher had delivered the parent's request each time and the work was done.
# The problem is therefore not one missed PR notice but every captain-facing
# outcome that depends on the model remembering to write to the channel.
# The fix is structural: every script that RECORDS a captain-facing outcome in a
# mate home publishes it on the parent channel itself, so delivery never
# depends on the model. This library owns where that channel lives and how a
# line is appended to it. The publishers are:
#   - bin/fm-inactive-reconcile.sh   a direct child's terminal done or failed
#                                    ledger line, on every watcher poll, plus
#                                    the silent-ledger inactive-outcome fallback
#   - bin/fm-pr-check.sh             a registered PR-ready line carrying the
#                                    canonical URL
#   - bin/fm-captain-hold.sh         a task held for the captain and its answer
#   - bin/fm-merge-outcome-lib.sh    a merged PR
#   - bin/fm-teardown.sh             the child's final ledger line, refusing to
#                                    remove the child while it is undelivered
#   - bin/fm-secondmate-report.sh     a marked request's correlated answer,
#                                    with this resolver choosing its destination
# The mate's own appends are reserved for judgement (bin/fm-brief.sh charter).
# docs/secondmate-parent-channel.md records the design and its coverage.
#
# THE CHANNEL. It is resolved from the home's own durable identity and parent
# binding, never from a caller's choice:
#   - the .fm-secondmate-home marker names the mate's id in its parent home;
#   - the .fm-secondmate-parent record (bin/fm-secondmate-parent-lib.sh) names
#     the route: a local route reports into the parent home's
#     state/<mate-id>.status, a remote route into this home's own
#     state/parent-replies.status, which the parent's remote reply adapter
#     mirrors line for line into that same parent file
#     (docs/remote-secondmates.md).
# The parent watcher classifies lines there exactly as it classifies any
# crewmate's status stream, so a captain-relevant line becomes a parent wake.
#
# Lines follow the charter's "<state> [key=<slug>]: <note>" shape and are
# appended at most once by exact content, so a retried publication cannot
# duplicate a delivered event. The append walks every parent component and opens
# each directory and the destination with no-follow flags while holding an
# exclusive file lock, so a concurrent replacement cannot redirect the write.
# An existing destination must be a regular, non-symlinked file; a missing one is
# created with its directory. The Python append path compares and writes physical
# newline-delimited records, not a literal backslash-n separator.
#
# Return codes, shared by every entry point that resolves the channel:
#   0  resolved, or appended / already present
#   1  this is a main home (no .fm-secondmate-home marker): nothing to report
#   2  the identity marker exists but is unusable (symlink, NUL, bad id)
#   3  the parent binding is missing or unreadable
#   4  the append itself failed
# A caller that has already recorded the outcome locally must surface a
# non-zero return rather than treat it as delivered.
#
# Sourced by the publishers above and by tests. No side effects on source.

_FM_PARENT_CHANNEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_PARENT_CHANNEL_LIB_DIR/fm-secondmate-parent-lib.sh"

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ID=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ROUTE=

# A mate id is used as a file-name component in the parent home, so it is
# accepted only when it is path-safe: no empty value, leading dot, slash, or
# character outside [A-Za-z0-9._-].
_fm_parent_channel_id_valid() {  # <id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The secondmate identity of <home>, printed, or non-zero for a main home (1)
# or an unusable identity marker (2).
fm_parent_channel_home_id() {  # <home>
  local home=$1 marker id
  marker="$home/.fm-secondmate-home"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  _fm_parent_channel_id_valid "$id" || return 2
  printf '%s\n' "$id"
}

# Resolve the channel destination for <home> whose state dir is <state>.
# Prints the destination path and sets FM_PARENT_CHANNEL_ID and
# FM_PARENT_CHANNEL_ROUTE. Returns 1 for a main home, 2 for an unusable
# marker, 3 for a missing or unreadable parent binding.
fm_parent_channel_destination() {  # <home> <state>
  local home=$1 state=$2 id rc=0
  FM_PARENT_CHANNEL_ID=
  FM_PARENT_CHANNEL_ROUTE=
  id=$(fm_parent_channel_home_id "$home") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 3
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 3
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=local
      printf '%s/state/%s.status\n' "$FM_SECONDMATE_PARENT_HOME" "$id"
      ;;
    remote)
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=remote
      printf '%s/parent-replies.status\n' "$state"
      ;;
    *) return 3 ;;
  esac
}

# Fold <text> onto one bounded line, so a note copied from a child ledger or a
# hold reason cannot break the channel's line framing.
fm_parent_channel_clean_note() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

# Append <line> to <path> unless that exact line is already there.
fm_parent_channel_append_once() {  # <path> <line>
  python3 - "$1" "$2" <<'PY'
import errno
import fcntl
import os
import re
import stat
import sys

path = os.path.abspath(sys.argv[1])
for alias in ("/tmp", "/var"):
    if path == alias or path.startswith(alias + os.sep):
        path = os.path.realpath(alias) + path[len(alias):]
        break
line = os.fsencode(sys.argv[2])
parts = [part for part in path.split(os.sep) if part]
flags = getattr(os, "O_NOFOLLOW", 0)
if not flags:
    raise OSError(errno.ENOTSUP, "no symlink-safe open available")
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | flags
fd = os.open(os.sep, directory_flags)
try:
    for part in parts[:-1]:
        while True:
            try:
                next_fd = os.open(part, directory_flags, dir_fd=fd)
                break
            except FileNotFoundError:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    try:
                        existing = os.lstat(part, dir_fd=fd)
                    except FileNotFoundError:
                        continue
                    if stat.S_ISLNK(existing.st_mode):
                        raise OSError(errno.ELOOP, "symlinked parent channel directory")
        os.close(fd)
        fd = next_fd

    leaf = parts[-1] if parts else ""
    lock_name = leaf + ".lock"
    lock_fd = os.open(lock_name, os.O_RDWR | os.O_CREAT | flags, 0o600, dir_fd=fd)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        file_flags = os.O_RDWR | os.O_APPEND | os.O_CREAT | flags
        file_fd = os.open(leaf, file_flags, 0o600, dir_fd=fd)
        if not stat.S_ISREG(os.fstat(file_fd).st_mode):
            raise OSError(errno.EINVAL, "parent channel is not a regular file")
        os.lseek(file_fd, 0, os.SEEK_SET)
        chunks = []
        while True:
            chunk = os.read(file_fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        contents = b"".join(chunks)
        migration_blocked = False

        def report(message):
            print(f"parent channel migration: {path}: {message}", file=sys.stderr)

        legacy_record_pattern = re.compile(
            rb"^(?:working|done|failed|blocked|paused|needs-decision|resolved|captain-held)"
            rb"(?: (?:corr=[0-9a-f]{16} )?(?:\[key=[A-Za-z0-9._-]+\])?)?: [^\x00-\x1f]+$"
        )

        def legacy_record(record):
            return bool(legacy_record_pattern.fullmatch(record))

        if b"\\n" in contents:
            backup_name = os.path.basename(leaf) + ".legacy-backup"
            legacy_parts = contents.split(b"\\n")
            valid = (
                b"\\n" not in legacy_parts[-1]
                and legacy_parts[-1] == b""
                and len(legacy_parts) > 1
                and all(legacy_record(record) for record in legacy_parts[:-1])
            )
            if b"\n" in contents:
                valid = False
                migration_blocked = True
                report("ambiguous framing; left unchanged")
            if valid:
                try:
                    backup_stat = os.lstat(backup_name, dir_fd=fd)
                except FileNotFoundError:
                    backup_stat = None
                if backup_stat is not None:
                    if not stat.S_ISREG(backup_stat.st_mode):
                        valid = False
                        migration_blocked = True
                        report("backup is not a regular file; left unchanged")
                    else:
                        existing_backup_fd = os.open(
                            backup_name, os.O_RDONLY | os.O_NONBLOCK | flags, dir_fd=fd)
                        try:
                            if not stat.S_ISREG(os.fstat(existing_backup_fd).st_mode):
                                valid = False
                                migration_blocked = True
                                report("backup is not a regular file; left unchanged")
                            saved = b""
                            while valid:
                                chunk = os.read(existing_backup_fd, 65536)
                                if not chunk:
                                    break
                                saved += chunk
                        finally:
                            os.close(existing_backup_fd)
                        if valid and saved != contents:
                            valid = False
                            migration_blocked = True
                            report("backup disagrees with legacy contents; left unchanged")
                if valid and backup_stat is None:
                    backup_prefix = f".{backup_name}.migration.{os.getpid()}"
                    backup_number = 0
                    while True:
                        backup_temp_name = f"{backup_prefix}.{backup_number}"
                        try:
                            backup_fd = os.open(
                                backup_temp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | flags,
                                0o600, dir_fd=fd)
                            break
                        except FileExistsError:
                            backup_number += 1
                    try:
                        payload = contents
                        while payload:
                            written = os.write(backup_fd, payload)
                            payload = payload[written:]
                        os.fsync(backup_fd)
                    finally:
                        os.close(backup_fd)
                    os.rename(backup_temp_name, backup_name, src_dir_fd=fd, dst_dir_fd=fd)
                if valid:
                    converted = b"\n".join(legacy_parts[:-1]) + b"\n"
                    temp_prefix = f".{os.path.basename(leaf)}.legacy-migration.{os.getpid()}"
                    temp_number = 0
                    while True:
                        temp_name = f"{temp_prefix}.{temp_number}"
                        try:
                            temp_fd = os.open(
                                temp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | flags,
                                0o600, dir_fd=fd)
                            break
                        except FileExistsError:
                            temp_number += 1
                    try:
                        payload = converted
                        while payload:
                            written = os.write(temp_fd, payload)
                            payload = payload[written:]
                        os.fsync(temp_fd)
                    finally:
                        os.close(temp_fd)
                    os.rename(temp_name, leaf, src_dir_fd=fd, dst_dir_fd=fd)
                    os.close(file_fd)
                    file_fd = os.open(leaf, file_flags, 0o600, dir_fd=fd)
                    contents = converted
            elif not (b"\n" in contents):
                migration_blocked = True
                report("invalid framing; left unchanged")

        if not migration_blocked and line not in contents.split(b"\n"):
            payload = line + b"\n"
            while payload:
                written = os.write(file_fd, payload)
                payload = payload[written:]
        os.close(file_fd)
    finally:
        os.close(lock_fd)
finally:
    os.close(fd)
PY
}

# Publish one parent-facing line from <home>. See the return codes above.
fm_parent_channel_report() {  # <home> <state> <line>
  local home=$1 state=$2 line=$3 destination rc=0
  destination=$(fm_parent_channel_destination "$home" "$state") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_parent_channel_append_once "$destination" "$line" || return 4
}
