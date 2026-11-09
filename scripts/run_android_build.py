#!/usr/bin/env python3
"""Run a release build with resource heartbeats and bounded JVM diagnostics."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def diagnostics():
    # Process names only: signing arguments and environment must never be dumped.
    commands = [["ps", "-u", str(os.getuid()), "-o", "pid,ppid,etimes,pcpu,rss,comm"]]
    for entry in Path("/proc").iterdir():
        try:
            if entry.name.isdigit() and entry.stat().st_uid == os.getuid() and (entry / "comm").read_text().strip() == "java":
                commands.append(["jcmd", entry.name, "Thread.print", "-l"])
        except (OSError, ProcessLookupError):
            continue
    for command in commands:
        try:
            subprocess.run(command, timeout=20, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Android build diagnostics unavailable: {type(error).__name__}", flush=True)


def run(command, *, interval=60, diagnose_every=600):
    started = time.monotonic()
    next_diagnostics = started + diagnose_every
    child = subprocess.Popen(command, start_new_session=True)
    previous = {}

    def forward(signum, _frame):
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous[signum] = signal.signal(signum, forward)
    try:
        while True:
            try:
                result = child.wait(timeout=interval)
                return result if result >= 0 else 128 - result
            except subprocess.TimeoutExpired:
                now = time.monotonic()
                print(f"Android build still running: {int(now - started)} seconds elapsed", flush=True)
                if now >= next_diagnostics:
                    diagnostics()
                    next_diagnostics = time.monotonic() + diagnose_every
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: run_android_build.py COMMAND [ARG ...]")
    raise SystemExit(run(sys.argv[1:]))
