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
import tarfile
import time
import urllib.parse
import urllib.request
import uuid

PRODUCERS = {"simolus3/sqlite3.dart", "edde746/libdovi-builds", "AppImage/type2-runtime", "bblanchon/pdfium-binaries", "gradle/gradle-distributions", "edde746/flutter-plezy", "boostorg/boost", "arvidn/libtorrent", "simdutf/simdutf", "ninja-build/ninja", "snapetech-org/mpv-build", "vslavik/winsparkle", "libsdl-org/SDL", "jrsoftware/issrc", "AppImage/appimagetool", "lg-flutter-webos/ndk", "lg-flutter-webos/artifacts", "ales-drnz/dart_smb2", "actions/python-versions"}


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
                       stdout=output, check=True, timeout=600)


def pinned_asset(repository, tag, name, expected, cache, release=None):
    if repository not in PRODUCERS or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Unreviewed native producer or digest")
    for part in (tag, name):
        if part in {".", ".."} or not re.fullmatch(r"[A-Za-z0-9_.+%\-]+", part):
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
    if asset.get("digest") not in (None, f"sha256:{expected}") or not 0 < asset.get("size", 0) <= (512 if repository in {"gradle/gradle-distributions", "edde746/flutter-plezy", "boostorg/boost", "snapetech-org/mpv-build", "lg-flutter-webos/ndk", "actions/python-versions"} else 64) * 1024**2:
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
            print(f"Verified native download: {name} {expected}", file=sys.stderr, flush=True)
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



# Same PDFium release selected by locked pdfium_dart 0.4.0. These are independent
# archive digests, rather than trusting an HTTP response or an existing output.
PDFIUM_PINS = {
    "android-arm": "bb9250eefb33343f56f27f7e60c81ab3236d932c40e21557bf02ca4c276eb832",
    "android-arm64": "f51539cadeb5135534305b8bdf8685ce2fbe9991dbbc5b35f553108411b9ed14",
    "android-x64": "23faaf6f993a39524d9dc7fafbb760e295f8bd5e9ffa46139bad2299fb5c80f3",
    "linux-arm64": "1682079aae24d73fcfb4f1ae115dd7b661780ad31ad43c8804da2d518dc546e8",
    "linux-x64": "e76e0a37aefb843d56f04657475ce612157021b1ebc53d801f2fbfcc537ccf64",
    "mac-arm64": "f9bbf1ebdc459e5f5ff25b2d457cc21db55ebfc0cf3d89fc1b90ce5445dac394",
    "mac-x64": "b31565aacda1f84393cd98438b06b49f21124888785e7dd1ddf015fa4406bd80",
    "win-arm64": "fa52ad62562a7bbe258c19fbf12adb794af2c204daba52a088ac1315a9968211",
    "win-x64": "2e7af12674ac3716cb0e20369bb9fb269ceadfa2f0b0597097a520e6834175a0",
}


def prepare_smb(root, platform, arch, cache):
    config_path = root / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text())
    entry = next(item for item in config["packages"] if item["name"] == "dart_smb2")
    uri = urllib.parse.urlparse(urllib.parse.urljoin(config_path.as_uri(), entry["rootUri"]))
    if uri.scheme != "file" or uri.netloc:
        raise ValueError("SMB must resolve to the locked local pub cache")
    hook = Path(urllib.request.url2pathname(uri.path)) / "hook/build.dart"
    if not hook.is_file() and platform == "tvos":
        return  # tvOS resolves the existing AMSMB2 MethodChannel adapter stub.
    content = hook.read_text()
    release = re.search(r"const _release = '([^']+)'", content)[1]
    hashes = dict(re.findall(r"'([^']+)':\s*'([a-f0-9]{64})'", content))
    if platform == "ios":
        targets = ["libsmb2_ios.xcframework.zip", "libsmb2_macos.xcframework.zip"]
    elif platform in {"macos", "tvos"}:
        targets = ["libsmb2_macos.xcframework.zip"]
    elif platform == "android":
        targets = [f"libsmb2_android-{abi}.so" for abi in ("armeabi-v7a", "arm64-v8a", "x86_64")] + ["libsmb2_linux-x86_64.so"]
    elif platform == "windows":
        targets = [f"libsmb2_windows-{'x86_64' if arch == 'x64' else 'arm64'}.dll"]
    else:
        targets = [f"libsmb2_linux-{'x86_64' if arch == 'x64' else 'aarch64'}.so"]
    for name in targets:
        digest = hashes[name]
        source = pinned_asset("ales-drnz/dart_smb2", release, name, digest, cache)
        target = root / ".dart_tool/hooks_runner/shared/dart_smb2/build" / digest / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            raise ValueError("Refusing linked SMB hook output")
        shutil.copyfile(source, target)  # The original hook verifies the full hash again.
        if sha256(target) != digest:
            raise ValueError("Staged SMB library changed")


