#!/usr/bin/env python3
"""Guard the architecture matrices and release contract in build.yml."""

import json
from pathlib import Path
import re
import sys

from workflow_yaml import iter_uses_references, job_block


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WORKFLOW = ROOT / ".github/workflows/build.yml"
FLUTTER_VERSION = "3.47.1"
FLUTTER_COMMIT = "6655482ec06e547f90abf8ae7590466f4415978d"
if len(sys.argv) > 2:
    raise SystemExit(f"Usage: {Path(sys.argv[0]).name} [workflow-path]")
WORKFLOW = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else DEFAULT_WORKFLOW
# Resolve the shared bootstrap and the Windows CMake file beside the workflow
# so fixture checks use their local copies rather than the checkout's real ones.
SETUP_FLUTTER_GIT = WORKFLOW.parents[1] / "actions/setup-flutter-git/action.yml"
SETUP_FLUTTER_WINDOWS = ROOT / ".github/actions/setup-flutter-windows/action.yml"
WINDOWS_CMAKE = WORKFLOW.parents[2] / "windows/CMakeLists.txt"
STEAM_CMAKE = WORKFLOW.parents[2] / "native/games/steam/CMakeLists.txt"
WINDOWS_MPV_DOWNLOADER = WORKFLOW.parents[2] / "windows/tool/download-pinned-mpv.ps1"
MPV_BUILD_LOCK = WORKFLOW.parents[2] / "mpv-build.lock.json"
WINDOWS_SIMDUTF_DOWNLOADER = (
    WORKFLOW.parents[2] / "windows/tool/download-pinned-simdutf.ps1"
)
WINDOWS_WINSPARKLE_DOWNLOADER = (
    WORKFLOW.parents[2] / "windows/tool/download-pinned-winsparkle.ps1"
)
WINDOWS_SDL3_DOWNLOADER = (
    WORKFLOW.parents[2] / "windows/tool/download-pinned-sdl3.ps1"
)
WINDOWS_TORRENT_DEPENDENCIES_DOWNLOADER = (
    WORKFLOW.parents[2] / "windows/tool/download-pinned-torrent-dependencies.ps1"
)
WINDOWS_TOOLCHAIN_LOCK = WORKFLOW.parents[2] / "windows/tool/build-toolchain.lock.json"
PLEZY_TORRENT_CMAKE = WORKFLOW.parents[2] / "packages/plezy_torrent/src/CMakeLists.txt"
WEBOS_CANDIDATE_BUILDER = ROOT / "tools/webos/build_release_candidate.sh"
WEBOS_IPK_BUILDER = ROOT / "tools/webos/build_ipk.sh"
WEBOS_RELEASE_GATE = ROOT / "tools/webos/check_release_eligibility.py"
SNAP_BUILDER = ROOT / "scripts/build_snap.sh"
TIZEN_WORKFLOW = ROOT / ".github/workflows/tizen.yml"
RELEASE_CHECKSUMS = ROOT / "scripts/create_release_checksums.py"
text = WORKFLOW.read_text(encoding="utf-8")
CI_WORKFLOW = ROOT / ".github/workflows/ci.yml"
ci_text = CI_WORKFLOW.read_text(encoding="utf-8") if CI_WORKFLOW.is_file() else ""
errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def job(name: str) -> str:
    block = job_block(text, name)
    require(bool(block), f"missing {name} job")
    return block


def named_step(block: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^      - name: {re.escape(name)}\n.*?(?=^      - |\Z)",
        block,
    )
    require(match is not None, f"missing '{name}' step")
    return match.group(0) if match else ""


def validate_windows_jni_jdk(block: str, context: str) -> None:
    setup_java = named_step(block, "Setup Java")
    require(
        "uses: actions/setup-java@b843ebf9b913146b38da2eaa7aeddf76074ae1ad # v5"
        in setup_java
        and 'distribution: "temurin"' in setup_java
        and 'java-version: "21"' in setup_java
        and "architecture: ${{ matrix.arch == 'arm64' && 'aarch64' || 'x64' }}"
        in setup_java,
        f"{context} must provision pinned native JDK 21 for JNI",
    )


def validate_windows_signing(block: str) -> None:
    install = named_step(block, "Install dependencies")
    signing = named_step(block, "Sign installer for WinSparkle (EdDSA)")
    require(
        block.find("      - name: Install dependencies")
        < block.find("      - name: Sign installer for WinSparkle (EdDSA)"),
        "locked root dependencies must be installed before Windows signing",
    )
    require(
        "flutter pub get --enforce-lockfile --no-example" in install,
        "Windows signing must use the enforced root dependency lock",
    )
    require(
        "dart run auto_updater:sign_update plezy-windows-installer.exe $keyPath"
        in signing,
        "Windows signing must execute the locked auto_updater package",
    )
    require(
        "$env:RUNNER_TEMP" in signing,
        "Windows signing key must live under RUNNER_TEMP",
    )
    require(
        "try {" in signing and "} finally {" in signing,
        "Windows signing key cleanup must run from a finally block",
    )
    require(
        "Remove-Item -Path $keyPath -Force -ErrorAction SilentlyContinue"
        in signing,
        "Windows signing must remove its temporary key",
    )
    lowered = signing.lower()
    for forbidden in (
        "raw.githubusercontent.com",
        "invoke-webrequest",
        "git clone",
        "_signer",
        "pubspec.yaml",
        "dart pub get",
    ):
        require(
            forbidden not in lowered,
            f"Windows signing step contains mutable or ad-hoc input: {forbidden}",
        )


def require_explicit_shells(name: str, block: str, shell: str) -> None:
    steps = re.findall(r"(?ms)^      - .*?(?=^      - |\Z)", block)
    run_steps = [step for step in steps if re.search(r"(?m)^        run:", step)]
    require(bool(run_steps), f"{name} must contain run steps")
    for step in run_steps:
        step_name = re.search(r"(?m)^      - name: (.+)$", step)
        label = step_name.group(1) if step_name else "unnamed step"
        require(
            f"        shell: {shell}\n" in step,
            f"{name} step '{label}' must explicitly use {shell}",
        )


for legacy_job in (
    "build-windows-x64",
    "build-windows-arm64",
    "build-linux-x64",
    "build-linux-arm64",
):
    require(f"  {legacy_job}:\n" not in text, f"legacy job {legacy_job} must stay removed")

windows = job("build-windows")
windows_checkout = re.search(
    r"(?ms)^      - uses: actions/checkout@[^\n]+\n(?P<step>.*?)(?=^      - |\Z)",
    windows,
)
require(
    windows_checkout is not None
    and re.search(r"(?m)^          fetch-depth: 0$", windows_checkout.group("step")) is not None,
    "Windows release checkout must fetch tags for the pinned Opus CMake version probe",
)
validate_windows_jni_jdk(windows, "Windows release builds")
require(
    '"group":"packer-windows"' in windows
    and '"Windows","X64"' in windows
    and '"PlezyNG"' in windows,
    "Windows x64 must retain its private route for the private profile",
)
require(
    "'windows-2025'" in windows
    and "'windows-11-vs2026-arm'" in windows,
    "the hybrid release must use standard native Windows x64 and ARM64 runners",
)
require("fail-fast: false" in windows, "Windows matrix must not cancel its other architecture")
require(
    '"arch":"x64","flutter_setup":"action","native_cache_path":"build/windows/x64/_deps"' in windows,
    "Windows x64 matrix configuration changed",
)
require(
    '"arch":"arm64","flutter_setup":"git","native_cache_path":"build/windows/arm64/_deps"' in windows
    and "matrix: ${{ fromJSON(needs.validate-trusted-ref.outputs.execution_profile == 'hybrid'" in windows
    and '"include":[{"arch":"x64"' in windows,
    "native Windows ARM64 must be present only in the hybrid 3.0.0 build matrix",
)
require(
    'CMAKE_GENERATOR=Visual Studio 18 2026' in named_step(
        windows, "Select Visual Studio 2026 generator for hybrid ARM64"
    ),
    "hybrid Windows ARM64 release builds must use the Visual Studio 2026 generator",
)
require(
    "CMAKE_GENERATOR_TOOLSET" not in windows
    and "CC=clang-cl" not in windows
    and "CXX=clang-cl" not in windows,
    "Flutter Windows ARM64 plugins must use the default MSVC toolset",
)
whisper_arm64_release = named_step(windows, "Build the pinned Whisper ARM64 backend with Clang")
require(
    "scripts/prepare_windows_arm64_whisper.py" in whisper_arm64_release
    and windows.find("name: Install dependencies") < windows.find("name: Build the pinned Whisper ARM64 backend with Clang"),
    "the hash-locked Whisper ARM64 backend must be built before Flutter configures Windows",
)
whisper_arm64_builder = (ROOT / "scripts/prepare_windows_arm64_whisper.py").read_text(encoding="utf-8")
require(
    all(value in whisper_arm64_builder for value in (
        "WHISPER_PLUGIN_CMAKE_SHA256",
        "ClangCL", "MSVC", "GGML_NATIVE=OFF", "FLUTTER_WHISPER_PREBUILT_ROOT",
        "IMPORTED_IMPLIB_RELEASE", "whisper", "ggml-base", "ggml-cpu",
    )),
    "the pinned Whisper dependency must use its hash-locked Clang library with the MSVC Flutter plugin",
)
for expected in (
    "if: matrix.flutter_setup == 'action'",
    "if: matrix.flutter_setup == 'git'",
    "uses: ./.github/actions/setup-flutter-git",
    "flutter pub get --enforce-lockfile --no-example",
    "--split-debug-info=debug-info/windows-${{ matrix.arch }}",
    "name: windows-${{ matrix.arch }}-build",
    "path: build/windows/${{ matrix.arch }}/runner/Release/",
):
    require(expected in windows, f"Windows matrix missing: {expected}")
