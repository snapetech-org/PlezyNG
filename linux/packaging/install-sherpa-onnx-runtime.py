#!/usr/bin/env python3
"""Install and verify the locked sherpa_onnx_linux runtime pair in a bundle."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote, urlsplit


LIBRARIES = ("libsherpa-onnx-c-api.so", "libonnxruntime.so")
ARCHITECTURE_DIRECTORIES = {"x64": "x64", "arm64": "aarch64"}


def resolve_package_root(package_config: Path, package_name: str) -> Path:
    config = json.loads(package_config.read_text(encoding="utf-8"))
    package = next(
        (item for item in config["packages"] if item["name"] == package_name),
        None,
    )
    if package is None:
        raise ValueError(f"{package_name} is missing from {package_config}")

    root_uri = package["rootUri"]
    parsed = urlsplit(root_uri)
    if parsed.scheme == "file":
        if parsed.netloc not in ("", "localhost"):
            raise ValueError(f"Unsupported package file URI: {root_uri}")
        root = Path(unquote(parsed.path))
    elif parsed.scheme:
        raise ValueError(f"Unsupported package URI: {root_uri}")
    else:
        root = Path(unquote(root_uri))
        if not root.is_absolute():
            root = package_config.parent / root
    return root.resolve()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def install_runtime_pair(
    package_config: Path,
    bundle: Path,
    architecture: str,
) -> None:
    package_root = resolve_package_root(package_config, "sherpa_onnx_linux")
    source_directory = package_root / "linux" / ARCHITECTURE_DIRECTORIES[architecture]
    destination_directory = bundle / "lib"
    if not destination_directory.is_dir():
        raise ValueError(f"Linux bundle library directory is missing: {destination_directory}")

    sources = {name: source_directory / name for name in LIBRARIES}
    missing = [str(path) for path in sources.values() if not path.is_file()]
    if missing:
        raise ValueError("Locked Sherpa ONNX package is missing: " + ", ".join(missing))

    for name, source in sources.items():
        destination = destination_directory / name
        shutil.copy2(source, destination)
        if sha256(source) != sha256(destination):
            raise RuntimeError(f"Sherpa ONNX runtime copy changed bytes: {name}")
        print(f"Sherpa ONNX {name}: sha256={sha256(destination)}")

    runtime = (destination_directory / "libonnxruntime.so").resolve()
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = str(destination_directory.resolve()) + os.pathsep + env.get(
        "LD_LIBRARY_PATH", ""
    )
    result = subprocess.run(
        ["ldd", str(destination_directory / "libsherpa-onnx-c-api.so")],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    output = result.stdout + result.stderr
    if result.returncode != 0 or "not found" in output:
        raise RuntimeError("Sherpa ONNX bundle has unresolved dependencies:\n" + output)

    runtime_line = next(
        (line for line in output.splitlines() if line.lstrip().startswith("libonnxruntime.so =>")),
        None,
    )
    if runtime_line is None:
        raise RuntimeError("ldd did not resolve the bundled libonnxruntime.so:\n" + output)
    resolved_text = runtime_line.split("=>", 1)[1].strip().split(" ", 1)[0]
    if Path(resolved_text).resolve() != runtime:
        raise RuntimeError(
            "Sherpa ONNX resolved a different libonnxruntime.so: " + runtime_line
        )
    print(f"Sherpa ONNX runtime pair resolves together from {destination_directory.resolve()}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--arch", required=True, choices=tuple(ARCHITECTURE_DIRECTORIES))
    parser.add_argument(
        "--package-config",
        type=Path,
        default=Path(".dart_tool/package_config.json"),
    )
    args = parser.parse_args()
    install_runtime_pair(args.package_config, args.bundle, args.arch)


if __name__ == "__main__":
    main()
