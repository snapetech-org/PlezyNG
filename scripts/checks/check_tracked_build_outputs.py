#!/usr/bin/env python3
"""Reject generated Flutter package build directories in the source tree."""
from pathlib import Path, PurePosixPath
import subprocess
import sys


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    invalid = []
    for name in tracked:
        parts = PurePosixPath(name).parts
        if parts and parts[0] == "packages" and "build" in parts[2:-1]:
            invalid.append(name)
    if invalid:
        print("Generated package build output is tracked:\n" + "\n".join(invalid), file=sys.stderr)
        return 1
    print("No generated package build output is tracked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