# libmpv comes from our mpv-build release zips via FetchContent for both
# arches (no 7-Zip, no unpinned sourceforge download); the asset name and
# checksum must be read from mpv-build.lock.json, never pinned by hand, and
# the checksum must stay enforced.
windows_cmake = WINDOWS_CMAKE.read_text(encoding="utf-8") if WINDOWS_CMAKE.is_file() else ""
require(bool(windows_cmake), "missing windows/CMakeLists.txt")
require(
    'set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}" CACHE PATH' in windows_cmake
    and 'set(INSTALL_BUNDLE_DATA_DIR "${BUILD_BUNDLE_DIR}/data")' in windows_cmake
    and 'set(INSTALL_BUNDLE_LIB_DIR "${BUILD_BUNDLE_DIR}")' in windows_cmake
    and 'install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${BUILD_BUNDLE_DIR}"' in windows_cmake
    and 'set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${BUILD_BUNDLE_DIR}")' in windows_cmake,
    "Windows must keep CMAKE_INSTALL_PREFIX concrete and route app bundle files to the target output directory",
)
torrent_cmake = PLEZY_TORRENT_CMAKE.read_text(encoding="utf-8") if PLEZY_TORRENT_CMAKE.is_file() else ""
require(
    '"$<TARGET_FILE_DIR:${BINARY_NAME}>/share/plezy/licenses"' in torrent_cmake,
    "Windows libtorrent notices must remain in the executable bundle when dependency staging uses a concrete prefix",
)
snap_builder = SNAP_BUILDER.read_text(encoding="utf-8") if SNAP_BUILDER.is_file() else ""
require(
    bool(snap_builder)
    and '"${RUNNER_ENVIRONMENT:-}" == self-hosted' in snap_builder
    and '"${RUNNER_ENVIRONMENT:-}" == github-hosted' in snap_builder
    and '"${PLEZYNG_ALLOW_PUBLIC_SNAP:-}" == true' in snap_builder
    and '"${GITHUB_REPOSITORY:-}" == snapetech-org/PlezyNG' in snap_builder
    and '"${GITHUB_REF:-}" == refs/heads/main' in snap_builder
    and '"${GITHUB_EVENT_NAME:-}" == workflow_dispatch' in snap_builder,
    "public Snap packaging must be limited to the explicitly enabled trusted-main workflow",
)
require(
    "PLEZYNG_ALLOW_PUBLIC_SNAP: ${{ needs.validate-trusted-ref.outputs.execution_profile == 'hybrid' && 'true' || 'false' }}"
    in text,
    "the hosted Snap lane must be explicitly enabled only by the validated hybrid profile",
)
steam_cmake = STEAM_CMAKE.read_text(encoding="utf-8") if STEAM_CMAKE.is_file() else ""
require(
    re.search(
        r"(?s)if\(DEFINED BUILD_SHARED_LIBS\).*?"
        r"set\(BUILD_SHARED_LIBS OFF\)\s+"
        r"add_subdirectory\(\"\$\{PLEZY_STEAM_SOURCE\}/mbedtls\".*?\)\s+"
        r"if\(_PLEZY_STEAM_PARENT_BUILD_SHARED_LIBS_DEFINED\)\s+"
        r"set\(BUILD_SHARED_LIBS \"\$\{_PLEZY_STEAM_PARENT_BUILD_SHARED_LIBS\}\"\)\s+"
        r"else\(\)\s+unset\(BUILD_SHARED_LIBS\)\s+endif\(\)",
        steam_cmake,
    )
    is not None,
    "Mbed TLS Everest must stay static even when the parent enables BUILD_SHARED_LIBS",
)
windows_mpv_block = windows_cmake.split("FetchContent_MakeAvailable(mpv_dev)", 1)[0]
windows_mpv_downloader = (
    WINDOWS_MPV_DOWNLOADER.read_text(encoding="utf-8")
    if WINDOWS_MPV_DOWNLOADER.is_file()
    else ""
)
mpv_build_lock = (
    json.loads(MPV_BUILD_LOCK.read_text(encoding="utf-8"))
    if MPV_BUILD_LOCK.is_file()
    else {}
)
windows_mpv_lock = mpv_build_lock.get("artifacts", {}).get("windows", {})
windows_simdutf_downloader = (
    WINDOWS_SIMDUTF_DOWNLOADER.read_text(encoding="utf-8")
    if WINDOWS_SIMDUTF_DOWNLOADER.is_file()
    else ""
)
windows_simdutf_downloader_normalized = windows_simdutf_downloader.replace("\\", "/")
windows_winsparkle_downloader = (
    WINDOWS_WINSPARKLE_DOWNLOADER.read_text(encoding="utf-8")
    if WINDOWS_WINSPARKLE_DOWNLOADER.is_file()
    else ""
)
windows_winsparkle_downloader_normalized = windows_winsparkle_downloader.replace("\\", "/")
windows_sdl3_downloader = (
    WINDOWS_SDL3_DOWNLOADER.read_text(encoding="utf-8")
    if WINDOWS_SDL3_DOWNLOADER.is_file()
    else ""
)
windows_sdl3_downloader_normalized = windows_sdl3_downloader.replace("\\", "/")
windows_torrent_dependencies_downloader = (
    WINDOWS_TORRENT_DEPENDENCIES_DOWNLOADER.read_text(encoding="utf-8")
    if WINDOWS_TORRENT_DEPENDENCIES_DOWNLOADER.is_file()
    else ""
)
windows_torrent_dependencies_downloader_normalized = (
    windows_torrent_dependencies_downloader.replace("\\", "/")
)
plezy_torrent_cmake = (
    PLEZY_TORRENT_CMAKE.read_text(encoding="utf-8")
    if PLEZY_TORRENT_CMAKE.is_file()
    else ""
)
windows_toolchain_lock = {}
if WINDOWS_TOOLCHAIN_LOCK.is_file():
    windows_toolchain_lock = json.loads(WINDOWS_TOOLCHAIN_LOCK.read_text(encoding="utf-8"))
windows_winsparkle_pin = windows_toolchain_lock.get("winSparkle", {})
windows_sdl3_pin = windows_toolchain_lock.get("sdl3", {})
windows_boost_pin = windows_toolchain_lock.get("boost", {})
windows_libtorrent_pin = windows_toolchain_lock.get("libtorrent", {})
require(
    "URL_HASH SHA256=${MPV_SHA256}" in windows_mpv_block,
    "Windows libmpv fetch must keep URL_HASH enforcement",
)
require(
    "string(JSON MPV_SHA256 GET " in windows_mpv_block
    and re.search(r"[0-9a-f]{64}", windows_mpv_block) is None,
    "Windows libmpv checksum must come from mpv-build.lock.json, not a literal",
)
require(
    "MPV_LOCAL_ARCHIVE" in windows_mpv_block
    and "PLEZYNG_MPV_ARCHIVE_PATH" in windows_mpv_block
    and "set(MPV_DOWNLOAD_URL" in windows_mpv_block
    and "URL_HASH SHA256=${MPV_SHA256}" in windows_mpv_block,
    "Windows CMake must use a predownloaded MPV archive without dropping lockfile hash verification",
)
require(
    "PLEZYNG_WINDOWS_CURL_PATH" in windows_cmake
    and "sdk.lunarg.com" in windows_cmake
    and "--ssl-revoke-best-effort" in windows_cmake
    and "file(SHA256" in windows_cmake
    and "VULKAN_RT_SHA256" in windows_cmake,
    "Windows Vulkan runtime downloads must use verified Schannel curl and keep the pinned SHA-256",
)
require(
    "SIMDUTF_LOCAL_ARCHIVE" in windows_cmake
    and "PLEZYNG_SIMDUTF_ARCHIVE_PATH" in windows_cmake
    and "URL_HASH SHA256=9fe4d6f515724a55c8de88fee4463e0890a1abe2267cda13c4b5d245d58039e6"
    in windows_cmake,
    "Windows simdutf must support the predownloaded archive and retain its pinned SHA-256",
)
require(
    "PLEZYNG_WINSPARKLE_SOURCE_DIR" in windows_cmake
    and "FETCHCONTENT_SOURCE_DIR_WINSPARKLE" in windows_cmake
    and "include/winsparkle.h" in windows_cmake
    and "x64/Release/WinSparkle.lib" in windows_cmake
    and "ARM64/Release/WinSparkle.lib" in windows_cmake,
    "Windows CMake must use and validate the checksum-verified WinSparkle source override",
)
require(
    "PLEZYNG_SDL3_SOURCE_DIR" in windows_cmake
    and "FETCHCONTENT_SOURCE_DIR_SDL3" in windows_cmake
    and "include/SDL3/SDL.h" in windows_cmake,
    "Windows CMake must use and validate the checksum-verified SDL3 source override",
)
require(
    "PLEZYNG_BOOST_SOURCE_DIR" in windows_cmake
    and "FETCHCONTENT_SOURCE_DIR_PLEZY_BOOST" in windows_cmake
    and "boost/version.hpp" in windows_cmake
    and "LICENSE_1_0.txt" in windows_cmake,
    "Windows CMake must use and validate the checksum-verified Boost source override",
)
require(
    "PLEZYNG_LIBTORRENT_SOURCE_DIR" in windows_cmake
    and "FETCHCONTENT_SOURCE_DIR_LIBTORRENT" in windows_cmake
    and "include/libtorrent/version.hpp" in windows_cmake
    and "COPYING" in windows_cmake,
    "Windows CMake must use and validate the checksum-verified libtorrent source override",
)
require(bool(windows_mpv_downloader), "missing pinned Windows MPV download helper")
windows_mpv_repo = mpv_build_lock.get("repo")
windows_mpv_expected_base = (
    f"https://github.com/{windows_mpv_repo}/releases/download/binaries-windows"
)
require(
    windows_mpv_repo == "snapetech-org/mpv-build"
    and windows_mpv_lock.get("assetBase") == windows_mpv_expected_base
    and "snapetech-org/mpv-build" in windows_mpv_downloader
    and "$lock.repo" in windows_mpv_downloader
    and "$expectedAssetBase" in windows_mpv_downloader
    and "$base.Port -ne 443" in windows_mpv_downloader,
    "Windows MPV downloader must validate the locked snapetech-org/mpv-build artifact base",
)
for expected in (
    "[ValidateSet('x64', 'arm64')]",
    "mpv-build.lock.json",
    "github.com",
    "HTTPS_PROXY",
    "--proxy",
    "--ssl-revoke-best-effort",
    "Schannel",
    "Get-FileHash -Algorithm SHA256",
    "PLEZYNG_MPV_ARCHIVE_PATH=",
    "PLEZYNG_WINDOWS_CURL_PATH=",
):
    require(expected in windows_mpv_downloader, f"Windows MPV bootstrap must keep: {expected}")
