#!/usr/bin/env python3
"""Patch the warning-suppression unsafe flag from the pinned AMSMB2 checkout."""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


EXPECTED_VERSION = "3.0.0"
EXPECTED_REVISION = "fbb1d37880b7e1d7504c6a6dc9371c10ff932bc9"
UNSAFE_BLOCK = '''                .unsafeFlags([
                    "-Wno-everything",
                ]),
'''


def fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


def replace_text_atomically(path: Path, contents: str) -> None:
    if path.is_symlink():
        raise OSError(f"refusing to replace manifest symlink: {path}")

    permissions = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(contents)
        temporary.chmod(permissions)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-packages-dir", required=True, type=Path)
    parser.add_argument("--resolved-package", required=True, type=Path)
    args = parser.parse_args()

    try:
        lock = json.loads(args.resolved_package.read_text(encoding="utf-8"))
        pins = [pin for pin in lock["pins"] if pin["identity"].casefold() == "amsmb2"]
        if len(pins) != 1:
            return fail(f"expected one AMSMB2 pin in {args.resolved_package}")
        state = pins[0]["state"]
        if state.get("version") != EXPECTED_VERSION or state.get("revision") != EXPECTED_REVISION:
            return fail(
                "refusing to patch an unexpected AMSMB2 version/revision: "
                f"{state.get('version')} {state.get('revision')}"
            )

        checkouts = args.source_packages_dir / "checkouts"
        matches = [
            path for path in checkouts.iterdir()
            if path.is_dir() and path.name.casefold() == "amsmb2"
        ]
        if len(matches) != 1:
            return fail(f"expected one AMSMB2 checkout under {checkouts}")
        checkout = matches[0]
        revision = subprocess.check_output(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
        ).strip()
        if revision != EXPECTED_REVISION:
            return fail(f"AMSMB2 checkout revision {revision} does not match the locked pin")

        manifest = checkout / "Package.swift"
        contents = manifest.read_text(encoding="utf-8")
        if UNSAFE_BLOCK in contents:
            patched = contents.replace(UNSAFE_BLOCK, "", 1)
            if ".unsafeFlags(" in patched:
                return fail("AMSMB2 manifest has additional unsafe flags; review the new source")
            replace_text_atomically(manifest, patched)
        elif ".unsafeFlags(" in contents:
            return fail("AMSMB2 manifest has unexpected unsafe flags; review the new source")

        print(
            "AMSMB2 source verified at "
            f"{EXPECTED_VERSION} ({EXPECTED_REVISION}); removed only -Wno-everything"
        )
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        return fail(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
