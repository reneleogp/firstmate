#!/usr/bin/env python3
"""A semantic stand-in for launchctl, for hosts that have no launchd.

It models the behavior bin/fm-telegram.py actually depends on, and nothing
else:

  bootstrap <domain> <plist>  refuses a label already in the domain and a
                              disabled label, reads the plist with plistlib,
                              and starts ProgramArguments exactly once when
                              RunAtLoad is set, with EnvironmentVariables
                              applied over the environment
  bootout <target>            asks the job to stop and returns EINPROGRESS
                              while its process is still alive, the way launchd
                              tears a job down asynchronously
  print <target>              the loaded job's path, state, pid, and last exit
                              code, or "could not find" when it is not loaded
  print-disabled <domain>     the persistent per-label disable records
  enable|disable <target>     write those records

Deliberately not modelled, because nothing under test relies on it: KeepAlive
restarts, throttling, per-session domains, and job labels other than the one
bootstrapped here. State lives in the JSON file named by FM_FAKE_LAUNCHD_STATE.
"""

from __future__ import annotations

import json
import os
import plistlib
import signal
import subprocess
import sys
from pathlib import Path
from typing import Any

EX_NO_SUCH_PROCESS = 3
EX_ALREADY_LOADED = 37
EX_IN_PROGRESS = 36
EX_NOT_FOUND = 113
EX_DISABLED = 112


def state_path() -> Path:
    value = os.environ.get("FM_FAKE_LAUNCHD_STATE")
    if not value:
        print("FM_FAKE_LAUNCHD_STATE is not set", file=sys.stderr)
        raise SystemExit(2)
    return Path(value)


def exits_dir() -> Path:
    return state_path().with_name(state_path().name + ".exits")