require(bool(windows_simdutf_downloader), "missing pinned Windows simdutf download helper")
for expected in (
    "linux/packaging/native-inputs.json",
    "inputs.simdutf",
    "github.com",
    "HTTPS_PROXY",
    "--proxy",
    "--ssl-revoke-best-effort",
    "Schannel",
    "Get-FileHash -Algorithm SHA256",
    "PLEZYNG_SIMDUTF_ARCHIVE_PATH=",
):
    require(
        expected in windows_simdutf_downloader_normalized,
        f"Windows simdutf bootstrap must keep: {expected}",
    )
for forbidden in ("--ssl-no-revoke", "--insecure"):
    require(
        forbidden not in windows_simdutf_downloader,
        f"Windows simdutf bootstrap must not use {forbidden}",
    )
require(bool(windows_winsparkle_downloader), "missing pinned Windows WinSparkle download helper")
for expected in (
    "build-toolchain.lock.json",
    "winSparkle",
    "github.com",
    "/vslavik/winsparkle/releases/download/v$version/$filename",
    "HTTPS_PROXY",
    "--proxy",
    "--ssl-revoke-best-effort",
    "Schannel",
    "Get-FileHash -Algorithm SHA256",
    "Expand-Archive",
    "include/winsparkle.h",
    "x64/Release/WinSparkle.lib",
    "ARM64/Release/WinSparkle.lib",
    "PLEZYNG_WINSPARKLE_SOURCE_DIR=",
):
    require(
        expected in windows_winsparkle_downloader_normalized,
        f"Windows WinSparkle bootstrap must keep: {expected}",
    )
for forbidden in ("--ssl-no-revoke", "--insecure"):
    require(
        forbidden not in windows_winsparkle_downloader,
        f"Windows WinSparkle bootstrap must not use {forbidden}",
    )
require(bool(windows_sdl3_downloader), "missing pinned Windows SDL3 download helper")
for expected in (
    "build-toolchain.lock.json",
    "sdl3",
    "github.com",
    "/libsdl-org/SDL/releases/download/release-$version/$filename",
    "HTTPS_PROXY",
    "--proxy",
    "--ssl-revoke-best-effort",
    "Schannel",
    "Get-FileHash -Algorithm SHA256",
    "Expand-Archive",
    "CMakeLists.txt",
    "include/SDL3/SDL.h",
    "PLEZYNG_SDL3_SOURCE_DIR=",
):
    require(
        expected in windows_sdl3_downloader_normalized,
        f"Windows SDL3 bootstrap must keep: {expected}",
    )
for forbidden in ("--ssl-no-revoke", "--insecure"):
    require(
        forbidden not in windows_sdl3_downloader,
        f"Windows SDL3 bootstrap must not use {forbidden}",
    )
require(
    bool(windows_torrent_dependencies_downloader),
    "missing pinned Windows Boost/libtorrent download helper",
)
for expected in (
    "build-toolchain.lock.json",
    "boost",
    "libtorrent",
    "github.com",
    "HTTPS_PROXY",
    "--proxy",
    "--ssl-revoke-best-effort",
    "Schannel",
    "Get-FileHash -Algorithm SHA256",
    "cmake.exe",
    "-E tar",
    "xJf",
    "xzf",
    "boost/version.hpp",
    "include/libtorrent/version.hpp",
    "PLEZYNG_BOOST_SOURCE_DIR",
    "PLEZYNG_LIBTORRENT_SOURCE_DIR",
):
    require(
        expected in windows_torrent_dependencies_downloader_normalized,
        f"Windows torrent dependency bootstrap must keep: {expected}",
    )
for forbidden in ("--ssl-no-revoke", "--insecure"):
    require(
        forbidden not in windows_torrent_dependencies_downloader,
        f"Windows torrent dependency bootstrap must not use {forbidden}",
    )
for label, downloader in (
    ("MPV", windows_mpv_downloader),
    ("simdutf", windows_simdutf_downloader),
    ("WinSparkle", windows_winsparkle_downloader),
    ("SDL3", windows_sdl3_downloader),
    ("torrent", windows_torrent_dependencies_downloader),
):
    require(
        "$env:PLEZYNG_ALLOW_DIRECT_DOWNLOADS -eq '1'" in downloader
        and "if (-not [string]::IsNullOrWhiteSpace($proxy))" in downloader
        and "@('--proxy', $proxy) + $curlArguments" in downloader,
        f"Windows {label} downloads must allow direct egress only when explicitly enabled and keep proxy routing otherwise",
    )
require(
    "PLEZYNG_ALLOW_DIRECT_DOWNLOADS" in windows_cmake
    and "VULKAN_RT_CURL_ARGS" in windows_cmake,
    "Windows Vulkan runtime downloads must preserve the selected proxy or explicitly enabled direct route",
)
require(
    windows_winsparkle_pin.get("version") == "0.9.2"
    and windows_winsparkle_pin.get("filename") == "WinSparkle-0.9.2.zip"
    and windows_winsparkle_pin.get("url")
    == "https://github.com/vslavik/winsparkle/releases/download/v0.9.2/WinSparkle-0.9.2.zip"
    and windows_winsparkle_pin.get("sha256")
    == "2a5facf5a22056edf7afc4d0a4bf05620b7aa7cc1619c3078b281e374cdb9996",
    "Windows WinSparkle release pin must match its verified official 0.9.2 archive",
)
require(
    windows_sdl3_pin.get("version") == "3.2.8"
    and windows_sdl3_pin.get("filename") == "SDL3-3.2.8.zip"
    and windows_sdl3_pin.get("url")
    == "https://github.com/libsdl-org/SDL/releases/download/release-3.2.8/SDL3-3.2.8.zip"
    and windows_sdl3_pin.get("sha256")
    == "7f8ff5c8246db4145301bc122601a5f8cef25ee2c326eddb3e88668849c61ddf",
    "Windows SDL3 release pin must match its verified official 3.2.8 archive",
)
require(
    windows_boost_pin.get("version") == "1.86.0"
    and windows_boost_pin.get("filename") == "boost-1.86.0-b2-nodocs.tar.xz"
    and windows_boost_pin.get("url")
    == "https://github.com/boostorg/boost/releases/download/boost-1.86.0/boost-1.86.0-b2-nodocs.tar.xz"
    and windows_boost_pin.get("sha256")
    == "a4d99d032ab74c9c5e76eddcecc4489134282245fffa7e079c5804b92b45f51d"
    and f"URL {windows_boost_pin.get('url')}" in plezy_torrent_cmake
    and f"URL_HASH SHA256={windows_boost_pin.get('sha256')}" in plezy_torrent_cmake,
    "Windows Boost release pin must match the verified plezy_torrent source archive",
)
require(
    windows_libtorrent_pin.get("version") == "2.0.11"
    and windows_libtorrent_pin.get("filename") == "libtorrent-rasterbar-2.0.11.tar.gz"
    and windows_libtorrent_pin.get("url")
    == "https://github.com/arvidn/libtorrent/releases/download/v2.0.11/libtorrent-rasterbar-2.0.11.tar.gz"
    and windows_libtorrent_pin.get("sha256")
    == "f0db58580f4f29ade6cc40fa4ba80e2c9a70c90265cd77332d3cdec37ecf1e6d"
    and f"URL {windows_libtorrent_pin.get('url')}" in plezy_torrent_cmake
    and f"URL_HASH SHA256={windows_libtorrent_pin.get('sha256')}" in plezy_torrent_cmake,
    "Windows libtorrent release pin must match the verified plezy_torrent source archive",
)
windows_download_step = named_step(
    windows, "Download and verify pinned Windows libmpv archive"
)
windows_download_step_normalized = windows_download_step.replace("\\", "/")
require(
    "windows/tool/download-pinned-mpv.ps1" in windows_download_step_normalized
    and "steps.setup_flutter_windows.outputs.windows_curl_path" in windows_download_step
    and windows.find("name: Download and verify pinned Windows libmpv archive")
    < windows.find("name: Configure repository updater trust root"),
    "Windows release builds must download and verify MPV before CMake configures",
)
windows_simdutf_download_step = named_step(
    windows, "Download and verify pinned Windows simdutf source archive"
)
windows_simdutf_download_step_normalized = windows_simdutf_download_step.replace(
    "\\", "/"
)
require(
    "windows/tool/download-pinned-simdutf.ps1" in windows_simdutf_download_step_normalized
    and windows.find("name: Download and verify pinned Windows libmpv archive")
    < windows.find("name: Download and verify pinned Windows simdutf source archive")
    < windows.find("name: Configure repository updater trust root"),
    "Windows release builds must predownload and verify simdutf before CMake configures",
)
windows_winsparkle_download_step = named_step(
    windows, "Download and verify pinned Windows WinSparkle archive"
)
windows_winsparkle_download_step_normalized = windows_winsparkle_download_step.replace(
    "\\", "/"
)
require(
    "windows/tool/download-pinned-winsparkle.ps1" in windows_winsparkle_download_step_normalized
    and windows.find("name: Download and verify pinned Windows simdutf source archive")
    < windows.find("name: Download and verify pinned Windows WinSparkle archive")
    < windows.find("name: Configure repository updater trust root"),
    "Windows release builds must predownload and verify WinSparkle before CMake configures",
)
windows_sdl3_download_step = named_step(
    windows, "Download and verify pinned Windows SDL3 archive"
)
windows_sdl3_download_step_normalized = windows_sdl3_download_step.replace("\\", "/")
require(
    "windows/tool/download-pinned-sdl3.ps1" in windows_sdl3_download_step_normalized
    and windows.find("name: Download and verify pinned Windows WinSparkle archive")
    < windows.find("name: Download and verify pinned Windows SDL3 archive")
    < windows.find("name: Configure repository updater trust root"),
    "Windows release builds must predownload and verify SDL3 before CMake configures",
)
windows_torrent_dependencies_download_step = named_step(
    windows, "Download and verify pinned Windows torrent dependencies"
)
windows_torrent_dependencies_download_step_normalized = (
    windows_torrent_dependencies_download_step.replace("\\", "/")
)
require(
    "windows/tool/download-pinned-torrent-dependencies.ps1"
    in windows_torrent_dependencies_download_step_normalized
    and windows.find("name: Download and verify pinned Windows SDL3 archive")
    < windows.find("name: Download and verify pinned Windows torrent dependencies")
    < windows.find("name: Configure repository updater trust root"),
    "Windows release builds must predownload and verify Boost/libtorrent before CMake configures",
)
require(
    "sourceforge" not in windows_cmake,
    "Windows libmpv fetch must not regress to the unpinned sourceforge download",
)
windows_native_cache = named_step(windows, "Cache Windows native dependencies")
require(
    "hashFiles('windows/CMakeLists.txt', 'mpv-build.lock.json', 'windows/tool/build-toolchain.lock.json')"
    in windows_native_cache,
    "Windows native cache identity must include the MPV and toolchain locks",
)
require(
    re.search(
        r"(?ms)^    permissions:\n      contents: read\n    strategy:", windows
    )
    is not None,
    "Windows build permissions must remain contents: read",
)
require_explicit_shells("build-windows", windows, "pwsh")

