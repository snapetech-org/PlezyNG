#!/usr/bin/env python3
"""Sync all native pins to verified fork main, or reject a stale build pin."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REPO = "snapetech-org/mpv-build"
URL = f"https://github.com/{REPO}.git"
GROUPS = ("apple", "android", "linux", "windows")


def command(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def sync(root: Path, producer: Path, *, check: bool) -> str:
    """Verify the producer before invoking the atomic, receipt-aware pin writer."""
    revision = command("git", "rev-parse", "HEAD", cwd=producer)
    lock = json.loads((root / "mpv-build.lock.json").read_text())
    if check and (lock.get("repo") != REPO or lock.get("commit") != revision):
        raise ValueError(
            f"Native pin {lock.get('repo')}@{lock.get('commit')} is behind "
            f"{REPO}/main@{revision}. Run python3 scripts/sync_native_revision.py, "
            "commit all pin changes, and validate that application revision. "
            "If already tagged, use the next release; never move the tag."
        )
    for group in GROUPS:
        print(command(sys.executable, "scripts/keys.py", "verify",
                      "--platform-group", group, cwd=producer), flush=True)
    # Do not write a pin after main advances during verification. A subsequent
    # build preflight checks again; an in-flight build keeps its immutable pin.
    latest = command("git", "ls-remote", URL, "refs/heads/main").split()[0]
    if latest != revision:
        raise ValueError("Native main advanced during verification; retry the sync.")
    if not check:
        # This checkout was cloned from the fork, so the existing writer derives
        # the correct repository, validates capability receipts, and moves all
        # Apple, Android and desktop lock sites together.
        print(command("bash", "scripts/set_native_revision.sh", revision,
                      "--repo", str(producer), cwd=root), flush=True)
    print(f"Native dependency is current: {REPO}@{revision}", flush=True)
    return revision


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="reject stale pins without changing application files")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="plezyng-native-sync-") as directory:
        producer = Path(directory) / "mpv-build"
        command("git", "clone", "--quiet", "--depth=1", "--filter=blob:none",
                "--single-branch", "--branch", "main", URL, str(producer))
        sync(ROOT, producer, check=args.check)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Native dependency preflight failed: {error}")