def prepare_pdfium(root, platform, arch, cache):
    config_path = root / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text())
    entry = next(item for item in config["packages"] if item["name"] == "pdfium_dart")
    uri = urllib.parse.urlparse(urllib.parse.urljoin(config_path.as_uri(), entry["rootUri"]))
    if uri.scheme != "file" or uri.netloc:
        raise ValueError("PDFium must resolve to the locked local pub cache")
    package = Path(urllib.request.url2pathname(uri.path))
    hook = (package / "hook/build.dart").read_text()
    if "const _pdfiumRelease = 'chromium%2F7811';" not in hook:
        raise ValueError("PDFium release changed; review its archive pins")
    if platform in {"ios", "tvos"}:
        targets = ["mac-arm64"]
    elif platform == "macos":
        targets = ["mac-arm64", "mac-x64"]
    elif platform == "android":
        targets = ["android-arm", "android-arm64", "android-x64", "linux-x64"]
    else:
        targets = [f"{'win' if platform == 'windows' else 'linux'}-{arch}"]
    for target in targets:
        archive = pinned_asset("bblanchon/pdfium-binaries", "chromium%2F7811",
                               f"pdfium-{target}.tgz", PDFIUM_PINS[target], cache)
        filename = "pdfium.dll" if target.startswith("win-") else "libpdfium.dylib" if target.startswith("mac-") else "libpdfium.so"
        member_path = f"{'bin' if target.startswith('win-') else 'lib'}/{filename}"
        destination = root / ".dart_tool/hooks_runner/shared/pdfium_dart/build/chromium_7811" / target / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_symlink():
            raise ValueError("Refusing linked PDFium output")
        with tarfile.open(archive, "r:gz") as bundle:
            matches = [item for item in bundle.getmembers() if item.name == member_path]
            if len(matches) != 1 or not matches[0].isfile() or not 0 < matches[0].size < 256 * 1024**2:
                raise ValueError("Pinned PDFium archive has no unique regular library")
            with bundle.extractfile(matches[0]) as source, destination.open("wb") as output:
                shutil.copyfileobj(source, output)


def base36(value):
    result = ""
    while value:
        value, remainder = divmod(value, 36)
        result = "0123456789abcdefghijklmnopqrstuvwxyz"[remainder] + result
    return result or "0"