setup_flutter_git = (
    SETUP_FLUTTER_GIT.read_text(encoding="utf-8") if SETUP_FLUTTER_GIT.is_file() else ""
)
require(bool(setup_flutter_git), "missing .github/actions/setup-flutter-git/action.yml")
for expected in (
    f'$version = "{FLUTTER_VERSION}"',
    f'$expectedCommit = "{FLUTTER_COMMIT}"',
    # Fetch and verify the release tag so moved tags cannot change the SDK.
    'git -C $root fetch --depth 1 origin "refs/tags/${version}:refs/tags/${version}"',
    'git -C $root checkout --detach "refs/tags/$version"',
    "$actualCommit = git -C $root rev-parse HEAD",
    "$actualCommit -ne $expectedCommit",
    r'$versionOutput = & "$root\bin\flutter.bat" --version --machine',
    "$reportedVersion -ne $version",
):
    require(
        expected in setup_flutter_git,
        f"shared Flutter bootstrap must keep its verified pin: {expected}",
    )

setup_flutter_windows = (
    SETUP_FLUTTER_WINDOWS.read_text(encoding="utf-8") if SETUP_FLUTTER_WINDOWS.is_file() else ""
)
require(bool(setup_flutter_windows), "missing .github/actions/setup-flutter-windows/action.yml")
require(
    setup_flutter_windows.count("uses: subosito/flutter-action@") == 3
    and setup_flutter_windows.count("continue-on-error: true") == 4
    and setup_flutter_windows.count("cache: true")
    == setup_flutter_windows.count("cache-key: ${{ inputs.cache-key }}")
    and "steps.first.outcome == 'failure'" in setup_flutter_windows
    and "steps.second.outcome == 'failure'" in setup_flutter_windows
    and "steps.third.outcome == 'failure'" in setup_flutter_windows
    and "Remove-Item -LiteralPath $installRoot -Recurse -Force" in setup_flutter_windows
    and "throw 'Flutter setup failed three times" in setup_flutter_windows
    and "name: Probe pinned Flutter release connectivity" in setup_flutter_windows
    and "--ssl-revoke-best-effort" in setup_flutter_windows
    and "--retry-all-errors" in setup_flutter_windows
    and "--ssl-revoke-best-effort --head --fail" in setup_flutter_windows
    and 'manifest="$("$PLEZY_REAL_CURL" --ssl-revoke-best-effort --fail' in setup_flutter_windows
    and "name: Use the verified cached Flutter SDK after a transient setup failure" in setup_flutter_windows
    and "steps.cache_fallback.outputs.cache_valid != 'true'" in setup_flutter_windows
    and "reported.frameworkVersion -eq $env:FLUTTER_VERSION" in setup_flutter_windows
    and setup_flutter_windows.count("BASH_ENV: ${{ steps.windows_curl.outputs.bash_env }}") == 4
    and setup_flutter_windows.count(
        "PLEZY_REAL_CURL: ${{ steps.windows_curl.outputs.curl_path }}"
    ) == 5
    and 'curl() {' in setup_flutter_windows
    and "name: Verify best-effort curl wrapper for Flutter setup" in setup_flutter_windows
    and "PLEZY_REAL_CURL" in setup_flutter_windows
    and "windows_curl_path:" in setup_flutter_windows
    and "steps.windows_curl.outputs.windows_curl_path" in setup_flutter_windows
    and "--show-error" in setup_flutter_windows,
    "Windows Flutter setup must retry transient TLS failures, use only a verified pinned cache, and fail closed",
)

windows_ci = job_block(ci_text, "windows-native-test")
require(bool(windows_ci), "missing Windows native CI job")
require(
    "PLEZYNG_ALLOW_DIRECT_DOWNLOADS: ${{ inputs.execution_profile == 'hybrid' && '1' || '0' }}"
    in windows_ci,
    "Windows CI may use direct dependency egress only in the hybrid profile",
)
require(
    "PLEZYNG_ALLOW_DIRECT_DOWNLOADS: ${{ needs.validate-trusted-ref.outputs.execution_profile == 'hybrid' && '1' || '0' }}"
    in windows,
    "Windows release builds may use direct dependency egress only in the hybrid profile",
)
windows_ci_download_step = named_step(
    windows_ci, "Download and verify pinned Windows libmpv archive"
)
windows_ci_download_step_normalized = windows_ci_download_step.replace("\\", "/")
require(
    "windows/tool/download-pinned-mpv.ps1" in windows_ci_download_step_normalized
    and "steps.setup_flutter_windows.outputs.windows_curl_path" in windows_ci_download_step
    and windows_ci.find("name: Download and verify pinned Windows libmpv archive")
    < windows_ci.find("name: Prepare Flutter Windows configuration"),
    "Windows native CI must predownload the hash-locked MPV archive before CMake",
)
windows_ci_simdutf_download_step = named_step(
    windows_ci, "Download and verify pinned Windows simdutf source archive"
)
windows_ci_simdutf_download_step_normalized = windows_ci_simdutf_download_step.replace(
    "\\", "/"
)
require(
    "windows/tool/download-pinned-simdutf.ps1" in windows_ci_simdutf_download_step_normalized
    and windows_ci.find("name: Download and verify pinned Windows libmpv archive")
    < windows_ci.find("name: Download and verify pinned Windows simdutf source archive")
    < windows_ci.find("name: Prepare Flutter Windows configuration"),
    "Windows native CI must predownload and verify simdutf before CMake configures",
)
windows_ci_winsparkle_download_step = named_step(
    windows_ci, "Download and verify pinned Windows WinSparkle archive"
)
windows_ci_winsparkle_download_step_normalized = windows_ci_winsparkle_download_step.replace(
    "\\", "/"
)
require(
    "windows/tool/download-pinned-winsparkle.ps1" in windows_ci_winsparkle_download_step_normalized
    and windows_ci.find("name: Download and verify pinned Windows simdutf source archive")
    < windows_ci.find("name: Download and verify pinned Windows WinSparkle archive")
    < windows_ci.find("name: Prepare Flutter Windows configuration"),
    "Windows native CI must predownload and verify WinSparkle before CMake configures",
)
windows_ci_sdl3_download_step = named_step(
    windows_ci, "Download and verify pinned Windows SDL3 archive"
)
windows_ci_sdl3_download_step_normalized = windows_ci_sdl3_download_step.replace(
    "\\", "/"
)
require(
    "windows/tool/download-pinned-sdl3.ps1" in windows_ci_sdl3_download_step_normalized
    and windows_ci.find("name: Download and verify pinned Windows WinSparkle archive")
    < windows_ci.find("name: Download and verify pinned Windows SDL3 archive")
    < windows_ci.find("name: Prepare Flutter Windows configuration"),
    "Windows native CI must predownload and verify SDL3 before CMake configures",
)
windows_ci_torrent_dependencies_download_step = named_step(
    windows_ci, "Download and verify pinned Windows torrent dependencies"
)
windows_ci_torrent_dependencies_download_step_normalized = (
    windows_ci_torrent_dependencies_download_step.replace("\\", "/")
)
require(
    "windows/tool/download-pinned-torrent-dependencies.ps1"
    in windows_ci_torrent_dependencies_download_step_normalized
    and windows_ci.find("name: Download and verify pinned Windows SDL3 archive")
    < windows_ci.find("name: Download and verify pinned Windows torrent dependencies")
    < windows_ci.find("name: Prepare Flutter Windows configuration"),
    "Windows native CI must predownload and verify Boost/libtorrent before CMake configures",
)

