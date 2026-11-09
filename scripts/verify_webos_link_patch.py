#!/usr/bin/env python3
"""Permit only the direct, already-pinned Flutter interface link repair."""
import argparse
import re
import subprocess
from pathlib import Path

CMAKE_PATH = "webos/CMakeLists.txt"
ANCHOR = 'include(${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/webos_build.cmake)\n'
LINK = 'target_link_libraries(${BINARY_NAME} PRIVATE flutter)\n'


def equivalent(before, after):
    return before == after or (before.count(ANCHOR) == 1 and LINK not in before
                               and after == before.replace(ANCHOR, ANCHOR + LINK, 1))


def verify_local(root, source, target):
    if not all(re.fullmatch(r"[a-f0-9]{40}", revision) for revision in (source, target)):
        raise ValueError("Full immutable source revisions are required")
    contents = [subprocess.check_output(["git", "show", f"{revision}:{CMAKE_PATH}"], cwd=root).decode()
                for revision in (source, target)]
    if not equivalent(*contents):
        raise ValueError("webOS CMake changed beyond the direct existing Flutter/common link repair")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("target")
    args = parser.parse_args()
    verify_local(Path(__file__).resolve().parents[1], args.source, args.target)
