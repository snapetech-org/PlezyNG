#!/usr/bin/env python3
"""Build and stage the app-pinned MilkRust runtime on private ephemeral JIT.

Desktop/Android jobs call this before Flutter. Apple targets call it from their
Xcode phase, including simulator builds. Source and notices accompany binaries.
"""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RUST = "1.97.0"
SOURCE_PATHS = ["Cargo.toml", "Cargo.lock", "LICENSE", "LICENSE-SCOPE.md", "README.md", "crates", "docs", "tools"]
TARGETS = {
    "linux": {"x64": "x86_64-unknown-linux-gnu", "arm64": "aarch64-unknown-linux-gnu"},
    "windows": {"x64": "x86_64-pc-windows-msvc", "arm64": "aarch64-pc-windows-msvc"},
    "macos": {"x64": "x86_64-apple-darwin", "arm64": "aarch64-apple-darwin"},
    "ios": {"arm64": "aarch64-apple-ios"},
    "ios-simulator": {"x64": "x86_64-apple-ios", "arm64": "aarch64-apple-ios-sim"},
    "tvos": {"arm64": "aarch64-apple-tvos"},
    "tvos-simulator": {"arm64": "aarch64-apple-tvos-sim"},
    "android": {"arm64-v8a": "aarch64-linux-android", "armeabi-v7a": "armv7-linux-androideabi", "x86": "i686-linux-android", "x86_64": "x86_64-linux-android"},
}


def run(*command, env=None, cwd=None):
    subprocess.run([str(p) for p in command], env=env, cwd=cwd, check=True)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def valid_files(output, files):
    if not isinstance(files, dict) or not files or len(files) > 32:
        return False
    for name, sha in files.items():
        if not isinstance(name, str) or not isinstance(sha, str) or not re.fullmatch(r"[a-f0-9]{64}", sha):
            return False
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or ":" in name or "\\" in name or relative.as_posix() != name:
            return False
        path = output / name
        if any(parent.is_symlink() for parent in [path, *path.parents]) or not path.is_file() or digest(path) != sha:
            return False
    return True