linux = job("build-linux")
require(
    '"group":"ng-shared-main-jit"' in linux
    and "ng-shared-main-plezyng" in linux
    and '"linux","x64"' in linux
    and '"linux","arm64"' in linux
    and "matrix.arch == 'x64'" in linux
    and '"gha-{0}-{1}-build-linux"' in linux,
    "Linux architectures must use the private JIT route",
)
require("fail-fast: false" in linux, "Linux matrix must not cancel its other architecture")
require(
    re.search(
        r"(?ms)          - arch: x64\n"
        r"            flutter_channel: stable\n"
        r"            pkg_config_arch: x86_64-linux-gnu\n",
        linux,
    )
    is not None,
    "Linux x64 matrix configuration changed",
)
require(
    re.search(
        r"(?ms)          - arch: arm64\n"
        r"            flutter_channel: master\n"
        r"            pkg_config_arch: aarch64-linux-gnu\n",
        linux,
    )
    is not None,
    "Linux arm64 matrix configuration changed",
)
for expected in (
    "channel: ${{ matrix.flutter_channel }}",
    "flutter-version: ${{ env.FLUTTER_VERSION }}",
    "flutter pub get --enforce-lockfile --no-example",
    "lib/${{ matrix.pkg_config_arch }}/pkgconfig",
    "--split-debug-info=debug-info/linux-${{ matrix.arch }}",
    "BUILD_DIR=\"$BUNDLE_DIR\"",
    "ARCH_SUFFIX=${{ matrix.arch }}",
    "name: linux-${{ matrix.arch }}",
):
    require(expected in linux, f"Linux matrix missing: {expected}")
require(
    re.search(
        r"(?ms)^    permissions:\n"
        r"      id-token: write\n"
        r"      attestations: write\n"
        r"      contents: read\n"
        r"    strategy:",
        linux,
    )
    is not None,
    "Linux build attestation permissions changed",
)
require_explicit_shells("build-linux", linux, "bash")
flatpak_setup = named_step(linux, "Install Flatpak packaging dependencies")
require(
    "scripts/retry_flatpak.py remote-add" in flatpak_setup
    and "scripts/retry_flatpak.py install" in flatpak_setup
    and "flatpak remote-add" not in flatpak_setup
    and "flatpak install" not in flatpak_setup,
    "Flathub remote and runtime downloads must use the bounded retry helper",
)
libmpv_cache = named_step(linux, "Cache libmpv prefix")
require(
    "hashFiles('mpv-build.lock.json')" in libmpv_cache,
    "libmpv cache identity must include the mpv-build lock",
)
require(
    "python3 scripts/fetch_linux_libmpv.py" in named_step(linux, "Fetch libmpv"),
    "Linux libmpv fetch must go through scripts/fetch_linux_libmpv.py",
)


package_windows = job("package-windows")
validate_windows_signing(package_windows)
require(
    "needs: [validate-trusted-ref, build-windows]" in package_windows,
    "Windows packaging must depend on the trust check and complete Windows matrix",
)
for artifact in (
    "windows-x64-build",
    "windows-x64-portable",
    "windows-installer",
):
    require(f"name: {artifact}" in package_windows, f"Windows packaging lost {artifact}")
require(
    "windows-arm64-build" not in package_windows
    and "windows-arm64-portable" not in package_windows
    and "-Arm64BuildDir" not in package_windows,
    "the Windows installer and Chocolatey packages remain x64; ARM64 is a separate portable archive",
)

require(
    re.search(
        r"(?ms)^      mode:\n.*?        required: true\n"
        r"        type: choice\n.*?          - release\n"
        r"          - webos-validation\n",
        text,
    )
    is not None,
    "manual workflow must expose required release and webOS validation modes",
)
require(
    re.search(
        r"(?ms)^      include_webos_release:\n.*?        type: boolean\n"
        r"        default: false\n",
        text,
    )
    is not None,
    "public WebOS release inclusion must be an explicit opt-in",
)
require(
    re.search(
        r"(?ms)^      include_webos_build:\n.*?        type: boolean\n"
        r"        default: true\n",
        text,
    )
    is not None,
    "versioned builds must build the experimental WebOS candidate by default",
)
require(
    re.search(
        r"(?ms)^      include_tizen_build:\n.*?        type: boolean\n"
        r"        default: true\n",
        text,
    )
    is not None,
    "versioned builds must build the experimental Tizen candidate by default",
)
request_resolver = named_step(job("validate-trusted-ref"), "Resolve release request")
require(
    'INCLUDE_WEBOS_BUILD="$INCLUDE_WEBOS_BUILD_INPUT"' in request_resolver
    and 'INCLUDE_TIZEN_BUILD="$INCLUDE_TIZEN_BUILD_INPUT"' in request_resolver
    and '"$REF_TYPE" != "branch" || "$REF_NAME" != "main"' in request_resolver
    and 'VERSION="$BUILD_VERSION_INPUT"' in request_resolver
    and '"$VERSION" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+$' in request_resolver
    and 'RELEASE_TAG="v$VERSION"' in request_resolver,
    "manual release actions must preserve default platform choices and require an explicit version on main",
)
require(
    "Validate release tag before building" in job("validate-trusted-ref")
    and "steps.request.outputs.mode == 'release'" in job("validate-trusted-ref")
    and "RELEASE_TAG: ${{ steps.request.outputs.release_tag }}" in job("validate-trusted-ref")
    and '"$VERSION" != "$PACKAGE_VERSION"' in job("validate-trusted-ref")
    and '"$RELEASE_TAG" != "v$PACKAGE_VERSION"' in job("validate-trusted-ref"),
    "release mode must validate the requested version and pushed v-tag before building",
)
build_webos = job("build-webos")
require(
    "needs.validate-trusted-ref.outputs.mode == 'webos-validation'" in build_webos
    and "needs.validate-trusted-ref.outputs.mode == 'release' && needs.validate-trusted-ref.outputs.include_webos_build == 'true'" in build_webos
    and "bash tools/webos/build_release_candidate.sh" in build_webos,
    "versioned builds must build webOS independently from public-release inclusion",
)
require(
    "python3 -m unittest discover -s tools/webos/tests -v"
    in named_step(build_webos, "Test WebOS packaging and release gates"),
    "private webOS builds must run the headless packaging and release-gate tests",
)
require(
    "python3 tools/webos/check_release_eligibility.py" in named_step(
        job("validate-trusted-ref"), "Require approval for the exact webOS release artifact"
    )
    and "--preflight" in named_step(
        job("validate-trusted-ref"), "Require approval for the exact webOS release artifact"
    ),
    "webOS public-release approval must fail before platform builds start",
)
candidate_builder = (
    WEBOS_CANDIDATE_BUILDER.read_text(encoding="utf-8")
    if WEBOS_CANDIDATE_BUILDER.is_file()
    else ""
)
ipk_builder = (
    WEBOS_IPK_BUILDER.read_text(encoding="utf-8")
    if WEBOS_IPK_BUILDER.is_file()
    else ""
)
release_gate = (
    WEBOS_RELEASE_GATE.read_text(encoding="utf-8")
    if WEBOS_RELEASE_GATE.is_file()
    else ""
)
require(
    'read_lock releaseEligibility validatedSourceCommit' in candidate_builder
    and "export PLEZY_WEBOS_GIT_COMMIT" in candidate_builder
    and '"${PLEZY_WEBOS_GIT_COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"' in ipk_builder,
    "approved WebOS releases must embed the exact C6-qualified app-source commit",
)
require(
    '"validatedArtifactSha256"' in release_gate
    and 'actual_hash != expected_hash' in release_gate
    and "REQUIRED_GATES" in release_gate,
    "the WebOS public-release guard must check all gates and the exact IPK hash",
)
require(
    "--artifact" in named_step(build_webos, "Verify the exact approved WebOS IPK")
    and "--version \"$RELEASE_TAG\"" in named_step(
        build_webos, "Verify the exact approved WebOS IPK"
    ),
    "the public release must verify the exact qualified IPK hash, source, and version",
)
require(
    "if: ${{ needs.validate-trusted-ref.outputs.mode == 'release' && needs.validate-trusted-ref.outputs.include_webos_release == 'true' }}"
    in named_step(build_webos, "Upload approved WebOS IPK for public release assembly"),
    "the WebOS IPK must not be uploaded as a public workflow artifact before release approval",
)
require(
    "Upload experimental WebOS candidate for this build" not in build_webos,
    "unapproved WebOS candidates must stay inside private runner storage",
)
require(
    "retain_private_candidate.py --preflight" in named_step(
        build_webos, "Verify private WebOS output storage"
    )
    and "retain_private_candidate.py" in named_step(
        build_webos, "Retain verified WebOS candidate for private device testing"
    )
    and build_webos.index("Verify private WebOS output storage")
    < build_webos.index("Build and verify the WebOS ARM package")
    < build_webos.index("Retain verified WebOS candidate for private device testing"),
    "webOS candidates must survive guest cleanup in preflight-checked private storage",
)
require(
    "Public webOS inclusion requires action=release." in job("validate-trusted-ref")
    and "needs.validate-trusted-ref.outputs.include_webos_release == 'true'" in named_step(
        build_webos, "Upload approved WebOS IPK for public release assembly"
    ),
    "WebOS IPKs must only enter public artifacts for an approved draft-release action",
)
validation_evidence = named_step(
    build_webos, "Upload WebOS validation evidence without vendor runtime binaries"
)
require(
    "webos-validation-evidence" in validation_evidence
    and "*.ipk" not in validation_evidence,
    "webOS validation artifacts must contain metadata, not vendor runtime binaries",
)
tizen_job = job("build-tizen")
require(
    "uses: ./.github/workflows/tizen.yml" in tizen_job
    and "outputs.include_tizen_build == 'true'" in tizen_job
    and "execution_profile: ${{ needs.validate-trusted-ref.outputs.execution_profile }}" in tizen_job
    and "architecture: arm" in tizen_job
    and "tester_build: true" in tizen_job
    and "security_profile: ''" in tizen_job
    and "include_seller_office_handoff: false" in tizen_job,
    "versioned builds must call the ARM Tizen tester workflow without store handoff",
)
tizen_workflow = (
    TIZEN_WORKFLOW.read_text(encoding="utf-8") if TIZEN_WORKFLOW.is_file() else ""
)
require(
    "  workflow_call:" in tizen_workflow
    and "tester_build:" in tizen_workflow
    and "default: private" in tizen_workflow
    and tizen_workflow.count("inputs.execution_profile == 'hybrid' && 'ubuntu-24.04'") == 2
    and "PLEZYNG_ALLOW_DIRECT_DOWNLOADS: ${{ inputs.execution_profile == 'hybrid' && '1' || '0' }}" in tizen_workflow
    and "Ignore private Tizen toolchain paths on hosted runners" in tizen_workflow
    and "python3 scripts/tizen/prepare_signing_profile.py" in tizen_workflow
    and "python3 scripts/tizen/package.py build" in tizen_workflow
    and "startsWith(github.ref, 'refs/tags/v')" in tizen_workflow
    and "name: plezyng-tizen-${{ inputs.architecture }}-experimental" in tizen_workflow,
    "Tizen reusable workflow must build signed packages from main and version tags",
)
tizen_flutter_version = named_step(
    tizen_workflow, "Restore the pinned Flutter release tag for SDK version detection"
)
require(
    '"flutter_version_tag"' in tizen_flutter_version
    and '"flutter_revision"' in tizen_flutter_version
    and 'fetch --depth=1 origin "refs/tags/$flutter_tag:refs/tags/$flutter_tag"' in tizen_flutter_version
    and 'describe --tags --exact-match HEAD' in tizen_flutter_version,
    "the pinned Tizen Flutter checkout must restore its exact SDK version tag",
)
require(
    re.search(
        r"(?ms)^      action:\n.*?^        required: true\n        type: choice\n"
        r".*?^        options:\n          - build\n          - release$",
        text,
    ) is not None,
    "platform workflow must require an explicit build or release action",
)
require(
    re.search(
        r"(?ms)^      runner_pool:\n.*?^        required: true\n        type: choice\n"
        r".*?^        options:\n          - private$",
        text,
    ) is not None,
    "platform workflow must require its supported private runner pool",
)
require(
    re.search(
        r"(?ms)^      execution_profile:\n.*?^        required: true\n        type: choice\n"
        r".*?^        options:\n          - private\n          - hybrid\n        default: private$",
        text,
    ) is not None
    and "inputs.execution_profile == 'hybrid'" in job("validate-trusted-ref")
    and "\"$VERSION\" != \"3.0.0\"" in named_step(job("validate-trusted-ref"), "Resolve release request"),
    "the hybrid execution profile must be default-off and restricted to trusted-main PlezyNG 3.0.0 builds",
)
require(
    "inputs.build_android" not in text
    and "inputs.build_ios" not in text
    and "inputs.build_windows" not in text
    and "inputs.build_linux" not in text,
    "full-platform builds must not expose per-platform skip switches",
)
workflow_events = re.search(r"(?ms)^on:\n(?P<body>.*?)(?=^env:\n)", text)
event_body = workflow_events.group("body") if workflow_events else ""
require(
    "  workflow_dispatch:" in event_body
    and re.search(r"(?m)^  (?:push|pull_request|workflow_call):", event_body) is None,
    "platform builds must be manually dispatched with an explicit action and pool",
)
require(
    "if: ${{ github.event_name == 'workflow_dispatch' && inputs.build_linux_packages && (inputs.execution_profile != 'hybrid' || github.ref == 'refs/heads/main') }}"
    in job_block(ci_text, "linux-packages"),
    "the optional Linux package smoke build must not run on pushes",
)

