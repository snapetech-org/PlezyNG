#!/usr/bin/env python3
"""Prefetch pinned native assets via fresh GitHub API redirects, retaining SHA checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

PRODUCERS = {"simolus3/sqlite3.dart", "edde746/libdovi-builds", "AppImage/type2-runtime"}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def github_json(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", endpoint], timeout=90))


def download_asset(repository, asset_id, destination):
    endpoint = f"repos/{repository}/releases/assets/{asset_id}?pleazyng_verify={uuid.uuid4().hex}"
    # Older runner images predate the raw-output switch. Test CLI capability
    # locally; never pass an unsupported switch to an otherwise valid fetch.
    supports_raw = subprocess.run(["gh", "api", "--allow-escape-sequences", "--help"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    with destination.open("wb") as output:
        subprocess.run(["gh", "api", *(["--allow-escape-sequences"] if supports_raw else []), "-H", "Accept: application/octet-stream", endpoint],
                       stdout=output, check=True, timeout=120)


def pinned_asset(repository, tag, name, expected, cache, release=None):
    if repository not in PRODUCERS or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Unreviewed native producer or digest")
    for part in (tag, name):
        if part in {".", ".."} or not re.fullmatch(r"[A-Za-z0-9_.+-]+", part):
            raise ValueError("Unsafe native asset name")
    folder = cache / repository.replace("/", "_") / tag
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / name
    if target.is_symlink():
        raise ValueError(f"Refusing linked native cache: {target}")
    if target.is_file() and sha256(target) == expected:
        return target
    release = release or github_json(f"repos/{repository}/releases/tags/{tag}")
    matches = [asset for asset in release.get("assets", []) if asset.get("name") == name]
    if len(matches) != 1:
        raise ValueError(f"Native asset is not unique: {repository}/{tag}/{name}")
    asset = matches[0]
    if asset.get("digest") != f"sha256:{expected}" or not 0 < asset.get("size", 0) <= 64 * 1024**2:
        raise ValueError(f"Upstream native asset does not match its independent pin: {name}")
    failure = None
    for attempt in range(3):
        descriptor, temporary = tempfile.mkstemp(prefix=f".{name}.", dir=folder)
        os.close(descriptor)
        temporary = Path(temporary)
        try:
            download_asset(repository, asset["id"], temporary)
            if temporary.stat().st_size != asset["size"] or sha256(temporary) != expected:
                raise ValueError(f"Downloaded native asset failed its pinned size/hash: {name}")
            temporary.replace(target)
            print(f"Verified native download: {name} {expected}", flush=True)
            return target
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            failure = error
        finally:
            temporary.unlink(missing_ok=True)
        if attempt < 2:
            time.sleep(attempt + 1)
    raise RuntimeError(f"Unable to obtain verified native asset: {name}") from failure


def sqlite_inputs(root):
    config_path = root / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text())
    packages = [entry for entry in config["packages"] if entry.get("name") == "sqlite3"]
    if len(packages) != 1:
        raise ValueError("Locked sqlite3 package is not resolved")
    uri = urllib.parse.urlparse(urllib.parse.urljoin(config_path.as_uri(), packages[0]["rootUri"]))
    if uri.scheme != "file" or uri.netloc:
        raise ValueError("sqlite3 must resolve to the local verified pub cache")
    package = Path(urllib.request.url2pathname(uri.path))
    hashes = (package / "lib/src/hook/asset_hashes.dart").read_text()
    tag = re.search(r"releaseTag\s*=\s*'([^']+)'", hashes)
    block = re.search(r"(?ms)^  sqlite3:\n(.*?)(?=^  \S|\Z)", (root / "pubspec.lock").read_text())
    version = re.search(r'^    version: "([^"]+)"$', block[1], re.M) if block else None
    if not tag or not version or tag[1] != f"sqlite3-{version[1]}":
        raise ValueError("sqlite3 hook metadata differs from pubspec.lock")
    return tag[1], dict(re.findall(r"'([^']+)': '([0-9a-f]{64})'", hashes))


def sqlite_assets(platform, arch):
    if platform in {"ios", "tvos"}:
        return ["libsqlite3.arm64.ios.dylib", "libsqlite3.arm64.macos.dylib"]
    if platform == "macos":
        return ["libsqlite3.arm64.macos.dylib", "libsqlite3.x64.macos.dylib"]
    if platform == "android":
        return [f"libsqlite3.{item}.android.so" for item in ("arm", "arm64", "x64")] + ["libsqlite3.x64.linux.so"]
    if arch not in {"x64", "arm64"}:
        raise ValueError("Specify the native release architecture")
    return [f"sqlite3.{arch}.windows.dll" if platform == "windows" else f"libsqlite3.{arch}.linux.so"]


def prepare_sqlite(root, platform, arch, cache):
    tag, hashes = sqlite_inputs(root)
    release = None
    for name in sqlite_assets(platform, arch):
        expected = hashes.get(name)
        if expected is None:
            raise ValueError(f"sqlite3 has no pinned asset for {name}")
        source = pinned_asset("simolus3/sqlite3.dart", tag, name, expected, cache, release)
        # This is the pinned hooks_runner shared-output layout. The unmodified
        # sqlite3 hook re-hashes these files and reuses them rather than fetching.
        filename = "sqlite3.dll" if name.endswith(".dll") else "libsqlite3.dylib" if name.endswith(".dylib") else "libsqlite3.so"
        folder = root / ".dart_tool/hooks_runner/shared/sqlite3/build" / f"download-{expected[:8]}"
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / filename
        if target.is_symlink():
            raise ValueError(f"Refusing linked native output: {target}")
        shutil.copyfile(source, target)
        if sha256(target) != expected:
            raise ValueError(f"Staged sqlite3 asset changed: {name}")


def prepare_dovi(root, cache, wrapper_dir):
    source = (root / "android/app/build.gradle.kts").read_text()
    version = re.search(r'val doviVersion = "([^"]+)"', source)
    pins = re.findall(r'"([a-z0-9_-]+)" to Pair\(\s*"([a-z0-9_-]+)",\s*"([0-9a-f]{64})"', source)
    if not version or {entry[0] for entry in pins} != {"arm64-v8a", "armeabi-v7a", "x86", "x86_64"}:
        raise ValueError("Unrecognized pinned libdovi declaration")
    tag = f"v{version[1]}"
    metadata = github_json(f"repos/edde746/libdovi-builds/releases/tags/{tag}")
    mapping = {}
    for _, triple, expected in pins:
        name = f"libdovi-{triple}.tar.gz"
        path = pinned_asset("edde746/libdovi-builds", tag, name, expected, cache, metadata)
        mapping[f"https://github.com/edde746/libdovi-builds/releases/download/{tag}/{name}"] = {"path": str(path), "sha256": expected}
    real_curl = shutil.which("curl")
    if not real_curl:
        raise ValueError("The build host has no curl")
    wrapper_dir.mkdir(parents=True, exist_ok=True)
    (wrapper_dir / "downloads.json").write_text(json.dumps({"curl": real_curl, "assets": mapping}))
    wrapper = wrapper_dir / "curl"
    wrapper.write_text('''#!/usr/bin/env python3
import hashlib, json, os, pathlib, shutil, sys
config = json.loads(pathlib.Path(__file__).with_name("downloads.json").read_text())
args = sys.argv[1:]
if len(args) == 4 and args[0] == "-sfL" and args[2] == "-o" and args[1] in config["assets"]:
    entry = config["assets"][args[1]]
    source, target = pathlib.Path(entry["path"]), pathlib.Path(args[3])
    if source.is_symlink() or target.is_symlink():
        raise SystemExit("Refusing linked libdovi download")
    if hashlib.sha256(source.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit("Pinned libdovi cache changed")
    shutil.copyfile(source, target)
    if hashlib.sha256(target.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit("Staged libdovi download changed")
    raise SystemExit(0)
os.execv(config["curl"], [config["curl"], *args])
''')
    wrapper.chmod(0o755)
    github_path = os.environ.get("GITHUB_PATH")
    if github_path:
        with open(github_path, "a") as stream:
            stream.write(str(wrapper_dir.resolve()) + "\n")
    print(f"Pinned libdovi curl cache: {wrapper_dir}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--cache-dir", type=Path, default=Path.home() / ".cache/pleazyng-native-downloads")
    parser.add_argument("--sqlite-platform", choices=("android", "ios", "tvos", "macos", "windows", "linux"))
    parser.add_argument("--appimage-runtime", type=Path)
    parser.add_argument("--arch", choices=("x64", "arm64"))
    parser.add_argument("--libdovi", action="store_true")
    parser.add_argument("--curl-wrapper-dir", type=Path)
    args = parser.parse_args()
    if not args.sqlite_platform and not args.appimage_runtime:
        parser.error("Specify --sqlite-platform or --appimage-runtime")
    if args.sqlite_platform:
        prepare_sqlite(args.project_root.resolve(), args.sqlite_platform, args.arch, args.cache_dir.resolve())
    if args.appimage_runtime:
        # Pin the runtime independently; never let appimagetool fetch a rolling binary.
        source = pinned_asset("AppImage/type2-runtime", "continuous", "runtime-x86_64",
                              "617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46",
                              args.cache_dir.resolve())
        if args.appimage_runtime.is_symlink():
            raise ValueError("Refusing linked AppImage runtime output")
        shutil.copyfile(source, args.appimage_runtime)
    if args.libdovi:
        if not args.curl_wrapper_dir or os.name != "posix":
            raise ValueError("Android libdovi preparation requires a POSIX wrapper directory")
        prepare_dovi(args.project_root.resolve(), args.cache_dir.resolve(), args.curl_wrapper_dir.resolve())


if __name__ == "__main__":
    main()