def build(args):
    if os.environ.get("RUNNER_ENVIRONMENT") != "self-hosted" or os.environ.get("GITHUB_REPOSITORY") != "snapetech-org/PlezyNG":
        raise ValueError("MilkRust app builds require the private ephemeral JIT worker")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ValueError("A private JIT run ID is required")
    architectures = args.architectures.split(",")
    if not architectures or len(set(architectures)) != len(architectures) or any(a not in TARGETS[args.platform] for a in architectures):
        raise ValueError("Unsupported or duplicate architecture for this platform")
    if args.platform in ("linux", "windows") and len(architectures) != 1:
        raise ValueError("Desktop packages must select one native architecture")
    if args.platform == "linux":
        host = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine().lower())
        if host != architectures[0]:
            raise ValueError("Linux MilkRust must build on a matching private runner architecture")
    output = Path(args.output).absolute()
    if output.is_symlink():
        raise ValueError("MilkRust output must not be a symlink")
    output.parent.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / "native/visualizer/sources.lock.json").read_text())["milkrust"]
    if (lock["repository"] != "https://github.com/snapetech-org/MilkRust.git"
            or not re.fullmatch(r"[a-f0-9]{40}", lock["commit"])
            or not re.fullmatch(r"refs/pull/[1-9][0-9]*/head", lock["ref"])):
        raise ValueError("Unexpected MilkRust source pin")
    # Repeated Xcode archive phases reuse only exact, digest-verified artifacts.
    receipt = output / "milkrust-build.json"
    if receipt.is_file():
        old = json.loads(receipt.read_text())
        if (old.get("sourceRevision") == lock["commit"] and old.get("platform") == args.platform
                and old.get("architectures") == architectures and old.get("rustToolchain") == RUST
                and old.get("runId") == run_id and valid_files(output, old.get("files"))):
            return
        raise ValueError("Existing MilkRust artifact differs from this build; use a new output directory")
    if output.exists():
        raise ValueError("MilkRust output already exists without a valid receipt")
    with tempfile.TemporaryDirectory(prefix="plezy-milkrust-", dir=os.environ["RUNNER_TEMP"]) as tmp:
        work = Path(tmp)
        source = work / "source"
        run("git", "-c", "protocol.file.allow=never", "clone", "--filter=blob:none", "--no-checkout", lock["repository"], source)
        run("git", "fetch", "--no-tags", "origin", lock["ref"], cwd=source)
        run("git", "checkout", "--detach", lock["commit"], cwd=source)
        actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        if actual != lock["commit"]:
            raise ValueError("MilkRust source identity changed")
        env = os.environ.copy()
        for name in list(env):
            if name in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CC", "CXX", "AR", "CFLAGS", "CXXFLAGS") or name.startswith(("CC_", "CXX_", "AR_", "CFLAGS_", "CXXFLAGS_", "CARGO_TARGET_")):
                env.pop(name, None)
        env.update(RUSTUP_HOME=str(work / "rustup"), CARGO_HOME=str(work / "cargo"), CARGO_TARGET_DIR=str(work / "target"))
        targets = [TARGETS[args.platform][a] for a in architectures]
        run("rustup", "toolchain", "install", RUST, "--profile", "minimal", "--target", ",".join(targets), env=env)
        apple_sdk = {"macos": "macosx", "ios": "iphoneos", "ios-simulator": "iphonesimulator",
                     "tvos": "appletvos", "tvos-simulator": "appletvsimulator"}.get(args.platform)
        if apple_sdk:
            env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", apple_sdk, "--show-sdk-path"], text=True).strip()
        staged = work / "bundle"
        staged.mkdir()
        libraries = []
        for arch, target in zip(architectures, targets):
            target_env = env.copy()
            if args.platform == "android":
                ndk = Path(args.ndk or os.environ.get("ANDROID_NDK_HOME", "")).resolve(strict=True)
                if not re.search(r"Pkg.Revision\s*=\s*29\.0\.14206865\s*(?:\n|$)", (ndk / "source.properties").read_text()):
                    raise ValueError("MilkRust Android requires the app-pinned NDK 29.0.14206865")
                compiler = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
                triple = {"arm64-v8a": "aarch64-linux-android", "armeabi-v7a": "armv7a-linux-androideabi", "x86": "i686-linux-android", "x86_64": "x86_64-linux-android"}[arch]
                suffix = target.replace("-", "_")
                cc, cxx = compiler / f"{triple}23-clang", compiler / f"{triple}23-clang++"
                if not cc.is_file() or not cxx.is_file():
                    raise ValueError("Android NDK target compilers are absent")
                target_env.update({f"CC_{suffix}": str(cc), f"CXX_{suffix}": str(cxx), f"AR_{suffix}": str(compiler / "llvm-ar"),
                    f"CARGO_TARGET_{suffix.upper()}_LINKER": str(cc),
                    "CARGO_ENCODED_RUSTFLAGS": "-C\x1flink-arg=-Wl,-z,max-page-size=16384"})
            run("rustup", "run", RUST, "cargo", "build", "--locked", "--release", "--package", "milkrust-native",
                "--target", target, "--manifest-path", source / "Cargo.toml", env=target_env)
            filename = "libmilkrust_native.a" if apple_sdk else "milkrust_native.dll" if args.platform == "windows" else "libmilkrust_native.so"
            library = work / "target" / target / "release" / filename
            if not library.is_file():
                raise ValueError("MilkRust build omitted the expected runtime")
            libraries.append(library)
            if args.platform == "android":
                destination = staged / "jniLibs" / arch
                destination.mkdir(parents=True)
                shutil.copyfile(library, destination / filename)
            elif not apple_sdk:
                shutil.copyfile(library, staged / filename)
        if apple_sdk:
            run("xcrun", "lipo", "-create", *libraries, "-output", staged / "libmilkrust_native.a")
        assets = staged / "assets" / "visualizer-notices"
        assets.mkdir(parents=True)
        source_tar = work / "source.tar"
        run("git", "archive", "--format=tar", f"--prefix=milkrust-{lock['commit']}/", "-o", source_tar,
            lock["commit"], "--", *SOURCE_PATHS, cwd=source)
        with source_tar.open("rb") as original, (assets / "milkrust-source.tar.gz").open("wb") as file:
            with gzip.GzipFile(filename="", fileobj=file, mode="wb", mtime=0) as compressed:
                shutil.copyfileobj(original, compressed)
        notice = (ROOT / "native/visualizer/notices/MilkRust-AGPL-3.0.txt").read_text()
        notice += "\n\nHLSLParser (MIT):\n" + (source / "crates/milkrust-hlsl/vendor/hlslparser/LICENSE").read_text()
        (assets / "MILKRUST-NOTICES.txt").write_text(notice)
        files = {path.relative_to(staged).as_posix(): digest(path) for path in staged.rglob("*") if path.is_file()}
        metadata = {"schemaVersion": 1, "sourceRevision": lock["commit"], "platform": args.platform, "architectures": architectures,
            "rustToolchain": RUST, "runId": run_id, "runnerPolicy": "private-ephemeral-jit", "files": files, "qualified": False}
        (staged / "milkrust-build.json").write_text(json.dumps(metadata, sort_keys=True, indent=2) + "\n")
        # Destination may be on a different volume from RUNNER_TEMP. Assemble
        # beside it first, then expose the final directory atomically.
        delivery = Path(tempfile.mkdtemp(prefix=output.name + "-", dir=output.parent))
        try:
            shutil.copytree(staged, delivery, dirs_exist_ok=True)
            delivery.rename(output)
        finally:
            if delivery.exists():
                shutil.rmtree(delivery)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=TARGETS)
    parser.add_argument("--architectures", required=True, help="Comma-separated platform architecture names")
    parser.add_argument("--output", required=True)
    parser.add_argument("--ndk")
    build(parser.parse_args())