linux_release = job("build-linux")
linux_release_sherpa = named_step(
    linux_release, "Install and verify locked Sherpa ONNX libraries"
)
require(
    'python3 linux/packaging/install-sherpa-onnx-runtime.py "$BUNDLE_DIR" --arch "${{ matrix.arch }}"'
    in linux_release_sherpa
    and linux_release.find("      - name: Resolve bundle directory")
    < linux_release.find("      - name: Install and verify locked Sherpa ONNX libraries")
    < linux_release.find("      - name: Bundle shared libraries"),
    "Linux release artifacts must use the locked Sherpa ONNX library pair before bundling",
)

linux_smoke = job_block(ci_text, "linux-packages")
linux_smoke_sherpa = named_step(
    linux_smoke, "Install and verify locked Sherpa ONNX libraries"
)
require(
    "python3 linux/packaging/install-sherpa-onnx-runtime.py build/linux/x64/release/bundle --arch x64"
    in linux_smoke_sherpa
    and linux_smoke.find("      - name: Build the release bundle")
    < linux_smoke.find("      - name: Install and verify locked Sherpa ONNX libraries")
    < linux_smoke.find("      - name: Bundle shared libraries"),
    "Linux package smoke artifacts must use the locked Sherpa ONNX library pair before bundling",
)

apple_native = job_block(ci_text, "apple-native-test")
apple_prepare_scratch = named_step(
    apple_native, "Prepare local Xcode and SwiftPM scratch"
)
require(
    'bash scripts/prepare_apple_jit_scratch.sh "$APPLE_SCRATCH_JOB" 20 local-xcode'
    in apple_prepare_scratch
    and "result_bundle=\"$APPLE_RESULT_BUNDLE\"" in apple_native
    and apple_native.count('-derivedDataPath "$APPLE_DERIVED_DATA_PATH"') == 3,
    "Apple CI must keep SwiftPM sources, DerivedData, and results on local APFS",
)
apple_scratch_script = (ROOT / "scripts/prepare_apple_jit_scratch.sh").read_text()
apple_scratch_helper_scripts = (
    apple_scratch_script,
    (ROOT / "scripts/cleanup_apple_jit_scratch.sh").read_text(),
    (ROOT / "scripts/clean_appledouble_sidecars.sh").read_text(),
)
require(
    all('readonly NFS_MOUNT="/Volumes/p"' in script for script in apple_scratch_helper_scripts)
    and 'readonly NFS_PRIMARY_MOUNT="/Volumes/plezyng-native-build-kspld0"' in apple_scratch_script
    and 'if [[ "$short_source" != "$primary_source" ]]' in apple_scratch_script
    and all('readonly NFS_MOUNT="/Volumes/plezyng-native-build-kspld0"' not in script for script in apple_scratch_helper_scripts)
    and 'expected_cloned_dir="/Volumes/p/runs/' in (ROOT / "scripts/refresh_apple_spm.sh").read_text(),
    "Apple source workspaces must use the short NFS alias so native-asset install names fit Mach-O headers",
)
require(
    "printf 'APPLE_SOURCE_PACKAGES_DIR=%s/%s/SourcePackages\\n' \"$local_build_dir\" \"$scratch_job\"" in apple_scratch_script
    and "/build/${platform}/SourcePackages\"" in (ROOT / "scripts/refresh_apple_spm.sh").read_text(),
    "Apple SwiftPM checkouts must match Flutter's local build/<platform>/SourcePackages path",
)
macos_apple_build = named_step(
    apple_native, "Build macOS application and XCTest bundle"
)
require(
    '-clonedSourcePackagesDirPath "$APPLE_SOURCE_PACKAGES_DIR"' in macos_apple_build,
    "macOS Apple CI must reuse the run-scoped SwiftPM checkout during the build",
)
for apple_job_name, scratch_job in (
    ("build-ios", "ios"),
    ("build-tvos", "tvos"),
    ("build-macos", "macos"),
):
    apple_release_job = job(apple_job_name)
    require(
        f"scripts/prepare_apple_jit_scratch.sh {scratch_job} 40 local-xcode" in apple_release_job
        and f"scripts/cleanup_apple_jit_scratch.sh {scratch_job}" in apple_release_job,
        f"{apple_job_name} must allocate local Xcode state and clean task-scoped scratch",
    )
