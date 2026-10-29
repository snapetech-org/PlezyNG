#!/usr/bin/env python3
"""Build the exact app-pinned MilkRust runtime using the selected Tizen SDK.

Only runs on the private JIT worker. Produces source/notices/provenance, not a
device-qualification report or production signing material.
"""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(*command, env=None, cwd=None):
    subprocess.run([str(part) for part in command], env=env, cwd=cwd, check=True)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(args):
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    if (os.environ.get("RUNNER_ENVIRONMENT") != "self-hosted"
            or os.environ.get("GITHUB_REPOSITORY") != "snapetech-org/PlezyNG"
            or not re.fullmatch(r"[1-9][0-9]*", run_id)):
        raise ValueError("MilkRust Tizen builds require PlezyNG's private ephemeral JIT runner")
    runner = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    output = Path(args.output).absolute()
    output.parent.resolve(strict=True).relative_to(runner)
    if output.exists() or output.is_symlink():
        raise ValueError("MilkRust output must be a new directory under RUNNER_TEMP")
    toolchain = Path(args.toolchain).resolve(strict=True)
    lock = json.loads((ROOT / "native/visualizer/sources.lock.json").read_text())["milkrust"]
    if (lock["repository"] != "https://github.com/snapetech-org/MilkRust.git"
            or not re.fullmatch(r"[a-f0-9]{40}", lock["commit"])
            or not re.fullmatch(r"refs/pull/[1-9][0-9]*/head", lock["ref"])):
        raise ValueError("Unexpected MilkRust source identity")
    rust = json.loads((ROOT / "scripts/tizen/toolchain.json").read_text())["milkrust_rust_toolchain"]
    target = {"arm": "armv7-unknown-linux-gnueabi", "x64": "x86_64-unknown-linux-gnu"}[args.arch]
    with tempfile.TemporaryDirectory(prefix=f"milkrust-tizen-{run_id}-", dir=runner) as temp:
        work = Path(temp)
        run("cmake", "-S", ROOT / "native/visualizer/rust-toolchain", "-B", work / "toolchain",
            f"-DCMAKE_TOOLCHAIN_FILE={toolchain}", "-DCMAKE_BUILD_TYPE=Release")
        tools = json.loads((work / "toolchain/rust-tools.json").read_text())
        for name in ("CMAKE_C_COMPILER", "CMAKE_CXX_COMPILER", "CMAKE_AR"):
            if not Path(tools[name]).is_file() or any(c in tools[name] for c in "\n\r\x00"):
                raise ValueError("Invalid SDK compiler/archive tool")
        source = work / "source"
        run("git", "-c", "protocol.file.allow=never", "clone", "--filter=blob:none", "--no-checkout", lock["repository"], source)
        run("git", "fetch", "--no-tags", "origin", lock["ref"], cwd=source)
        run("git", "checkout", "--detach", lock["commit"], cwd=source)
        actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        if actual != lock["commit"]:
            raise ValueError("MilkRust checkout differs from immutable app pin")
        env = os.environ.copy()
        for stale in list(env):
            if stale in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CC", "CXX", "AR", "CFLAGS", "CXXFLAGS") or stale.startswith(("CC_", "CXX_", "AR_", "CFLAGS_", "CXXFLAGS_", "CARGO_TARGET_")):
                env.pop(stale, None)
        env.update(RUSTUP_HOME=str(work / "rustup"), CARGO_HOME=str(work / "cargo"), CARGO_TARGET_DIR=str(work / "target"))
        run("rustup", "toolchain", "install", rust, "--profile", "minimal", "--target", target, env=env)
        suffix = target.replace("-", "_")
        env[f"CC_{suffix}"] = tools["CMAKE_C_COMPILER"]
        env[f"CXX_{suffix}"] = tools["CMAKE_CXX_COMPILER"]
        env[f"AR_{suffix}"] = tools["CMAKE_AR"]
        sysroot = f"--sysroot={tools['CMAKE_SYSROOT']}"
        env[f"CFLAGS_{suffix}"] = tools["CMAKE_C_FLAGS"] + " " + shlex.quote(sysroot)
        env[f"CXXFLAGS_{suffix}"] = tools["CMAKE_CXX_FLAGS"] + " " + shlex.quote(sysroot)
        env[f"CARGO_TARGET_{suffix.upper()}_LINKER"] = tools["CMAKE_C_COMPILER"]
        flags = shlex.split(tools["CMAKE_C_FLAGS"] + " " + tools["CMAKE_EXE_LINKER_FLAGS"]) + [sysroot]
        env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(value for flag in flags for value in ("-C", f"link-arg={flag}"))
        run("rustup", "run", rust, "cargo", "build", "--locked", "--release", "--package", "milkrust-native",
            "--target", target, "--manifest-path", source / "Cargo.toml", env=env)
        library = work / "target" / target / "release/libmilkrust_native.so"
        header = library.read_bytes()[:20]
        machine, elf_class = (40, 1) if args.arch == "arm" else (62, 2)
        if len(header) != 20 or header[:4] != b"\x7fELF" or header[4:6] != bytes([elf_class, 1]) or struct.unpack_from("<H", header, 18)[0] != machine:
            raise ValueError("MilkRust runtime has the wrong ELF architecture")
        bundle = work / "bundle"
        bundle.mkdir()
        shutil.copyfile(library, bundle / library.name)
        with (bundle / "milkrust-source.tar.gz").open("wb") as file:
            with gzip.GzipFile(filename="", fileobj=file, mode="wb", mtime=0) as compressed:
                archive = subprocess.Popen(["git", "archive", "--format=tar", f"--prefix=milkrust-{lock['commit']}/", lock["commit"], "--", "Cargo.toml", "Cargo.lock", "LICENSE", "LICENSE-SCOPE.md", "README.md", "crates", "docs", "tools"], cwd=source, stdout=subprocess.PIPE)
                assert archive.stdout is not None
                try:
                    shutil.copyfileobj(archive.stdout, compressed)
                finally:
                    archive.stdout.close()
                if archive.wait() != 0:
                    raise ValueError("Could not archive corresponding MilkRust source")
        notices = (ROOT / "native/visualizer/notices/MilkRust-AGPL-3.0.txt").read_text()
        notices += "\n\nHLSLParser (MIT):\n" + (source / "crates/milkrust-hlsl/vendor/hlslparser/LICENSE").read_text()
        notices += "\n\nMilkRust core third-party notices:\n" + (source / "crates/milkrust-core/THIRD_PARTY_NOTICES.md").read_text()
        (bundle / "MILKRUST-NOTICES.txt").write_text(notices)
        metadata = {"schemaVersion": 1, "abi": lock["abi"], "target": f"tizen-{args.arch}",
            "sourceRevision": lock["commit"], "buildRun": f"https://github.com/snapetech-org/PlezyNG/actions/runs/{run_id}",
            "runnerPolicy": "private-ephemeral-jit", "rustToolchain": rust, "rustTarget": target,
            "toolchainSha256": sha(toolchain), "compilerSha256": sha(tools["CMAKE_CXX_COMPILER"]),
            "librarySha256": sha(bundle / library.name), "sourceArchiveSha256": sha(bundle / "milkrust-source.tar.gz"),
            "noticesSha256": sha(bundle / "MILKRUST-NOTICES.txt")}
        (bundle / "milkrust-native.json").write_text(json.dumps(metadata, sort_keys=True, indent=2) + "\n")
        bundle.rename(output)
    print(sha(output / "milkrust-native.json"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=("arm", "x64"))
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--output", required=True)
    build(parser.parse_args())
