#!/usr/bin/env python3
"""Prepare/probe the selected real Xcode SDK without changing xcode-select.

Run on an idle private Mac build agent. SDK selection is process-local. The
source probes compile actual receiver and controller sources, not SDK stubs.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import uuid

from build_steam_apple import PLATFORMS

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORKS = ("AVFoundation", "AudioToolbox", "CoreHaptics", "CoreMedia", "CoreVideo",
              "GameController", "IOSurface", "Metal", "Network", "QuartzCore", "Security", "VideoToolbox")


def target_triple(sdk: str, arch: str) -> str:
    if sdk not in PLATFORMS or arch not in ("arm64", "x86_64"):
        raise ValueError("Unsupported Apple SDK or architecture")
    if sdk in ("iphoneos", "appletvos") and arch != "arm64":
        raise ValueError("Apple device builds require arm64")
    deployment = PLATFORMS[sdk][2]
    family = "macosx" if sdk == "macosx" else "ios" if sdk.startswith("iphone") else "tvos"
    return f"{arch}-apple-{family}{deployment}" + ("-simulator" if sdk.endswith("simulator") else "")


def environment(developer: Path | None) -> dict[str, str]:
    result = dict(os.environ)
    if developer is not None:
        path = developer.expanduser().resolve()
        if path.suffix == ".app":
            path /= "Contents/Developer"
        if not (path / "usr/bin/xcodebuild").is_file():
            raise ValueError("--developer-dir must identify a complete Xcode installation")
        result["DEVELOPER_DIR"] = str(path)
    return result


def output(args: list[str], env: dict[str, str]) -> str:
    return subprocess.check_output(args, env=env, cwd=ROOT, text=True, timeout=90).strip()


def run(args: list[str], env: dict[str, str]) -> None:
    subprocess.run(args, env=env, cwd=ROOT, check=True)


def xcode_version(env: dict[str, str], required_build: str | None = None) -> str:
    version = output(["xcodebuild", "-version"], env)
    if not re.search(r"^Build version \S+$", version, re.MULTILINE):
        raise ValueError("Select a complete Xcode installation, not Command Line Tools alone")
    if required_build and f"Build version {required_build}" not in version.splitlines():
        raise ValueError("Selected Xcode build does not match --require-xcode-build")
    return version


def prepare(env: dict[str, str], sdk: str, simulator_version: str | None,
            required_build: str | None = None) -> None:
    # Full Xcode comes from Apple's developer download/App Store. The smaller
    # command-line-tools-only package does not provide iOS/tvOS SDKs.
    if simulator_version and (sdk not in ("iphonesimulator", "appletvsimulator")
                              or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", simulator_version)):
        raise ValueError("A pinned simulator runtime requires an iOS/tvOS simulator SDK")
    xcode_version(env, required_build)
    run(["xcodebuild", "-runFirstLaunch"], env)
    try:
        # Older Xcodes bundle Metal; newer Xcodes may supply a downloadable
        # component. Exercise the tool, since --find can return a placeholder.
        output(["xcrun", "--sdk", sdk, "metal", "--version"], env)
    except (OSError, subprocess.SubprocessError):
        run(["xcodebuild", "-downloadComponent", "metalToolchain"], env)
    if simulator_version:
        run(["xcodebuild", "-downloadPlatform", "iOS" if sdk == "iphonesimulator" else "tvOS",
             "-buildVersion", simulator_version], env)


def inspect(env: dict[str, str], sdk: str, arch: str, required_build: str | None = None) -> dict:
    triple = target_triple(sdk, arch)
    version = xcode_version(env, required_build)
    project = "macos" if sdk == "macosx" else "ios" if sdk.startswith("iphone") else "tvos"
    output(["plutil", "-lint", str(ROOT / project / "Runner.xcodeproj/project.pbxproj")], env)
    sdk_path = Path(output(["xcrun", "--sdk", sdk, "--show-sdk-path"], env))
    if not sdk_path.is_absolute() or not sdk_path.is_dir():
        raise ValueError("xcrun did not return an installed SDK directory")
    missing = [name for name in FRAMEWORKS if not (sdk_path / "System/Library/Frameworks" / f"{name}.framework").is_dir()]
    if missing:
        raise ValueError("Incomplete Apple SDK frameworks: " + ", ".join(missing))
    tools = {name: output(["xcrun", "--sdk", sdk, "--find", name], env)
             for name in ("clang++", "swiftc", "metal", "metallib", "libtool", "lipo")}
    # Finding a shim is insufficient: fail before the app build if its Metal
    # component still needs installation.
    metal_version = output(["xcrun", "--sdk", sdk, "metal", "--version"], env)
    cmake = shutil.which("cmake") or next((p for p in ("/opt/homebrew/bin/cmake", "/usr/local/bin/cmake") if Path(p).is_file()), None)
    if not cmake:
        raise ValueError("CMake 3.22+ is required by the Steam archive build phase")
    cmake_version = output([cmake, "--version"], env).splitlines()[0]
    match = re.fullmatch(r"cmake version (\d+)\.(\d+)(?:\..*)?", cmake_version)
    if not match or tuple(map(int, match.groups())) < (3, 22):
        raise ValueError("CMake 3.22+ is required by the Steam archive build phase")
    return {"schema": 1, "commit": output(["git", "rev-parse", "HEAD"], env),
            "dirty": bool(output(["git", "status", "--porcelain"], env)),
            "xcode": version, "sdk": sdk, "sdkPath": str(sdk_path),
            "sdkVersion": output(["xcrun", "--sdk", sdk, "--show-sdk-version"], env),
            "target": triple, "frameworks": list(FRAMEWORKS), "tools": tools, "cmake": cmake_version,
            "metal": metal_version,
            "projectSyntaxChecked": True, "sourceProbesPassed": False, "flutterAdapterChecked": False}


def application_shaders(converter: str, presenter: str) -> dict[str, str]:
    conversion = re.search(r'constexpr char convertShader\[\]\s*=\s*R"metal\((.*?)\)metal";', converter, re.DOTALL)
    presentation = re.search(r'static NSString\* shader\s*=\s*@((?:"(?:\\.|[^"\\])*"\s*)+);', presenter)
    if not conversion or not presentation:
        raise ValueError("Receiver shader declarations changed; update the SDK probe to compile their actual sources")
    # These C string literals use JSON-compatible escapes. Decode each fragment
    # instead of maintaining an independent copy of the production shader.
    fragments = re.findall(r'"(?:\\.|[^"\\])*"', presentation[1])
    return {"conversion": conversion[1], "presentation": "".join(json.loads(fragment) for fragment in fragments)}


def probe(report: dict, env: dict[str, str], flutter_framework: Path | None) -> None:
    run([os.sys.executable, str(ROOT / "scripts/games/prepare_steam.py")], env)
    source = ROOT / ".dart_tool/games/steam"
    includes = [ROOT / "native/games/steam", ROOT / "native/games/apple", source / "ihslib/include",
                source / "opus/include", source / "pyrowave/metal"]
    common = ["-target", report["target"], "-isysroot", report["sdkPath"], "-std=c++17", "-fobjc-arc",
              "-fsyntax-only", "-Werror=unguarded-availability", "-Werror=implicit-function-declaration"]
    for path in includes:
        common += ["-I", str(path)]
    checked = []
    for path in ("native/games/apple/SteamAppleSink.mm", "native/games/apple/SteamMetalPyrowave.mm",
                 "scripts/games/probes/apple_receiver.mm"):
        run([report["tools"]["clang++"], *common, str(ROOT / path)], env)
        checked.append(path)
    # This source is deliberately independent of Flutter, and is identical in
    # the iOS/tvOS and macOS plugin directories.
    swift = "packages/universal_gamepad/ios/Classes/GamepadEffects.swift"
    if (ROOT / swift).read_bytes() != (ROOT / "packages/universal_gamepad/macos/Classes/GamepadEffects.swift").read_bytes():
        raise ValueError("Apple controller effect implementations diverged; review both SDK probes")
    run([report["tools"]["swiftc"], "-typecheck", "-sdk", report["sdkPath"],
         "-target", report["target"], str(ROOT / swift)], env)
    checked.append(swift)
    if flutter_framework:
        framework = flutter_framework.resolve()
        expected = "FlutterMacOS.framework" if report["sdk"] == "macosx" else "Flutter.framework"
        if framework.name != expected or not (framework / "Headers").is_dir():
            raise ValueError("Supply the matching device/simulator Flutter framework directory")
        run([report["tools"]["clang++"], *common, "-F", str(framework.parent),
             str(ROOT / "native/games/apple/PlezySteamPlugin.mm")], env)
        report["flutterAdapterChecked"] = True
        checked.append("native/games/apple/PlezySteamPlugin.mm")
    with tempfile.TemporaryDirectory(prefix="plezy-steam-metal-") as temporary:
        shaders = application_shaders((ROOT / "native/games/apple/SteamMetalPyrowave.mm").read_text(),
                                      (ROOT / "native/games/apple/PlezySteamPlugin.mm").read_text())
        objects = []
        for name, code in shaders.items():
            source, air = Path(temporary) / f"{name}.metal", Path(temporary) / f"{name}.air"
            source.write_text(code)
            run(["xcrun", "--sdk", report["sdk"], "metal", "-c", str(source), "-o", str(air)], env)
            objects.append(str(air))
        library = Path(temporary) / "receiver.metallib"
        run(["xcrun", "--sdk", report["sdk"], "metallib", *objects, "-o", str(library)], env)
        if not library.is_file() or library.stat().st_size == 0:
            raise ValueError("Metal SDK did not produce a library")
    report.update(sourceProbesPassed=True, checkedSources=checked, metalShadersChecked=list(shaders))


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
    parser.add_argument("action", choices=("check", "prepare", "probe"))
    parser.add_argument("--sdk", choices=PLATFORMS, required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
    parser.add_argument("--developer-dir", type=Path)
    parser.add_argument("--require-xcode-build")
    parser.add_argument("--simulator-version", help="Exact optional runtime version to download during prepare")
    parser.add_argument("--flutter-framework", type=Path, help="Matching .framework directory for the full adapter probe")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Apple SDK preparation and probes must run on a Mac build agent")
    target_triple(args.sdk, args.arch)
    if args.action != "prepare" and args.simulator_version:
        parser.error("--simulator-version is only valid with prepare")
    if args.action != "probe" and args.flutter_framework:
        parser.error("--flutter-framework is only valid with probe")
    # Invalidate an earlier success before touching SDKs or running a new probe.
    # A failed command must never leave an apparently current successful receipt.
    write_report(args.report, {"schema": 1, "status": "running", "sdk": args.sdk,
                               "sourceProbesPassed": False, "flutterAdapterChecked": False})
    try:
        env = environment(args.developer_dir)
        if args.action == "prepare":
            prepare(env, args.sdk, args.simulator_version, args.require_xcode_build)
        report = inspect(env, args.sdk, args.arch, args.require_xcode_build)
        if args.action == "probe":
            probe(report, env, args.flutter_framework)
        report["status"] = "passed"
        write_report(args.report, report)
    except Exception as error:
        write_report(args.report, {"schema": 1, "status": "failed", "sdk": args.sdk,
                                   "sourceProbesPassed": False, "flutterAdapterChecked": False,
                                   "error": str(error)})
        raise
    print(f"Apple SDK {report['sdkVersion']} checked for {report['target']}; report: {args.report}")


if __name__ == "__main__":
    main()