def load_state() -> dict[str, Any]:
    try:
        data = json.loads(state_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        data = {}
    data.setdefault("jobs", {})
    data.setdefault("disabled", {})
    data.setdefault("launches", [])
    return data


def save_state(state: dict[str, Any]) -> None:
    state_path().write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")


def alive(pid: Any) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def reconcile(state: dict[str, Any]) -> None:
    """Catch up with reality before answering anything about a job."""
    for label, job in list(state["jobs"].items()):
        pid = job.get("pid")
        if pid is None or alive(pid):
            continue
        job["pid"] = None
        job["state"] = "not running"
        if job.get("exiting"):
            del state["jobs"][label]
            continue
        if job.get("last_exit") is None:
            job["last_exit"] = collect_exit(pid)


def collect_exit(pid: int) -> Any:
    """What the supervisor recorded, or None while it has not recorded yet."""
    try:
        return int((exits_dir() / str(pid)).read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def label_of(target: str) -> str:
    return target.rsplit("/", 1)[-1]


def launch(job_plist: dict[str, Any], path: str, state: dict[str, Any]) -> int:
    """Start the job once, with something watching how it ends.

    launchd is a job's real parent, so a fake that only spawns and walks away
    could never report an exit code and every failed start would look like a
    slow one. A supervisor stays behind for exactly that.
    """
    arguments = job_plist.get("ProgramArguments")
    if not isinstance(arguments, list) or not arguments:
        print("plist has no ProgramArguments", file=sys.stderr)
        raise SystemExit(1)
    environment = dict(os.environ)
    for key, value in (job_plist.get("EnvironmentVariables") or {}).items():
        environment[str(key)] = str(value)
    log = job_plist.get("StandardErrorPath") or os.devnull
    read_fd, write_fd = os.pipe()
    supervisor = os.fork()
    if supervisor == 0:
        code = 0
        try:
            os.close(read_fd)
            os.setsid()
            # launchctl's own caller must not wait on this supervisor's inherited
            # standard streams; the job's output goes to its configured log.
            devnull = os.open(os.devnull, os.O_RDWR)
            for descriptor in (0, 1, 2):
                os.dup2(devnull, descriptor)
            os.close(devnull)
            with open(log, "ab", buffering=0) as handle:
                process = subprocess.Popen(
                    [str(argument) for argument in arguments], env=environment,
                    stdin=subprocess.DEVNULL, stdout=handle, stderr=handle,
                )
            os.write(write_fd, f"{process.pid}\n".encode())
            os.close(write_fd)
            status = process.wait()
            exits_dir().mkdir(parents=True, exist_ok=True)
            (exits_dir() / str(process.pid)).write_text(
                str(status if status >= 0 else 128 - status), encoding="utf-8"
            )
        except OSError:
            code = 1
        finally:
            os._exit(code)
    os.close(write_fd)
    with os.fdopen(read_fd, encoding="utf-8") as reader:
        pid = int(reader.readline().strip())
    state["launches"].append({"label": job_plist.get("Label"), "pid": pid, "path": path})
    return pid


def command_bootstrap(arguments: list[str], state: dict[str, Any]) -> int:
    if len(arguments) < 2:
        return 2
    path = arguments[1]
    try:
        data = plistlib.loads(Path(path).read_bytes())
    except (OSError, ValueError) as error:
        print(f"Could not read {path}: {error}", file=sys.stderr)
        return 1
    label = str(data.get("Label"))
    if label in state["jobs"]:
        print(f"Bootstrap failed: {EX_ALREADY_LOADED}: Service already loaded",
              file=sys.stderr)
        return EX_ALREADY_LOADED
    if state["disabled"].get(label):
        print(f"Bootstrap failed: {EX_DISABLED}: Service is disabled", file=sys.stderr)
        return EX_DISABLED
    pid = launch(data, path, state) if data.get("RunAtLoad") else None
    state["jobs"][label] = {
        "path": path,
        "pid": pid,
        "state": "running" if pid else "not running",
        "last_exit": None,
        "exiting": False,
    }
    return 0


def command_bootout(arguments: list[str], state: dict[str, Any]) -> int:
    label = label_of(arguments[0]) if arguments else ""
    job = state["jobs"].get(label)
    if job is None:
        print(f"Boot-out failed: {EX_NO_SUCH_PROCESS}: No such process", file=sys.stderr)
        return EX_NO_SUCH_PROCESS
    job["exiting"] = True
    pid = job.get("pid")
    if alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        # launchd tears a job down asynchronously; the caller has to wait for it.
        print(f"Boot-out failed: {EX_IN_PROGRESS}: Operation now in progress",
              file=sys.stderr)
        return EX_IN_PROGRESS
    del state["jobs"][label]
    return 0


def command_print(arguments: list[str], state: dict[str, Any]) -> int:
    label = label_of(arguments[0]) if arguments else ""
    job = state["jobs"].get(label)
    if job is None:
        print(f"Could not find service \"{label}\" in domain", file=sys.stderr)
        return EX_NOT_FOUND
    exit_code = job.get("last_exit")
    print(f"{label} = {{")
    print(f"\tpath = {job['path']}")
    print(f"\tstate = {job.get('state') or 'unknown'}")
    if job.get("pid"):
        print(f"\tpid = {job['pid']}")
    print("\tlast exit code = "
          f"{exit_code if exit_code is not None else '(never exited)'}")
    print("}")
    return 0


def command_print_disabled(_arguments: list[str], state: dict[str, Any]) -> int:
    print("disabled services = {")
    for label, disabled in sorted(state["disabled"].items()):
        print(f"\t\"{label}\" => {'true' if disabled else 'false'}")
    print("}")
    return 0


def command_enable(arguments: list[str], state: dict[str, Any]) -> int:
    state["disabled"][label_of(arguments[0])] = False
    return 0


def command_disable(arguments: list[str], state: dict[str, Any]) -> int:
    state["disabled"][label_of(arguments[0])] = True
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        return 2
    state = load_state()
    reconcile(state)
    handlers = {
        "bootstrap": command_bootstrap,
        "bootout": command_bootout,
        "print": command_print,
        "print-disabled": command_print_disabled,
        "enable": command_enable,
        "disable": command_disable,
    }
    handler = handlers.get(argv[0])
    if handler is None:
        print(f"unsupported launchctl subcommand: {argv[0]}", file=sys.stderr)
        save_state(state)
        return 2
    try:
        return handler(argv[1:], state)
    finally:
        save_state(state)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
