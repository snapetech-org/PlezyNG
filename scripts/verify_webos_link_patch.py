#!/usr/bin/env python3
"""Permit only pinned Flutter interface and static worker atomic link repairs."""
import argparse
import re
import subprocess
from pathlib import Path

CMAKE_PATH = "webos/CMakeLists.txt"
ANCHOR = 'include(${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/webos_build.cmake)\n'
LINK = 'target_link_libraries(${BINARY_NAME} PRIVATE flutter)\n'
WORKER_ANCHOR = 'add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native/games/romm" "${CMAKE_CURRENT_BINARY_DIR}/romm_native")\n'
ATOMIC_LINKS = ('target_link_libraries(plezy_retro PRIVATE "-Wl,-Bstatic" atomic "-Wl,-Bdynamic")\n'
                'target_link_libraries(plezy_retro_worker PRIVATE "-Wl,-Bstatic" atomic "-Wl,-Bdynamic")\n')


def equivalent(before, after):
    # Changes are additive exact link statements at known existing targets.
    # Never normalize arbitrary CMake or allow link removal/replacement.
    candidates = {before}
    if before.count(ANCHOR) == 1 and LINK not in before:
        candidates.add(before.replace(ANCHOR, ANCHOR + LINK, 1))
    for candidate in tuple(candidates):
        if candidate.count(WORKER_ANCHOR) == 1 and ATOMIC_LINKS not in candidate:
            candidates.add(candidate.replace(WORKER_ANCHOR, WORKER_ANCHOR + ATOMIC_LINKS, 1))
    return after in candidates


def verify_local(root, source, target):
    if not all(re.fullmatch(r"[a-f0-9]{40}", revision) for revision in (source, target)):
        raise ValueError("Full immutable source revisions are required")
    contents = [subprocess.check_output(["git", "show", f"{revision}:{CMAKE_PATH}"], cwd=root).decode()
                for revision in (source, target)]
    if not equivalent(*contents):
        raise ValueError("webOS CMake changed beyond the pinned Flutter/static atomic link repairs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("target")
    args = parser.parse_args()
    verify_local(Path(__file__).resolve().parents[1], args.source, args.target)
