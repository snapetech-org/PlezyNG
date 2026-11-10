#!/usr/bin/env python3
"""Build the Apple DV runtime included in every ordinary app package.

The implementation is loaded only when Settings requests it on a supported OS.
The small API framework retains the app's older deployment floor. All source
packages are pinned before resolution; compilation never implies qualification.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess

from build_adapters import verify_swift_pins

ROOT = Path(__file__).resolve().parents[2]


def run(args, *, cwd=None, env=None):
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def build_runtime(common, work: Path, architectures: list[str], env):
    command = common + [
        "ARCHS=" + " ".join(architectures), "ONLY_ACTIVE_ARCH=NO",
        "CODE_SIGNING_ALLOWED=NO", "build",
    ]
    try:
        run(command, cwd=work, env=env)
    except subprocess.CalledProcessError as error:
        # Xcode 26 can abort while attaching freshly fetched Swift packages to
        # its project model. Retain the verified task-owned checkouts, discard
        # only partial build products, and retry the exact locked build once.
        if error.returncode not in (-signal.SIGABRT, 128 + signal.SIGABRT):
            raise
        shutil.rmtree(work / "DerivedData", ignore_errors=True)
        run(command, cwd=work, env=env)


def build_environment(base=None):
    # A Run Script exports the enclosing app's resolved build settings. In
    # particular, EXECUTABLE_DEBUG_DYLIB_PATH makes every nested package target
    # link the same app dylib. Start with execution/network settings only; Xcode
    # must resolve product, compiler, SDK and signing settings for its own graph.
    base = os.environ if base is None else base
    allowed = {
        "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG",
        "DEVELOPER_DIR", "SSH_AUTH_SOCK", "XDG_CACHE_HOME",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE",
    }
    env = {key: value for key, value in base.items()
           if key in allowed or key.startswith(("LC_", "GIT_"))}
    # System Git runs LFS smudge inside Xcode's package fetch. Keep this scoped
    # to child processes, without changing the enclosing app's environment or
    # the authenticated developer's global Git configuration.
    config = {
        "filter.lfs.process": "git-lfs filter-process",
        "filter.lfs.required": "true",
        "filter.lfs.smudge": "git-lfs smudge -- %f",
        "filter.lfs.clean": "git-lfs clean -- %f",
    }
    start = int(env.get("GIT_CONFIG_COUNT", "0"))
    env["GIT_CONFIG_COUNT"] = str(start + len(config))
    for index, (key, value) in enumerate(config.items(), start=start):
        env[f"GIT_CONFIG_KEY_{index}"] = key
        env[f"GIT_CONFIG_VALUE_{index}"] = value
    return env


def build(work: Path, sdk: str, configuration: str, architectures: list[str]) -> Path:
    if platform.system() != "Darwin":
        raise ValueError("Apple runtime builds require macOS and Xcode 27")
    for tool in ("xcodegen", "xcodebuild", "git-lfs"):
        if not shutil.which(tool):
            raise ValueError(f"missing required Apple build tool: {tool}")
    # Task-owned APFS storage also owns package checkout and DerivedData. Never
    # allow Xcode to spill into its global DerivedData directory or onto NFS.
    work.mkdir(parents=True, exist_ok=True)
    sdk_platform, floor, destination = {
        "macosx": ("macOS", "15.0", "generic/platform=macOS"),
        "iphoneos": ("iOS", "18.0", "generic/platform=iOS"),
        "iphonesimulator": ("iOS", "18.0", "generic/platform=iOS Simulator"),
        "appletvos": ("tvOS", "18.0", "generic/platform=tvOS"),
        "appletvsimulator": ("tvOS", "18.0", "generic/platform=tvOS Simulator"),
    }[sdk]
    lock = json.loads((ROOT / "tools/dv-engine/adapters.lock.json").read_text())
    aether = lock["sources"]["aether"]
    pins = list(aether["swift_pins"]) + [{
        "identity": "aetherengine", "kind": "remoteSourceControl",
        "location": aether["url"], "state": {"revision": aether["commit"]},
    }]
    (work / "BuildAnchor.swift").write_text("import PlezyNGDVRuntime\npublic struct BuildAnchor {}\n")
    spec = {
        "name": "PlezyNGDVRuntimeBuild",
        "packages": {"Runtime": {"path": str(ROOT / "native/dv/apple")}},
        "settings": {"base": {
            "SWIFT_VERSION": "5.0", "GENERATE_INFOPLIST_FILE": "YES",
            "CODE_SIGNING_ALLOWED": "NO", "SKIP_INSTALL": "NO",
        }},
        "targets": {"PlezyNGDVBuild": {
            "type": "framework", "platform": sdk_platform, "deploymentTarget": floor,
            "sources": ["BuildAnchor.swift"],
            "dependencies": [{"package": "Runtime", "product": "PlezyNGDVRuntime"}],
        }},
    }
    spec_path = work / "project.json"
    spec_path.write_text(json.dumps(spec, indent=2) + "\n")
    env = build_environment()
    run(["xcodegen", "generate", "--spec", spec_path, "--project", work], env=env)
    project = work / "PlezyNGDVRuntimeBuild.xcodeproj"
    resolved = project / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    resolved.parent.mkdir(parents=True, exist_ok=True)
    if not resolved.exists():
        resolved.write_text(json.dumps({"pins": pins, "version": 2}, indent=2) + "\n")
    verify_swift_pins(resolved, pins, required=aether["swift_required_pins"] + ["aetherengine"])
    common = [
        "xcodebuild", "-project", project, "-scheme", "PlezyNGDVBuild",
        "-configuration", configuration, "-sdk", sdk, "-destination", destination,
        "-derivedDataPath", work / "DerivedData", "-clonedSourcePackagesDirPath", work / "SourcePackages",
        "-scmProvider", "system", "-disableAutomaticPackageResolution",
        "-onlyUsePackageVersionsFromResolvedFile", "-jobs", "2",
    ]
    # The build loads the checked-in Package.resolved under
    # -onlyUsePackageVersionsFromResolvedFile. A separate nested resolve action
    # reliably aborts inside Xcode 26's package-graph model and is redundant.
    build_runtime(common, work, architectures, env)
    verify_swift_pins(resolved, pins, required=aether["swift_required_pins"] + ["aetherengine"])
    products = work / "DerivedData/Build/Products"
    # Keep only products for the requested SDK/configuration; never pick a
    # matching intermediate generated by a previous SDK build.
    folder = configuration if sdk == "macosx" else configuration + "-" + sdk
    product_root = products / folder
    matches = list(product_root.glob("**/PlezyNGDVRuntime.framework"))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one built runtime framework, found {matches}")
    # Keep upstream notices beside the bundled binaries and their exact pins.
    notices = product_root / "PlezyNGDVRuntime-Licenses"
    notices.mkdir(exist_ok=True)
    for name in ("AetherEngine", "FFmpegBuild", "LibDovi"):
        checkout = work / "SourcePackages/checkouts" / name
        if not checkout.exists():
            matches = [p for p in (work / "SourcePackages/checkouts").iterdir() if p.name.lower() == name.lower()]
            if len(matches) != 1:
                raise ValueError(f"missing pinned source checkout for notices: {name}")
            checkout = matches[0]
        files = [p for p in checkout.iterdir() if p.is_file() and p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE"))]
        if not files:
            raise ValueError(f"missing upstream license notice: {name}")
        for source in files:
            target = notices / (name + "-" + source.name)
            # SwiftPM checkouts can be read-only. Replace our previous copy
            # so incremental app builds do not fail on its inherited mode.
            target.unlink(missing_ok=True)
            shutil.copyfile(source, target)
    provenance = {
        "schema_version": 1, "abi_version": 1, "sdk": sdk,
        "architectures": architectures, "aether_commit": aether["commit"],
        "traits": ["DualLayerDolbyVision"], "activation": "runtime-settings-automatic-with-fallback",
        "qualification": "unqualified", "pins": pins,
        "lock_sha256": hashlib.sha256((ROOT / "tools/dv-engine/adapters.lock.json").read_bytes()).hexdigest(),
    }
    (product_root / "PlezyNGDVRuntime.provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return product_root


def embed(products: Path, frameworks: Path, resources: Path) -> None:
    frameworks.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    # Binary package dependencies and the API travel beside the runtime.
    # The anchor framework exists only to drive Xcode's package build graph.
    package_frameworks = products / "PackageFrameworks"
    sources = package_frameworks.glob("*.framework") if package_frameworks.is_dir() else products.glob("*.framework")
    copied = []
    for source in sorted(sources):
        if source.name == "PlezyNGDVBuild.framework" or any(p.suffix == ".framework" for p in source.parents):
            continue
        target = frameworks / source.name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target, symlinks=True)
        copied.append(target)
    for source in products.glob("*.bundle"):
        target = resources / source.name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target, symlinks=True)
    notice_source = products / "PlezyNGDVRuntime-Licenses"
    notice_target = resources / notice_source.name
    if notice_target.exists():
        shutil.rmtree(notice_target)
    shutil.copytree(notice_source, notice_target)
    shutil.copy2(products / "PlezyNGDVRuntime.provenance.json", resources)
    if not (frameworks / "PlezyNGDVRuntime.framework/PlezyNGDVRuntime").exists():
        raise ValueError("app packaging did not include the DV runtime")
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY")
    if os.environ.get("CODE_SIGNING_ALLOWED") != "NO" and identity:
        for target in copied:
            run(["codesign", "--force", "--sign", identity, "--preserve-metadata=identifier,entitlements", target])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--sdk", choices=("macosx", "iphoneos", "iphonesimulator", "appletvos", "appletvsimulator"))
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--arch", action="append")
    parser.add_argument("--xcode-phase", action="store_true")
    args = parser.parse_args()
    if args.xcode_phase:
        sdk = os.environ["PLATFORM_NAME"]
        configuration = "Debug" if os.environ.get("CONFIGURATION") == "Debug" else "Release"
        architectures = os.environ["ARCHS"].split()
        work = Path(os.environ["PROJECT_TEMP_DIR"]) / "PlezyNGDVRuntime" / sdk / configuration
    else:
        if not args.work_dir or not args.sdk:
            parser.error("--work-dir and --sdk are required outside Xcode")
        sdk, configuration, architectures, work = args.sdk, args.configuration, args.arch or ["arm64"], args.work_dir
    products = build(work.absolute(), sdk, configuration, architectures)
    if args.xcode_phase:
        target = Path(os.environ["TARGET_BUILD_DIR"])
        embed(products, target / os.environ["FRAMEWORKS_FOLDER_PATH"], target / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"])
    print(products)


if __name__ == "__main__":
    main()