def prepare_gradle(root, cache):
    properties = (root / "android/gradle/wrapper/gradle-wrapper.properties").read_text()
    url = re.search(r"(?m)^distributionUrl=(.+)$", properties)[1].replace("\\:", ":")
    digest = re.search(r"(?m)^distributionSha256Sum=([a-f0-9]{64})$", properties)[1]
    match = re.fullmatch(r"https://services\.gradle\.org/distributions/gradle-([0-9.]+)-all\.zip", url)
    if not match:
        raise ValueError("Unreviewed Gradle distribution URL")
    version = match[1]
    # Gradle Wrapper uses the base-36 MD5 of its unchanged distribution URL.
    url_hash = base36(int.from_bytes(hashlib.md5(url.encode()).digest(), "big"))
    home = Path(os.environ.get("GRADLE_USER_HOME", str(Path.home() / ".gradle")))
    folder = home / "wrapper/dists" / f"gradle-{version}-all" / url_hash
    target = folder / f"gradle-{version}-all.zip"
    if target.with_suffix(".zip.ok").is_file() and (folder / f"gradle-{version}/bin/gradle").is_file():
        return  # Preserve a distribution already installed by the original Wrapper.
    archive = pinned_asset("gradle/gradle-distributions", f"v{version}", target.name, digest, cache)
    folder.mkdir(parents=True, exist_ok=True)
    if target.is_symlink():
        raise ValueError("Refusing linked Gradle archive")
    shutil.copyfile(archive, target)  # Original Wrapper still verifies and extracts it.


def prepare_github_url(url, expected, destination, cache):
    match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)", url)
    if not match:
        raise ValueError("Expected a pinned GitHub release asset")
    repository, tag, name = match.groups()
    source = pinned_asset(repository, tag, name, expected, cache)
    if destination.is_symlink():
        raise ValueError("Refusing linked pinned download output")
    shutil.copyfile(source, destination)


def prepare_cmake_downloads(root, platform, arch, cache):
    if platform == "linux":
        deps = root / "build/linux" / arch / "release/_deps"
        files = [root / "packages/plezy_torrent/src/CMakeLists.txt", root / "linux/CMakeLists.txt"]
    elif platform in {"ios", "tvos", "macos"}:
        deps = root / "build/p2p/dependencies"
        files = [root / "packages/plezy_torrent/src/CMakeLists.txt"]
    elif platform == "android":
        deps = Path(os.environ["RUNNER_TEMP"]) / "pleazyng-cmake-sources"
        files = [root / "packages/plezy_torrent/src/CMakeLists.txt"]
    else:
        raise ValueError("CMake archive preparation supports Linux and Android")
    for source in files:
        declarations = re.findall(r"FetchContent_Declare\(\s*(\w+)\s+URL\s+(https://github\.com/\S+)\s+URL_HASH SHA256=([a-f0-9]{64})", source.read_text())
        if not declarations:
            raise ValueError(f"No pinned FetchContent inputs in {source}")
        for name, url, digest in declarations:
            basename = url.rsplit("/", 1)[1]
            folder = deps / f"{name}-subbuild/{name}-populate-prefix/src"
            folder.mkdir(parents=True, exist_ok=True)
            archive = folder / basename
            prepare_github_url(url, digest, archive, cache)
            if platform == "android":
                target = deps / f"{name}-source"
                if target.exists():
                    raise ValueError(f"Refusing to replace existing native sources: {target}")
                with tempfile.TemporaryDirectory(prefix=f"{name}-extract-", dir=deps) as temporary:
                    with tarfile.open(archive) as bundle:
                        bundle.extractall(temporary, filter="data")
                    roots = list(Path(temporary).iterdir())
                    if len(roots) != 1 or not roots[0].is_dir() or roots[0].is_symlink():
                        raise ValueError("Native archive needs a single source directory")
                    roots[0].rename(target)
                with open(os.environ["GITHUB_ENV"], "a") as stream:
                    stream.write(f"PLEZYNG_CMAKE_SOURCE_{name.upper()}={target.resolve()}\n")




