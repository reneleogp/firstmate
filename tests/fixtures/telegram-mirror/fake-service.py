#!/usr/bin/env python3
"""A stand-in for the mirror bot inside the fake launchd.

The real bot is what the readiness tests launch. This fixture exists only for
the two shapes the real bot cannot be asked to take on demand: a start that
fails, and a process that ignores the polite stop. FM_TELEGRAM_FAKE_MODE picks
one:

  ready  publish the readiness marker the installer waits for, then idle
  stale  publish a marker naming a DIFFERENT launch generation, then idle
  wedge  publish the marker, ignore SIGTERM, and outlast the bounded stop
  fail   exit nonzero without ever becoming ready

The marker it writes is the same contract the bot publishes: the launch
generation this process was given, and its own pid.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from pathlib import Path


def publish(launch_id: str) -> None:
    home = Path(os.environ["FM_TELEGRAM_DIR"])
    home.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"launch_id": launch_id, "pid": os.getpid()})
    (home / "service-ready.json").write_text(payload, encoding="utf-8")


def main() -> int:
    mode = os.environ.get("FM_TELEGRAM_FAKE_MODE", "ready")
    if mode == "fail":
        print("fixture: this service refuses to start", file=sys.stderr)
        return 3
    if mode == "stale":
        publish("a-generation-that-was-never-launched")
    else:
        publish(os.environ.get("FM_TELEGRAM_LAUNCH_ID", ""))
    if mode == "wedge":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(600)
    return 0


if __name__ == "__main__":
    sys.exit(main())
