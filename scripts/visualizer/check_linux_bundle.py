#!/usr/bin/env python3
"""Fail a Linux package if its native visualizer cannot receive mpv audio."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
TAP_SYMBOLS = {
    "mpv_plezy_audio_tap_version",
    "mpv_plezy_audio_tap_enable",
    "mpv_plezy_audio_tap_read",
    "mpv_plezy_audio_tap_read_next",
}


def check(bundle: Path) -> None:
    bundle = bundle.resolve(strict=True)
    library = (bundle / "lib/libmpv.so.2").resolve(strict=True)
    if not library.is_relative_to(bundle / "lib") or library.read_bytes()[:4] != b"\x7fELF":
        raise ValueError("The bundled libmpv is missing or points outside the bundle")
    symbols = subprocess.check_output(["nm", "-D", "--defined-only", str(library)], text=True)
    exported = {line.rsplit(" ", 1)[-1].split("@", 1)[0] for line in symbols.splitlines()}
    missing = TAP_SYMBOLS - exported
    if missing:
        raise ValueError(f"The bundled libmpv lacks music PCM tap exports: {', '.join(sorted(missing))}")

    runtime = bundle / "lib/libmilkrust_native.so"
    helper = bundle / "plezy_visualizer_helper"
    source = bundle / "data/visualizer-notices/source/milkrust-source.tar.gz"
    starter = bundle / "data/flutter_assets/assets/visualizer/milkrust-sample-pack-0.1.0.rmpack"
    receipt = bundle / "data/visualizer-notices/milkrust-build.json"
    notices = bundle / "data/visualizer-notices/MILKRUST-NOTICES.txt"
    for path in (runtime, helper, source, starter, receipt, notices):
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"The visualizer bundle is missing {path.relative_to(bundle)}")
    if runtime.read_bytes()[:4] != b"\x7fELF" or not os.access(helper, os.X_OK):
        raise ValueError("The native renderer or helper is not executable")
    expected = json.loads((ROOT / "native/visualizer/sources.lock.json").read_text())["milkrust"]["commit"]
    built = json.loads(receipt.read_text())["sourceRevision"]
    if built != expected:
        raise ValueError("The bundled MilkRust runtime differs from the application source pin")
    print(f"Linux visualizer bundle verified: MilkRust {built[:12]}, PCM tap and offline starter pack")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    try:
        check(args.bundle)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Linux visualizer bundle failed: {error}", file=sys.stderr)
        raise SystemExit(1)
