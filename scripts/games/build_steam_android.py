#!/usr/bin/env python3
"""Build/inspect the real Steam JNI receiver with the repository-pinned Android NDK.

This checks native linking, ABI, JNI exports and ELF page alignment. Gradle app
packaging, shrinking and device execution remain separate build-agent gates.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import prepare_android_sdk as sdk_tools  # noqa: E402

ABIS = {"arm64-v8a": "AArch64", "armeabi-v7a": "ARM", "x86": "Intel 80386",
        "x86_64": "Advanced Micro Devices X86-64"}


def pins() -> tuple[str, str, int]:
    source = (ROOT / "android/steam/build.gradle").read_text()
    values = []
    for pattern in (r"ndkVersion\s+['\"]([0-9.]+)['\"]", r"\bversion\s+['\"]([0-9.]+)['\"]", r"\bminSdk\s+(\d+)"):
        matches = re.findall(pattern, source)
        if len(matches) != 1:
            raise ValueError("Review the Steam Gradle SDK pins before using this builder")
        values.append(matches[0])
    return values[0], values[1], int(values[2])


def inspect_elf(text: str, abi: str, exports: set[str]) -> None:
    machine = re.search(r"^\s*Machine:\s*(.+)$", text, re.MULTILINE)
    if machine is None or machine[1].strip() != ABIS[abi]:
        raise ValueError(f"JNI receiver ELF machine does not match {abi}")
    loads = re.findall(r"^\s*LOAD\s+.*\s+(0x[0-9a-fA-F]+)\s*$", text, re.MULTILINE)
    alignment = 16384 if abi in ("arm64-v8a", "x86_64") else 4096
    if not loads or any(int(value, 16) < alignment for value in loads):
        raise ValueError(f"JNI receiver needs {alignment}-byte ELF LOAD alignment for {abi}")
    if re.search(r"\((?:TEXTREL|RPATH|RUNPATH)\)", text):
        raise ValueError("JNI receiver contains text relocations or a runtime search path")
    symbols = set(re.findall(r"^\s*\d+:.*\b(?:GLOBAL|WEAK)\s+DEFAULT\s+(?!UND\b)\S+\s+(\S+)\s*$", text, re.MULTILINE))
    missing = exports - symbols
    if missing:
        raise ValueError("JNI receiver lacks exported methods: " + ", ".join(sorted(missing)))


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
    parser.add_argument("--sdk-root", type=Path)
    parser.add_argument("--abi", action="append", choices=ABIS, help="Repeat for selected ABIs; defaults to all four")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/steam-android-sdk")
    parser.add_argument("--parallel", type=int, default=2)
    parser.add_argument("--inspect-only", action="store_true", help="Inspect existing binaries without claiming a new build")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.parallel <= 16 or (args.abi and len(set(args.abi)) != len(args.abi)):
        parser.error("Use 1..16 build workers and distinct ABIs")
    env = dict(os.environ)
    if args.sdk_root:
        env["ANDROID_SDK_ROOT"] = str(args.sdk_root)
    report = {"schema": 1, "status": "running", "applicationBuilt": False, "deviceTested": False,
              "buildInvoked": not args.inspect_only, "artifacts": []}
    write_report(args.report, report)
    try:
        sdk = sdk_tools.sdk_root(env)
        ndk_version, cmake_version, api = pins()
        sdk_tools.verify_packages(sdk, [f"ndk;{ndk_version}", f"cmake;{cmake_version}"])
        suffix = ".exe" if platform.system() == "Windows" else ""
        host = {"Linux": "linux-x86_64", "Darwin": "darwin-x86_64", "Windows": "windows-x86_64"}[platform.system()]
        ndk = sdk / "ndk" / ndk_version
        cmake = sdk / "cmake" / cmake_version / "bin" / f"cmake{suffix}"
        ninja = cmake.with_name(f"ninja{suffix}")
        readelf = ndk / f"toolchains/llvm/prebuilt/{host}/bin/llvm-readelf{suffix}"
        native_java = (ROOT / "android/steam/src/main/java/org/snapetech/plezyng/games/steam/NativeSteam.java").read_text()
        methods = re.findall(r"\bstatic\s+native\s+[\w\[\]]+\s+(\w+)\s*\(", native_java)
        if not methods:
            raise ValueError("No NativeSteam JNI contract was found")
        exports = {"JNI_OnLoad", *("Java_org_snapetech_plezyng_games_steam_NativeSteam_" + name for name in methods)}
        report.update(commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                      dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)),
                      ndk=ndk_version, cmake=cmake_version, androidApi=api)
        if not args.inspect_only:
            subprocess.run([sys.executable, str(ROOT / "scripts/games/prepare_steam.py")], cwd=ROOT, check=True)
        for abi in args.abi or ABIS:
            directory = args.build_dir.resolve() / abi
            if not args.inspect_only:
                subprocess.run([str(cmake), "-S", str(ROOT / "native/games/steam"), "-B", str(directory), "-G", "Ninja",
                                f"-DCMAKE_TOOLCHAIN_FILE={ndk / 'build/cmake/android.toolchain.cmake'}",
                                f"-DCMAKE_MAKE_PROGRAM={ninja}", f"-DANDROID_ABI={abi}", f"-DANDROID_PLATFORM=android-{api}",
                                "-DANDROID_STL=c++_shared", "-DCMAKE_BUILD_TYPE=Release", "-DPLEZY_STEAM_TESTS=OFF",
                                "-DPLEZY_STEAM_GSTREAMER=OFF"], cwd=ROOT, check=True)
                subprocess.run([str(cmake), "--build", str(directory), "--target", "plezy_steam", "--parallel", str(args.parallel)],
                               cwd=ROOT, check=True)
            binary = directory / "libplezy_steam.so"
            detail = subprocess.check_output([str(readelf), "--wide", "--file-header", "--program-headers", "--dynamic", "--dyn-syms", str(binary)], text=True)
            inspect_elf(detail, abi, exports)
            report["artifacts"].append({"abi": abi, "path": str(binary), "bytes": binary.stat().st_size,
                                         "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "elfChecked": True,
                                         "jniExportsChecked": len(exports)})
        report["status"] = "passed"
        write_report(args.report, report)
    except Exception as error:
        report.update(status="failed", error=str(error))
        write_report(args.report, report)
        raise
    print(f"Verified {len(report['artifacts'])} Android JNI receiver ABIs; report: {args.report}")


if __name__ == "__main__":
    main()