for apple_job_name, workspace_label in (
    ("build-ios", "iOS"),
    ("build-macos", "macOS"),
):
    apple_release_job = job(apple_job_name)
    require(
        'ln -s "$APPLE_LOCAL_BUILD_DIR" "$short_root/build"' in apple_release_job
        and '"$(cd "$short_root/build" && pwd -P)" == "$APPLE_LOCAL_BUILD_DIR"' in apple_release_job,
        f"{workspace_label} release Flutter/Xcode build output must resolve to local APFS",
    )
    stage_step_name = (
        "Prepare NFS source workspace and local APFS iOS build output"
        if apple_job_name == "build-ios"
        else "Prepare NFS source workspace and local APFS macOS build output"
    )
    stage_step = named_step(apple_release_job, stage_step_name)
    xcode_step_name = (
        "Build iOS (no codesign)" if apple_job_name == "build-ios" else "Build macOS"
    )
    if apple_job_name == "build-macos":
        macos_xcode_step = named_step(apple_release_job, xcode_step_name)
        require(
            "flutter build macos --release" in macos_xcode_step
            and "--no-codesign" not in macos_xcode_step
            and 'FLUTTER_XCODE_CODE_SIGNING_ALLOWED: "NO"' in macos_xcode_step
            and 'FLUTTER_XCODE_CODE_SIGNING_REQUIRED: "NO"' in macos_xcode_step
            and 'FLUTTER_XCODE_CODE_SIGNING_IDENTITY: ""' in macos_xcode_step,
            "macOS release build must use Flutter's Xcode build-setting overrides to disable signing before optional Developer ID signing",
        )
    cleanup_step_name = (
        "Remove AppleDouble sidecars before iOS Xcode build"
        if apple_job_name == "build-ios"
        else "Remove AppleDouble sidecars before macOS Xcode build"
    )
    cleanup_step = named_step(apple_release_job, cleanup_step_name)
    require(
        'bash "$short_root/scripts/clean_appledouble_sidecars.sh" "$short_root"' in stage_step
        and "scripts/clean_appledouble_sidecars.sh" in cleanup_step
        and apple_release_job.find(f"      - name: {stage_step_name}")
        < apple_release_job.find(f"      - name: {cleanup_step_name}")
        < apple_release_job.find(f"      - name: {xcode_step_name}"),
        f"{workspace_label} NFS source must remove AppleDouble sidecars before Xcode builds",
    )
    clean_appledouble_script = (ROOT / "scripts/clean_appledouble_sidecars.sh").read_text()
    require(
        '/usr/bin/find "$task_root" -type f -name \'._*\' -delete' in clean_appledouble_script
        and "dot_clean" not in clean_appledouble_script
        and "run_id=$GITHUB_RUN_ID" in clean_appledouble_script
        and "scratch_mode=local-xcode" in clean_appledouble_script
        and "AppleDouble sidecars remain after cleanup" in clean_appledouble_script,
        "AppleDouble cleanup must delete sidecars only inside the owned NFS task root and verify the result",
    )
    if apple_job_name == "build-ios":
        signed_build = named_step(apple_release_job, "Build signed iOS App Store IPA")
        require(
            'bash "$GITHUB_WORKSPACE/scripts/clean_appledouble_sidecars.sh" "$PLEZYNG_APPLE_WORKSPACE"'
            in signed_build,
            "Signed iOS archive builds must repeat the AppleDouble check after the unsigned build",
        )
for apple_job_name in ("build-ios", "build-tvos"):
    apple_release_job = job(apple_job_name)
    require(
        f'archive_path="$APPLE_LOCAL_BUILD_DIR/{"ios" if apple_job_name == "build-ios" else "tvos"}-store.xcarchive"' in apple_release_job
        and f'derived_data_path="$APPLE_LOCAL_BUILD_DIR/{"ios" if apple_job_name == "build-ios" else "tvos"}-store-derived-data"' in apple_release_job,
        f"{apple_job_name} signing archives and DerivedData must stay on local APFS",
    )
require(
    "scripts/refresh_apple_spm.sh ios" in apple_native
    and "scripts/refresh_apple_spm.sh macos" in apple_native
    and "xcodebuild -resolvePackageDependencies -workspace" in apple_native
    and "-disableAutomaticPackageResolution" in apple_native,
    "Apple CI must refresh pinned SwiftPM mirrors and resolve exact locked packages before Xcode tests",
)

unit_tests = job_block(ci_text, "test")
chrome_setup = named_step(unit_tests, "Configure Flutter Chrome executable")
chrome_test = named_step(unit_tests, "Run wakelock_plus Chrome tests")
require(
    "working-directory: tools/reader-tests" in chrome_setup
    and "chromium.executablePath()" in chrome_setup
    and "CHROME_EXECUTABLE=%s" in chrome_setup
    and "flutter test --platform chrome" in chrome_test,
    "Flutter Chrome tests must use the Chromium installed for reader browser checks",
)

windows_native = job_block(ci_text, "windows-native-test")
native_format = job_block(ci_text, "native-format")
require(
    "inputs.execution_profile == 'hybrid' && 'macos-26-intel' || fromJSON(format(" in native_format
    and '"group":"private-apple-builds"' in native_format
    and "scripts/format_native.sh --check" in native_format,
    "hybrid native formatting must use standard macOS while private mode preserves the Apple JIT route",
)
validate_windows_jni_jdk(windows_native, "Windows native CI")
windows_ci_flutter_cache_key = re.search(
    r'(?m)^\s*cache-key:\s*["\']?([^"\'\s]+)["\']?\s*$',
    windows_native,
)
require(
    "uses: ./.github/actions/setup-flutter-windows" in windows_native
    and windows_ci_flutter_cache_key is not None
    and windows_ci_flutter_cache_key.group(1)
    == "flutter-:os:-:channel:-:version:-:arch:-:hash:"
    and "uses: ./.github/actions/setup-flutter-git" in windows_native,
    "Windows native CI must keep bounded x64 setup and the pinned ARM64 Flutter bootstrap",
)
require(
    '"arch":"arm64","flutter_setup":"git"' in windows_native
    and "matrix: ${{ fromJSON(inputs.execution_profile == 'hybrid'" in windows_native
    and '"include":[{"arch":"x64"' in windows_native
    and "'windows-11-vs2026-arm'" in windows_native,
    "native Windows ARM64 CI must run on the public ARM64 host in the 3.0.0 hybrid profile",
)
require(
    'CMAKE_GENERATOR=Visual Studio 18 2026' in named_step(
        windows_native, "Select Visual Studio 2026 generator for hybrid ARM64"
    ),
    "hybrid Windows ARM64 CI must use the Visual Studio 2026 generator",
)
require(
    "CMAKE_GENERATOR_TOOLSET" not in windows_native
    and "CC=clang-cl" not in windows_native
    and "CXX=clang-cl" not in windows_native,
    "Flutter Windows ARM64 CI plugins must use the default MSVC toolset",
)
whisper_arm64_ci = named_step(windows_native, "Build the pinned Whisper ARM64 backend with Clang")
require(
    "scripts/prepare_windows_arm64_whisper.py" in whisper_arm64_ci
    and windows_native.find("name: Install locked Dart dependencies")
    < windows_native.find("name: Build the pinned Whisper ARM64 backend with Clang"),
    "the hash-locked Whisper ARM64 backend must be built before Flutter configures Windows CI",
)


run_name = re.search(r"(?m)^run-name: (.*)$", text)
run_name_expression = run_name.group(1) if run_name else ""
require(
    all(field in run_name_expression for field in ("inputs.action", "inputs.runner_pool", "inputs.build_version"))
    and "format('action:{0}:pool:{1}:tag:v{2}'" in run_name_expression
    and "inputs.action == 'build' && inputs.mode == 'release' && inputs.build_version != ''" in run_name_expression
    and "format('action:{0}:pool:{1}:mode:{2}:version:{3}'" in run_name_expression
    and "format('action:{0}:pool:{1}'" in run_name_expression
    and "inputs.action == 'release'" in run_name_expression,
    "build and release run names must match the private JIT broker title schema",
)

for action_pool_job in (
    "validate-trusted-ref",
    "build-android",
    "build-webos",
    "build-tizen",
    "build-ios",
    "build-tvos",
    "build-macos",
    "build-windows",
    "package-windows",
    "build-linux",
):
    block = job(action_pool_job)
    if action_pool_job == "validate-trusted-ref":
        gated = (
            "inputs.runner_pool == 'private'" in block
            and "inputs.action == 'build'" in block
            and "inputs.action == 'release'" in block
        )
    else:
        gated = (
            "needs.validate-trusted-ref.outputs.action == 'build'" in block
            and "needs.validate-trusted-ref.outputs.runner_pool == 'private'" in block
        )
    require(gated, f"{action_pool_job} must be gated by the requested action and private pool")

release = job("create-release")
require(
    "needs: [validate-trusted-ref, build-android, build-webos, build-tizen, build-ios, build-tvos, build-macos, build-windows, package-windows, build-linux]"
    in release,
    "release dependencies must include the trust gate, all platform builds, and Windows packaging",
)
for artifact in (
    "android-apk",
    "plezyng-tizen-arm-experimental",
    "ios-ipa",
    "tvos-ipa",
    "macos-dmg",
    "windows-x64-portable",
    "windows-installer",
    "windows-chocolatey",
    "linux-x64",
    "linux-arm64",
):
    require(f"name: {artifact}" in release, f"release download lost {artifact}")
require(
    "windows-arm64-build" in release
    and "plezy-windows-arm64-portable.zip" in release
    and "EXECUTION_PROFILE" in named_step(release, "Collect release files"),
    "hybrid release assembly must verify and attach a native Windows ARM64 portable archive",
)
winget_generator = (ROOT / "scripts/generate_winget_manifests.py").read_text(
    encoding="utf-8"
)
winget_step = named_step(release, "Generate WinGet manifest bundle")
require(
    re.search(
        r'architectures\s*=\s*\["x64",\s*"arm64"\]\s*if args\.include_arm64\s*else\s*\["x64"\]',
        winget_generator,
    )
    is not None
    and "--include-arm64" not in winget_step,
    "3.0.0 WinGet manifests must match the x64-only installer",
)

