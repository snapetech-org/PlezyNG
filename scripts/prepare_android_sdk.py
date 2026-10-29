#!/usr/bin/env python3
"""Provision every Android module's pinned SDK tools on private JIT runners."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.request
from urllib.parse import urlsplit
import uuid
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOOLS_LOCK = Path(__file__).with_name("android-sdk-tools.lock.json")


@contextmanager
def sdk_lock(sdk: Path):
    sdk.mkdir(parents=True, exist_ok=True)
    with (sdk / ".plezy-sdk.lock").open("a+b") as handle:
        if os.name == "nt":
            import msvcrt
            if handle.seek(0, os.SEEK_END) == 0:
                handle.write(b"\0")
                handle.flush()

            def acquire():
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            def acquire():
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        deadline = time.monotonic() + 900
        while True:
            try:
                acquire()
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                    raise
                if time.monotonic() >= deadline:
                    raise TimeoutError("Another process still owns Android SDK preparation") from error
                time.sleep(0.1)
        # Closing the file releases the OS lock even after exceptions.
        yield


def host_key() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    machine = {"amd64": "x86_64", "aarch64": "arm64"}.get(machine, machine)
    # Google supplies x64 Windows tools; Windows on ARM runs this host tooling
    # through its x64 compatibility layer, independently of the app target ABI.
    if system == "windows" and machine == "arm64":
        machine = "x86_64"
    return f"{system}-{machine}"


def sdk_root(env: dict[str, str]) -> Path:
    value = env.get("ANDROID_SDK_ROOT") or env.get("ANDROID_HOME")
    if not value or not Path(value).is_absolute() or any(c in value for c in "\r\n"):
        raise ValueError("Set an absolute --sdk-root, ANDROID_SDK_ROOT or ANDROID_HOME")
    return Path(value)


def tools_version(directory: Path) -> str | None:
    properties = directory / "source.properties"
    if not properties.is_file():
        return None
    match = re.search(r"^Pkg\.Revision\s*=\s*([^\s]+)\s*$", properties.read_text(), re.MULTILINE)
    return match[1] if match else None


def extract_tools(archive: Path, destination: Path) -> None:
    """Reject links/traversal and bound expansion before writing any member."""
    with zipfile.ZipFile(archive) as source:
        members = source.infolist()
        if len(members) > 10000 or sum(member.file_size for member in members) > 1024**3:
            raise ValueError("Android command-line tools archive exceeds extraction bounds")
        seen = set()
        for member in members:
            path = Path(member.filename)
            mode = member.external_attr >> 16
            if (path.is_absolute() or ".." in path.parts or "\\" in member.filename
                    or ":" in member.filename or not path.parts or path.parts[0] != "cmdline-tools"
                    or stat.S_ISLNK(mode) or (mode and stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))
                    or member.filename in seen):
                raise ValueError("Unsafe Android command-line tools archive member")
            seen.add(member.filename)
        for member in members:
            target = destination / member.filename
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(member) as input_file, target.open("xb") as output:
                shutil.copyfileobj(input_file, output, 1024 * 1024)
            target.chmod(0o755 if (member.external_attr >> 16) & 0o111 else 0o644)


def bootstrap(sdk: Path, archive: Path | None = None) -> Path:
    """Install a verified CLI side by side, without replacing a builder's SDK."""
    lock = json.loads(TOOLS_LOCK.read_text())
    key = host_key()
    if lock.get("schema") != 1 or key not in lock["archives"]:
        raise ValueError(f"No pinned Android command-line tools for {key}")
    pin = lock["archives"][key]
    if not re.fullmatch(r"commandlinetools-[a-z0-9_]+-[0-9]+_latest\.zip", pin["file"]):
        raise ValueError("Invalid Android tools archive name")
    if not re.fullmatch(r"[0-9a-f]{64}", pin["sha256"]) or not re.fullmatch(r"\d+\.\d+", lock["version"]):
        raise ValueError("Invalid Android tools integrity pin")
    tools = sdk / "cmdline-tools"
    tools.mkdir(parents=True, exist_ok=True)
    target = tools / lock["version"]
    manager_name = "sdkmanager.bat" if key.startswith("windows-") else "sdkmanager"
    if target.exists():
        if (target.is_symlink() or tools_version(target) != lock["version"]
                or not (target / "bin" / manager_name).is_file()):
            raise ValueError(f"Incomplete or unexpected pinned command-line tools: {target}")
        return target / "bin" / manager_name
    with tempfile.TemporaryDirectory(prefix=".plezy-sdk-", dir=tools) as temporary:
        staging = Path(temporary)
        if archive is None:
            archive = staging / pin["file"]
            request = urllib.request.Request("https://dl.google.com/android/repository/" + pin["file"],
                                             headers={"User-Agent": "PlezyNG-sdk-preparation/1"})
            with urllib.request.urlopen(request, timeout=60) as response, archive.open("xb") as output:
                if urlsplit(response.url).scheme != "https":
                    raise ValueError("Android tool download redirected outside HTTPS")
                size = 0
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > 512 * 1024**2:
                        raise ValueError("Android tools download exceeds its size limit")
                    output.write(block)
        digest = hashlib.sha256()
        with archive.open("rb") as payload:
            for block in iter(lambda: payload.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != pin["sha256"]:
            raise ValueError("Android command-line tools SHA-256 mismatch")
        extract_tools(archive, staging / "extracted")
        prepared = staging / "extracted/cmdline-tools"
        if tools_version(prepared) != lock["version"] or not (prepared / "bin" / manager_name).is_file():
            raise ValueError("Android tools metadata does not match its pin")
        try:
            prepared.rename(target)
        except OSError:
            # Another concurrent preparation may have committed the same version.
            if tools_version(target) != lock["version"] or not (target / "bin" / manager_name).is_file():
                raise
    return target / "bin" / manager_name


def proxy_parts(env: dict[str, str]) -> tuple[str, int]:
    raw = env.get("HTTPS_PROXY") or env.get("https_proxy") or ""
    if not raw or any(character.isspace() for character in raw):
        raise ValueError("The private JIT HTTPS proxy is required and must not contain whitespace")
    parsed = urlsplit(raw if "://" in raw else f"http://{raw}")
    if (parsed.scheme != "http" or not parsed.hostname or not parsed.port
            or parsed.username or parsed.password or parsed.path not in ("", "/")
            or parsed.query or parsed.fragment
            or not re.fullmatch(r"[A-Za-z0-9.:-]+", parsed.hostname)):
        raise ValueError("Expected an unauthenticated HTTP proxy with an explicit host and port")
    return parsed.hostname, parsed.port


def configure_proxy(env: dict[str, str]) -> None:
    host, port = proxy_parts(env)
    options = (f"-Dhttp.proxyHost={host} -Dhttp.proxyPort={port} "
               f"-Dhttps.proxyHost={host} -Dhttps.proxyPort={port} "
               "-Dhttp.nonProxyHosts=localhost|127.*|[::1]")
    lines = []
    for name in ("JAVA_TOOL_OPTIONS", "GRADLE_OPTS"):
        previous = env.get(name, "").strip()
        if "\n" in previous or "\r" in previous:
            raise ValueError(f"{name} must fit on one environment-file line")
        lines.append(f"{name}={previous + ' ' if previous else ''}{options}\n")
    with Path(env["GITHUB_ENV"]).open("a", encoding="utf-8") as output:
        output.writelines(lines)


def platform_package(api: int) -> str:
    # Google publishes API 37 and later with a minor version
    # (platforms;android-37.0); there is no plain platforms;android-37.
    return f"platforms;android-{api}.0" if api >= 37 else f"platforms;android-{api}"


def required_packages(root: Path) -> list[str]:
    packages = {"platform-tools"}
    sources = list((root / "android").glob("*.gradle*"))
    sources += list((root / "android").glob("*/*.gradle*"))
    sources += list((root / "packages").glob("*/android/*.gradle*"))
    for path in sources:
        if not path.is_file() or not (path.name.endswith(".gradle") or path.name.endswith(".gradle.kts")):
            continue
        source = path.read_text(encoding="utf-8")
        for value in re.findall(r"\bcompileSdk\s*(?:=\s*)?(\d+)\b", source):
            packages.add(platform_package(int(value)))
        for field, package in (("buildToolsVersion", "build-tools"), ("ndkVersion", "ndk")):
            pattern = rf"\b{field}\s*(?:=\s*)?['\"]([0-9.]+)['\"]"
            for value in re.findall(pattern, source):
                packages.add(f"{package};{value}")
        # These project files declare externalNativeBuild CMake versions as
        # literals. Do not confuse Android/Kotlin plugin versions with CMake.
        for block in re.findall(r"\bcmake\s*\{([^{}]*)\}", source):
            for value in re.findall(r"\bversion\s*(?:=\s*)?['\"]([0-9.]+)['\"]", block):
                packages.add(f"cmake;{value}")
    for prefix in ("platforms;", "build-tools;", "ndk;", "cmake;"):
        if not any(package.startswith(prefix) for package in packages):
            raise ValueError(f"No literal Android {prefix} pin found; review the Gradle declarations")
    return sorted(packages)


def verify_packages(sdk: Path, packages: list[str]) -> None:
    system = platform.system()
    executable = ".exe" if system == "Windows" else ""
    script = ".bat" if system == "Windows" else ""
    ndk_host = {"Linux": "linux-x86_64", "Darwin": "darwin-x86_64", "Windows": "windows-x86_64"}[system]
    for package in packages:
        parts = package.split(";")
        directory = sdk.joinpath(*parts)
        kind = parts[0]
        if kind == "platform-tools":
            required = (directory / f"adb{executable}",)
        elif kind == "platforms":
            required = (directory / "android.jar",)
        elif kind == "build-tools":
            required = (directory / f"aapt2{executable}", directory / f"apksigner{script}")
        elif kind == "cmake":
            required = (directory / f"bin/cmake{executable}", directory / f"bin/ninja{executable}")
        else:
            required = (directory / f"ndk-build{'.cmd' if system == 'Windows' else ''}", directory / "source.properties",
                        directory / f"toolchains/llvm/prebuilt/{ndk_host}/bin/clang{executable}")
        for path in required:
            if not path.is_file() or (system != "Windows" and path.suffix not in (".jar", ".properties")
                                      and not os.access(path, os.X_OK)):
                raise ValueError(f"Incomplete Android toolchain package {package}: missing {path.name}")
        if kind == "ndk":
            properties = (directory / "source.properties").read_text()
            if not re.search(rf"^Pkg\.Revision\s*=\s*{re.escape(parts[1])}\s*$", properties, re.MULTILINE):
                raise ValueError(f"NDK metadata does not match its declared version: {package}")


def repair_nested_platform(sdk: Path, package: str) -> None:
    """Normalize a verified legacy platform container left by SDK Manager 22.

    Preserve the previous container outside SDK discovery. Never merge/overwrite
    files in a working platform, accept another API's metadata or follow links.
    The caller holds sdk_lock while installing or repairing.
    """
    if not re.fullmatch(r"platforms;android-\d+(?:\.\d+)?", package):
        return
    directory = sdk.joinpath(*package.split(";"))
    nested = directory / directory.name
    if (directory / "android.jar").is_file() or not (nested / "android.jar").is_file():
        return
    if (directory.is_symlink() or nested.is_symlink()
            or any(path.is_symlink() for path in nested.rglob("*"))):
        raise ValueError("Refusing linked legacy SDK platform metadata")
    properties = (nested / "source.properties").read_text()
    api = directory.name.removeprefix("android-").split(".")[0]
    if not re.search(rf"^AndroidVersion\.ApiLevel\s*=\s*{api}\s*$", properties, re.MULTILINE):
        raise ValueError("Nested SDK platform does not match its requested API")
    metadata = directory / "package.xml"
    if metadata.is_symlink() or not metadata.is_file():
        raise ValueError("Nested SDK platform lacks SDK Manager package metadata")
    local = next((e for e in ET.parse(metadata).getroot() if e.tag.endswith("localPackage")), None)
    if local is None or local.get("path") != package:
        raise ValueError("Nested SDK platform package identity mismatch")
    if (nested / "package.xml").exists():
        raise ValueError("Nested SDK platform already has conflicting package metadata")
    archive = sdk.parent / f"{sdk.name}-platform-layout" / f"{directory.name}-{uuid.uuid4().hex}"
    archive.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if archive.parent.is_symlink():
        raise ValueError("Refusing a linked SDK platform archive directory")
    copied_metadata = nested / "package.xml"
    shutil.copy2(metadata, copied_metadata)
    try:
        directory.rename(archive)
    except OSError:
        copied_metadata.unlink()
        raise
    try:
        (archive / directory.name).rename(directory)
    except OSError:
        archive.rename(directory)
        copied_metadata.unlink()
        raise
    print(f"Repaired {package}; previous container retained at {archive}", flush=True)


def install_locked(root: Path, env: dict[str, str]) -> None:
    sdk = sdk_root(env)
    suffix = ".bat" if platform.system() == "Windows" else ""
    managers = sorted(sdk.glob(f"cmdline-tools/*/bin/sdkmanager{suffix}"))
    if not managers:
        managers = [bootstrap(sdk)]
    manager = sdk / f"cmdline-tools/latest/bin/sdkmanager{suffix}"
    if manager not in managers:
        manager = max(managers, key=lambda p: tuple(int(v) for v in re.findall(r"\d+", p.parents[1].name)))
    args = [str(manager), f"--sdk_root={sdk}", "--channel=3"]
    if env.get("HTTPS_PROXY") or env.get("https_proxy") or env.get("GITHUB_ACTIONS") == "true":
        host, port = proxy_parts(env)
        args += ["--proxy=http", f"--proxy_host={host}", f"--proxy_port={port}"]
    packages = required_packages(root)
    print("Provisioning pinned Android packages: " + ", ".join(packages), flush=True)
    subprocess.run(args + ["--licenses"], input="y\n" * 100, text=True,
                   stdout=subprocess.DEVNULL, check=True, env=env)
    # Verify each installation before proceeding. Some legacy platform archives
    # unpack incorrectly when several SDK generations share one install batch.
    for package in packages:
        repair_nested_platform(sdk, package)
        subprocess.run(args + ["--install", package], check=True, env=env)
        repair_nested_platform(sdk, package)
        verify_packages(sdk, [package])


def install(root: Path, env: dict[str, str]) -> None:
    with sdk_lock(sdk_root(env)):
        install_locked(root, env)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("proxy", "bootstrap", "install", "verify", "list"))
    parser.add_argument("--sdk-root", type=Path, help="Absolute SDK directory; no machine-wide settings are changed")
    parser.add_argument("--archive", type=Path, help="Use a checksum-verified offline command-line tools ZIP")
    args = parser.parse_args()
    env = dict(os.environ)
    if args.sdk_root:
        env["ANDROID_SDK_ROOT"] = str(args.sdk_root)
    if args.archive and args.action != "bootstrap":
        parser.error("--archive applies only to bootstrap")
    if args.action == "proxy":
        configure_proxy(env)
    elif args.action == "bootstrap":
        with sdk_lock(sdk_root(env)):
            print(bootstrap(sdk_root(env), args.archive))
    elif args.action == "install":
        install(ROOT, env)
    elif args.action == "verify":
        packages = required_packages(ROOT)
        verify_packages(sdk_root(env), packages)
        print(json.dumps({"sdk": str(sdk_root(env)), "packages": packages, "verified": True}, indent=2))
    else:
        print("\n".join(required_packages(ROOT)))


if __name__ == "__main__":
    main()
