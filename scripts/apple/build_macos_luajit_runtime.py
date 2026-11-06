#!/usr/bin/env python3
"""Keep the pinned LuaJIT unwinder in its own macOS image.

SwiftPM verifies and selects the original XCFramework. Repackage that exact
archive rather than rebuilding LuaJIT or changing the production engine pin.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
NAME = "libplezy_luajit.dylib"


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    if os.environ.get("PLATFORM_NAME") != "macosx":
        raise SystemExit("LuaJIT dynamic isolation is only required on macOS.")
    architectures = os.environ["ARCHS"].split()
    if not architectures or set(architectures) - {"arm64", "x86_64"}:
        raise SystemExit("Unsupported macOS LuaJIT architecture selection.")
    archive = Path(os.environ["BUILT_PRODUCTS_DIR"]) / "Libluajit.framework/Libluajit"
    if not archive.is_file():
        raise SystemExit(f"SwiftPM's selected pinned LuaJIT archive is missing: {archive}")
    headers = {
        "LuaJIT-luajit.h": archive.parent / "Headers/luajit-2.1/luajit.h",
        "Lua-lua.h": archive.parent / "Headers/luajit-2.1/lua.h",
    }
    for path in headers.values():
        if not path.is_file():
            raise SystemExit(f"Pinned LuaJIT copyright notice header is missing: {path}")
    for arch in architectures:
        run("xcrun", "lipo", "-verify_arch", arch, str(archive))
    work = Path(os.environ["DERIVED_FILE_DIR"]) / "plezy-luajit"
    work.mkdir(parents=True, exist_ok=True)
    library = work / NAME
    sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-path")
    command = ["xcrun", "--sdk", "macosx", "clang", "-dynamiclib"]
    for arch in architectures:
        command.extend(["-arch", arch])
    command.extend([
        "-isysroot", sdk,
        "-mmacosx-version-min=" + os.environ["MACOSX_DEPLOYMENT_TARGET"],
        "-Xlinker", "-force_load", "-Xlinker", str(archive),
        "-Xlinker", "-install_name", "-Xlinker", "@rpath/" + NAME,
        "-o", str(library),
    ])
    subprocess.run(command, check=True)
    for arch in architectures:
        run("xcrun", "lipo", "-verify_arch", arch, str(library))

    app = Path(os.environ["TARGET_BUILD_DIR"])
    embedded = app / os.environ["FRAMEWORKS_FOLDER_PATH"] / NAME
    embedded.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(library, embedded)
    if os.environ.get("CODE_SIGNING_ALLOWED", "YES") == "YES":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        subprocess.run([
            "codesign", "--force", "--sign", identity, "--options", "runtime",
            "--timestamp=none" if identity == "-" else "--timestamp", str(embedded),
        ], check=True)
        run("codesign", "--verify", "--strict", str(embedded))

    # Keep the source archive and compiled engine receipt unchanged. This is a
    # checksum-bound packaging adapter, with normal compact unwind in each image.
    receipt = {
        "schemaVersion": 1,
        "purpose": "isolate LuaJIT personality from Objective-C/C++/Rust app unwinders",
        "nativeLockSha256": digest(ROOT / "mpv-build.lock.json"),
        "inputArchiveSha256": digest(archive),
        "architectures": architectures,
        "deploymentTarget": os.environ["MACOSX_DEPLOYMENT_TARGET"],
        "installName": "@rpath/" + NAME,
        "linkLibrarySha256": digest(library),
        "embeddedLibrarySha256": digest(embedded),
        "notices": {name: digest(path) for name, path in headers.items()},
        "buildCommand": command,
    }
    notices = app / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "playback-notices"
    notices.mkdir(parents=True, exist_ok=True)
    for name, path in headers.items():
        shutil.copy2(path, notices / name)
    (notices / "luajit-runtime.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Built and embedded isolated pinned LuaJIT runtime: {embedded}")


if __name__ == "__main__":
    main()