tizen_download = named_step(release, "Download Tizen ARM tester handoff")
require(
    "name: plezyng-tizen-arm-experimental" in tizen_download
    and "path: artifacts/tizen" in tizen_download,
    "the release must consume the Tizen ARM tester artifact from this exact workflow run",
)
tizen_handoff = named_step(release, "Verify and archive Tizen tester handoff")
require(
    "sha256sum --check" in tizen_handoff
    and "EXPECTED_SOURCE_COMMIT" in tizen_handoff
    and "source_commit" in tizen_handoff
    and "PlezyNG-tizen-arm-tester-handoff.zip" in tizen_handoff
    and "development-only-requires-tv-resigning" in tizen_handoff
    and "tv_install_verified" in tizen_handoff,
    "the release must verify Tizen package checksum/source and label the tester signing gate",
)
require(
    "artifacts/tizen/PlezyNG-tizen-arm-tester-handoff.zip" in named_step(
        release, "Collect release files"
    ),
    "the verified ARM Tizen tester handoff must be attached to the versioned release",
)

webos_download = named_step(release, "Download WebOS artifact")
require(
    "if: ${{ needs.validate-trusted-ref.outputs.include_webos_release == 'true' }}" in webos_download
    and "name: webos-ipk" in webos_download,
    "the WebOS release artifact must be downloaded only after explicit opt-in",
)
webos_checksum_rename = named_step(
    release, "Give the WebOS checksum manifest a unique release filename"
)
require(
    "include_webos_release == 'true'" in webos_checksum_rename
    and "mv artifacts/webos/SHA256SUMS.txt artifacts/webos/webos-SHA256SUMS.txt"
    in webos_checksum_rename
    and release.find(webos_checksum_rename) < release.find("name: Generate release SHA-256 checksums"),
    "the WebOS checksum manifest must be uniquely named before release checksums are generated",
)
collect_release_files = named_step(release, "Collect release files")
require(
    'if [[ "$INCLUDE_WEBOS_RELEASE" == "true" ]]' in collect_release_files
    and "artifacts/webos/*.ipk" in collect_release_files
    and "artifacts/webos/webos-SHA256SUMS.txt" in collect_release_files,
    "the WebOS IPK must enter the public release asset list only after approval",
)
checksum_source = RELEASE_CHECKSUMS.read_text(encoding="utf-8")
require(
    '".ipk"' in checksum_source and '".tpk"' in checksum_source,
    "TV packages must be included in the release-wide checksum manifest",
)

release_if = re.search(r"(?m)^    if: (.+)$", release)
require(release_if is not None, "release job must have an explicit condition")
release_condition = release_if.group(1) if release_if else ""
require(
    "needs.validate-trusted-ref.outputs.mode == 'release'" in release_condition
    and "needs.validate-trusted-ref.outputs.action == 'release'" in release_condition
    and "needs.validate-trusted-ref.outputs.runner_pool == 'private'" in release_condition
    and all(f"needs.{name}.result == 'success'" in release_condition for name in (
        "build-android", "build-ios", "build-tvos", "build-macos", "build-windows", "package-windows", "build-linux"))
    and "needs.validate-trusted-ref.result == 'success'" in release_condition
    and "needs.build-webos.result == 'success'" in release_condition
    and "needs.build-webos.result == 'skipped'" in release_condition
    and "needs.build-tizen.result == 'success'" in release_condition
    and "needs.build-tizen.result == 'skipped'" in release_condition
    and "contains(needs.*.result, 'failure')" in release_condition
    and "contains(needs.*.result, 'cancelled')" in release_condition,
    "draft release creation must require a successful complete build",
)


require("draft: true" in release, "build output must remain a draft release")
require("body_path: release-notes.md" in release, "draft notes must come from the changelog renderer")
require(
    "tag_name: ${{ needs.validate-trusted-ref.outputs.release_tag }}" in release,
    "release builds must bind the validated release tag",
)
require(
    "target_commitish: ${{ github.sha }}" in release,
    "release tags must target the exact build commit",
)
require(
    "python3 scripts/generate_release_notes.py \"$RELEASE_TAG\" > release-notes.md"
    in release,
    "draft release notes must be rendered from CHANGELOG.md",
)

trusted_ref = job("validate-trusted-ref")
require(
    "permissions:\n      contents: read" in trusted_ref,
    "release request validation must have read-only repository access",
)
require(
    '"$GITHUB_REF" != "refs/heads/main"' in trusted_ref,
    "trusted-ref validation must reject non-main refs",
)
require(
    "Validate release tag before building" in trusted_ref
    and '"$VERSION" != "$PACKAGE_VERSION"' in trusted_ref
    and '"$ACTION" == "release" && "$RELEASE_TAG" != "v$PACKAGE_VERSION"' in trusted_ref
    and '"$RUNNER_POOL" != "private"' in trusted_ref
    and '"$ACTION" != "build" && "$ACTION" != "release"' in trusted_ref
    and '"$REF_TYPE" != "branch" || "$REF_NAME" != "main"' in request_resolver
    and 'git fetch --no-tags origin "refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"' in trusted_ref
    and 'git rev-parse "refs/tags/$RELEASE_TAG^{commit}"' in trusted_ref
    and '"$release_commit" != "$GITHUB_SHA"' in trusted_ref,
    "release tags must match pubspec and the exact trusted main commit before builds",
)
for protected_job in (
    "build-android",
    "build-ios",
    "build-tvos",
    "build-macos",
    "build-windows",
    "build-linux",
):
    require(
        "needs: validate-trusted-ref" in job(protected_job),
        f"{protected_job} must depend on trusted-ref validation",
    )

android_job = job("build-android")
android_memory_diagnostics = named_step(android_job, "Capture Android JIT memory diagnostics")
android_ffmpeg_prepare = named_step(android_job, "Prepare verified Android FFmpeg source archive")
android_gradle_properties = (ROOT / "android/gradle.properties").read_text(encoding="utf-8")
android_ci = job_block(ci_text, "android-test")
android_ci_ffmpeg_prepare = named_step(android_ci, "Prepare verified Android FFmpeg source archive")
android_ffmpeg_gradle = (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
android_ffmpeg_helper = (ROOT / "scripts/prepare_android_ffmpeg_source.py").read_text(encoding="utf-8")
require(
    "prepare_android_ffmpeg_source.py" in android_ci_ffmpeg_prepare
    and "actions/cache/restore@" in android_ci
    and "actions/cache/save@" in android_ci
    and "TRUSTED_BUILD_CACHE_VERSION" in android_ci
    and "PLEZYNG_FFMPEG_SOURCE_ARCHIVE" in android_ffmpeg_gradle,
    "Android CI must prefetch, verify, and cache pinned FFmpeg headers through the private JIT proxy",
)
require(
    "prepare_android_ffmpeg_source.py" in android_ffmpeg_prepare
    and "actions/cache/restore@" in android_job
    and "actions/cache/save@" in android_job
    and "TRUSTED_BUILD_CACHE_VERSION" in android_job
    and "PLEZYNG_FFMPEG_SOURCE_ARCHIVE" in android_ffmpeg_gradle,
    "Android release builds must prefetch, verify, and cache pinned FFmpeg headers before Gradle",
)
require(
    "proxy_parts(dict(os.environ))" in android_ffmpeg_helper
    and "ProxyHandler({})" in android_ffmpeg_helper
    and "--direct-egress" in android_ci_ffmpeg_prepare
    and "--direct-egress" in android_ffmpeg_prepare
    and "sha256_file" in android_ffmpeg_helper
    and "FFmpeg source SHA-256 mismatch" in android_ffmpeg_helper,
    "Android FFmpeg prefetch must use the private proxy and verify its pinned SHA-256",
)
require(
    "-Xmx3G" in android_gradle_properties
    and "kotlin.compiler.execution.strategy=in-process" in android_gradle_properties
    and "org.gradle.workers.max=1" in android_gradle_properties
    and "android.nonFinalResIds=false" in android_gradle_properties
    and "android.r8.optimizedResourceShrinking=false" in android_gradle_properties,
    "Android release Gradle must bound memory, serialize workers, and preserve the final IDs required by Moonlight",
)
require(
    'CMAKE_BUILD_PARALLEL_LEVEL: "2"' in android_job
    and "if: always()" in android_memory_diagnostics
    and all(
        f"/sys/fs/cgroup/{name}" in android_memory_diagnostics
        for name in ("memory.current", "memory.max", "memory.peak", "memory.events")
    ),
    "Android release builds must limit native parallelism and log JIT memory state even on failure",
)

require(
    text.count(FLUTTER_VERSION) == 1 and f'FLUTTER_VERSION: "{FLUTTER_VERSION}"' in text,
    "the Flutter SDK version must be written once, as the workflow FLUTTER_VERSION env",
)
require(
    "TRUSTED_BUILD_CACHE_VERSION: trusted-build-v1" in text,
    "build caches must use a dedicated trusted namespace",
)
require("restore-keys:" not in text, "privileged build caches must not use prefix fallback")
cache_keys = re.findall(r"(?m)^          key: (.+)$", text)
require(bool(cache_keys), "build workflow must define cache keys")
for cache_key in cache_keys:
    require(
        "TRUSTED_BUILD_CACHE_VERSION" in cache_key,
        f"cache key is outside the trusted build namespace: {cache_key}",
    )
windows_flutter_wrappers = text.count("uses: ./.github/actions/setup-flutter-windows")
require(
    windows_flutter_wrappers == 2
    and text.count("cache-key:") == text.count("cache: true") + windows_flutter_wrappers,
    "every Flutter SDK cache must define its trusted cache key",
)

# Action-pin checks run elsewhere; this guard adds the checkout credential
# invariant for the workflow-dispatch-only build.
remote_actions = [
    reference.rpartition("@")[0]
    for _, reference in iter_uses_references(text)
    if not reference.startswith("./")
]
require(bool(remote_actions), "build workflow must use pinned actions")
require(
    text.count("persist-credentials: false") == remote_actions.count("actions/checkout"),
    "every build checkout must discard GitHub credentials",
)

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)

print("build workflow architecture matrix checks passed")
