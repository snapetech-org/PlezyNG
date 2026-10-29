#!/usr/bin/env python3
"""Check Linux Steam receiver development/runtime packages without installing them.

Run with the native build agent's pkg-config environment. A passing SDK receipt
does not qualify its display, GPU, audio device or application package.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = {"gtk+-3.0": "3.22", "libsecret-1": "0.18", "libevdev": "1.0",
            "wayland-client": "1.18", "wayland-egl": "1.18", "egl": "1.4",
            "gstreamer-app-1.0": "1.20", "gstreamer-video-1.0": "1.20", "vulkan": "1.1"}
ELEMENTS = ("appsink", "appsrc", "videoconvert", "audioconvert", "audioresample", "autoaudiosrc",
            "autoaudiosink", "h264parse", "h265parse", "avdec_h264", "avdec_h265", "openh264enc", "videotestsrc")
APT_PACKAGES = ("build-essential", "clang", "cmake", "ninja-build", "pkg-config", "python3-jinja2",
                "libgtk-3-dev", "libsecret-1-dev", "libevdev-dev", "libwayland-dev", "libegl-dev", "libvulkan-dev",
                "mesa-vulkan-drivers", "libgstreamer1.0-dev", "libgstreamer-plugins-base1.0-dev", "gstreamer1.0-tools",
                "gstreamer1.0-plugins-base", "gstreamer1.0-plugins-good", "gstreamer1.0-plugins-bad", "gstreamer1.0-libav")


def inspect() -> dict:
    result = {"schema": 1, "status": "running", "packages": {}, "tools": {}, "errors": [],
              "applicationBuilt": False, "gpuQualified": False}

    def query(label: str, args: list[str]) -> str | None:
        try:
            return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.STDOUT, timeout=30).strip()
        except (OSError, subprocess.SubprocessError):
            result["errors"].append(label)
            return None

    for name, minimum in PACKAGES.items():
        if query(f"{name} >= {minimum}", ["pkg-config", f"--atleast-version={minimum}", name]) is not None:
            result["packages"][name] = query(name, ["pkg-config", "--modversion", name])
    for name in ("cmake", "ninja", "c++"):
        version = query(name, [name, "--version"])
        if version:
            result["tools"][name] = version.splitlines()[0]
    cmake = re.search(r"cmake version (\d+)\.(\d+)", result["tools"].get("cmake", ""))
    if not cmake or tuple(map(int, cmake.groups())) < (3, 22):
        result["errors"].append("CMake >= 3.22")
    query("Python Jinja2 shader generator", [sys.executable, "-c", "import jinja2; print(jinja2.__version__)"])
    for element in ELEMENTS:
        query(f"GStreamer element {element}", ["gst-inspect-1.0", "--exists", element])
    result["commit"] = query("source commit", ["git", "rev-parse", "HEAD"])
    dirty = query("source worktree", ["git", "status", "--porcelain"])
    result["dirty"] = bool(dirty)
    result["status"] = "failed" if result["errors"] else "passed"
    return result


def write_report(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.{uuid.uuid4().hex}.pending")
    try:
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apt-packages", action="store_true", help="Print Ubuntu/Debian receiver prerequisites only")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.apt_packages:
        print(" ".join(APT_PACKAGES))
        return
    if platform.system() != "Linux" or not args.report:
        parser.error("Use a native Linux builder and --report")
    write_report(args.report, {"schema": 1, "status": "running", "applicationBuilt": False, "gpuQualified": False})
    result = inspect()
    write_report(args.report, result)
    if result["errors"]:
        raise SystemExit("Missing Linux receiver prerequisites: " + ", ".join(result["errors"]))
    print(f"Linux receiver SDK prerequisites checked; report: {args.report}")


if __name__ == "__main__":
    main()