def prepare_webos_python(cache):
    if os.name != "posix" or os.uname().machine != "x86_64" or 'VERSION_ID="24.04"' not in Path("/etc/os-release").read_text():
        raise ValueError("Pinned webOS Python requires Ubuntu 24.04 x86_64")
    toolcache = Path(os.environ["RUNNER_TOOL_CACHE"])
    destination = toolcache / "Python/3.14.8/x64"
    marker = destination.with_name("x64.complete")
    environment = {**os.environ, "AGENT_TOOLSDIRECTORY": str(toolcache),
                   "LD_LIBRARY_PATH": str(destination / "lib") + (":" + os.environ["LD_LIBRARY_PATH"] if os.environ.get("LD_LIBRARY_PATH") else "")}
    if destination.is_symlink() or marker.is_symlink():
        raise ValueError("Refusing linked Python cache")
    if destination.exists() or marker.exists():
        if not destination.is_dir() or not marker.is_file():
            raise ValueError("Existing incomplete Python cache retained; refusing to replace it")
        result = subprocess.check_output([str(destination / "bin/python3.14"), "--version"], text=True, env=environment).strip()
        if result != "Python 3.14.8":
            raise ValueError("Existing Python cache has the wrong version")
        return
    archive = pinned_asset("actions/python-versions", "3.14.8-36806082737",
                           "python-3.14.8-linux-24.04-x64.tar.gz",
                           "fa74abc70a55c10f6631967784878704eef81bbde9b8ec27469534f6ba997cb3", cache)
    stage = Path(tempfile.mkdtemp(prefix="pleazyng-python-install-", dir=os.environ["RUNNER_TEMP"]))
    print(f"Pinned Python installer scratch: {stage}", flush=True)
    try:
        with tarfile.open(archive) as bundle:
            bundle.extractall(stage, filter="data")
        # The pinned upstream installer creates the completion marker only after
        # successful installation. Its replace-existing branch is excluded above.
        subprocess.run(["bash", "setup.sh"], cwd=stage, env=environment, check=True)
        if not marker.is_file() or subprocess.check_output([str(destination / "bin/python3.14"), "--version"], text=True, env=environment).strip() != "Python 3.14.8":
            raise ValueError("Upstream Python installer did not produce its expected cache")
    except Exception:
        print(f"Retained Python installer diagnostics: {stage}", file=sys.stderr)
        raise
    else:
        shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    parser.add_argument("--cache-dir", type=Path, default=Path(os.environ.get("PLEAZYNG_NATIVE_DOWNLOAD_CACHE", str(Path.home() / ".cache/pleazyng-native-downloads"))))
    parser.add_argument("--sqlite-platform", choices=("android", "ios", "tvos", "macos", "windows", "linux"))
    parser.add_argument("--appimage-runtime", type=Path)
    parser.add_argument("--github-url")
    parser.add_argument("--webos-python", action="store_true")
    parser.add_argument("--expected-sha")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--arch", choices=("x64", "arm64"))
    parser.add_argument("--libdovi", action="store_true")
    parser.add_argument("--cmake-deps", action="store_true")
    parser.add_argument("--curl-wrapper-dir", type=Path)
    args = parser.parse_args()
    if not args.sqlite_platform and not args.appimage_runtime and not args.github_url and not args.webos_python:
        parser.error("Specify --sqlite-platform or --appimage-runtime")
    if args.webos_python:
        prepare_webos_python(args.cache_dir.resolve())
    if args.sqlite_platform:
        prepare_sqlite(args.project_root.resolve(), args.sqlite_platform, args.arch, args.cache_dir.resolve())
        prepare_pdfium(args.project_root.resolve(), args.sqlite_platform, args.arch, args.cache_dir.resolve())
        prepare_smb(args.project_root.resolve(), args.sqlite_platform, args.arch, args.cache_dir.resolve())
        if args.sqlite_platform in {"ios", "tvos", "macos"}:
            prepare_cmake_downloads(args.project_root.resolve(), args.sqlite_platform, args.arch, args.cache_dir.resolve())
        if args.sqlite_platform == "android":
            prepare_gradle(args.project_root.resolve(), args.cache_dir.resolve())
    if args.cmake_deps:
        prepare_cmake_downloads(args.project_root.resolve(), args.sqlite_platform, args.arch, args.cache_dir.resolve())
    if args.github_url:
        if not args.expected_sha or not args.output:
            parser.error("Pinned GitHub downloads require --expected-sha and --output")
        prepare_github_url(args.github_url, args.expected_sha, args.output, args.cache_dir.resolve())
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
