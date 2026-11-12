#!/usr/bin/env python3
"""Build pinned Windows ARM64 Whisper with Clang, leaving Flutter plugins on MSVC."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urljoin, urlsplit


ROOT = Path(__file__).resolve().parents[1]
WHISPER_PATCH_MARKER = "# PLEAZYNG_WINDOWS_ARM64_WHISPER_PATCH_V1"
WHISPER_ADD_SUBDIRECTORY = '''add_subdirectory(
  "${FLUTTER_WHISPER_CPP_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}/whisper_cpp"
  EXCLUDE_FROM_ALL)'''
# The plugin sets MSVC warning flags on whisper.cpp targets. The ARM64 route
# replaces those targets with prebuilt Clang IMPORTED libraries, which cannot
# accept PRIVATE compile options and do not need MSVC compile flags.
WHISPER_MSVC_WARNING_BLOCK = '''if(MSVC)
  foreach(_FW_THIRD_PARTY_TARGET
      whisper ggml ggml-base ggml-cpu ggml-cuda ggml-vulkan)
    if(TARGET ${_FW_THIRD_PARTY_TARGET})
      target_compile_options(${_FW_THIRD_PARTY_TARGET} PRIVATE
        /W0 /wd4244 /wd4267)
    endif()
  endforeach()
endif()'''
WHISPER_MSVC_WARNING_BLOCK_PATCHED = '''if(MSVC)
  foreach(_FW_THIRD_PARTY_TARGET
      whisper ggml ggml-base ggml-cpu ggml-cuda ggml-vulkan)
    if(TARGET ${_FW_THIRD_PARTY_TARGET})
      get_target_property(_FW_TARGET_IS_IMPORTED ${_FW_THIRD_PARTY_TARGET} IMPORTED)
      if(NOT _FW_TARGET_IS_IMPORTED)
        target_compile_options(${_FW_THIRD_PARTY_TARGET} PRIVATE
          /W0 /wd4244 /wd4267)
      endif()
    endif()
  endforeach()
endif()'''
WHISPER_IMPORTED_TARGETS_BODY = '''set(FLUTTER_WHISPER_PREBUILT_ROOT "$ENV{FLUTTER_WHISPER_PREBUILT_ROOT}")
if(FLUTTER_WHISPER_PREBUILT_ROOT STREQUAL "")
  add_subdirectory(
    "${FLUTTER_WHISPER_CPP_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/whisper_cpp"
    EXCLUDE_FROM_ALL)
else()
  file(TO_CMAKE_PATH "${FLUTTER_WHISPER_PREBUILT_ROOT}" FLUTTER_WHISPER_PREBUILT_ROOT)
  foreach(_target IN ITEMS whisper ggml ggml-base ggml-cpu)
    set(_dll "${FLUTTER_WHISPER_PREBUILT_ROOT}/${_target}.dll")
    set(_implib "${FLUTTER_WHISPER_PREBUILT_ROOT}/${_target}.lib")
    if(NOT EXISTS "${_dll}" OR NOT EXISTS "${_implib}")
      message(FATAL_ERROR "Missing prebuilt Windows ARM64 Whisper dependency: ${_target}")
    endif()
    add_library(${_target} SHARED IMPORTED GLOBAL)
    set_target_properties(${_target} PROPERTIES
      IMPORTED_CONFIGURATIONS RELEASE
      IMPORTED_LOCATION "${_dll}"
      IMPORTED_LOCATION_RELEASE "${_dll}"
      IMPORTED_IMPLIB "${_implib}"
      IMPORTED_IMPLIB_RELEASE "${_implib}")
  endforeach()
  # Match the PUBLIC target graph from the pinned whisper.cpp CMake files.
  # The plugin calls GGML APIs directly and therefore needs all import libs.
  set_target_properties(whisper PROPERTIES
    INTERFACE_LINK_LIBRARIES ggml)
  set_target_properties(ggml PROPERTIES
    INTERFACE_LINK_LIBRARIES "ggml-base;ggml-cpu")
endif()'''
WHISPER_IMPORTED_TARGETS = f"{WHISPER_PATCH_MARKER}\n{WHISPER_IMPORTED_TARGETS_BODY}"


def package_root(package_config: Path) -> Path:
    config = json.loads(package_config.read_text(encoding="utf-8"))
    packages = [entry for entry in config.get("packages", []) if entry.get("name") == "flutter_whisper_ggml"]
    if len(packages) != 1:
        raise ValueError("Flutter package configuration must contain exactly one flutter_whisper_ggml entry")

    root_uri = urljoin(package_config.resolve().as_uri(), packages[0].get("rootUri", ""))
    parsed = urlsplit(root_uri)
    if parsed.scheme != "file" or parsed.query or parsed.fragment:
        raise ValueError("flutter_whisper_ggml rootUri must be a local file URI")
    path = unquote(parsed.path)
    if parsed.netloc and parsed.netloc != "localhost":
        path = f"//{parsed.netloc}{path}"
    if os.name == "nt":
        path = path.replace("/", "\\")
        if re.match(r"^\\[A-Za-z]:\\", path):
            path = path[1:]
    return Path(path).resolve()


def patch_plugin_cmake(
    cmake_file: Path,
    prebuilt_root: Path,
) -> None:
    # Flutter resolves this dependency from the lockfile with
    # --enforce-lockfile before this script runs. Anchor the rewrite to its
    # CMake structure instead of an upstream file hash: the Pub cache retains
    # this file between jobs, and a dependency update should not need a manual
    # checksum edit when the relevant build blocks remain compatible.
    source = cmake_file.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    if (
        source.count(WHISPER_IMPORTED_TARGETS) == 1
        and source.count(WHISPER_PATCH_MARKER) == 1
        and source.count(WHISPER_MSVC_WARNING_BLOCK_PATCHED) == 1
        and source.count(WHISPER_MSVC_WARNING_BLOCK) == 0
    ):
        # The current marked output is already cached.
        return

    if (
        source.count(WHISPER_IMPORTED_TARGETS_BODY) == 1
        and source.count(WHISPER_IMPORTED_TARGETS) == 0
        and source.count(WHISPER_PATCH_MARKER) == 0
        and source.count(WHISPER_MSVC_WARNING_BLOCK_PATCHED) == 1
        and source.count(WHISPER_MSVC_WARNING_BLOCK) == 0
    ):
        # Migrate the exact unmarked output written by earlier releases.
        source = source.replace(WHISPER_IMPORTED_TARGETS_BODY, WHISPER_IMPORTED_TARGETS)
        cmake_file.write_text(source, encoding="utf-8", newline="\n")
        return

    if source.count(WHISPER_ADD_SUBDIRECTORY) != 1:
        raise ValueError(
            "Refusing to patch an unrecognized flutter_whisper_ggml Windows CMakeLists.txt: "
            "expected one Whisper add_subdirectory block or this script's marked rewrite"
        )
    if source.count(WHISPER_MSVC_WARNING_BLOCK) != 1:
        raise ValueError("The pinned Whisper CMake file no longer has the expected MSVC warning-options block")
    if (
        source.count(WHISPER_IMPORTED_TARGETS_BODY)
        or source.count(WHISPER_PATCH_MARKER)
        or source.count(WHISPER_MSVC_WARNING_BLOCK_PATCHED)
    ):
        raise ValueError("Refusing to patch a mixed or partially rewritten Whisper CMake file")
    patched = source.replace(WHISPER_ADD_SUBDIRECTORY, WHISPER_IMPORTED_TARGETS)
    patched = patched.replace(WHISPER_MSVC_WARNING_BLOCK, WHISPER_MSVC_WARNING_BLOCK_PATCHED)
    cmake_file.write_text(patched, encoding="utf-8", newline="\n")


def cmake_identity_probe(work_root: Path, generator: str) -> None:
    source = work_root / "msvc-probe-source"
    build = work_root / "msvc-probe-build"
    source.mkdir()
    (source / "CMakeLists.txt").write_text(
        '''cmake_minimum_required(VERSION 3.21)
project(pleazyng_arm64_msvc_probe LANGUAGES C CXX)
file(WRITE "${CMAKE_BINARY_DIR}/compiler-identities.txt"
  "${CMAKE_C_COMPILER_ID};${CMAKE_CXX_COMPILER_ID};${CMAKE_VS_PLATFORM_TOOLSET}")
''',
        encoding="utf-8",
    )
    subprocess.run(
        ["cmake", "-S", str(source), "-B", str(build), "-G", generator, "-A", "ARM64"],
        check=True,
    )
    identity_file = build / "compiler-identities.txt"
    if not identity_file.is_file():
        raise RuntimeError("CMake did not report the Windows ARM64 default compiler")
    identities = identity_file.read_text(encoding="utf-8").strip().split(";")
    if len(identities) != 3 or identities[:2] != ["MSVC", "MSVC"] or identities[2] != "v145":
        raise RuntimeError(
            "Flutter's Windows ARM64 plugins require the Visual Studio 2026 MSVC toolset; "
            f"the default CMake toolset reported {identities}"
        )
    print("Verified Windows ARM64 application compiler: MSVC v145")


def prepare() -> None:
    if os.name != "nt":
        raise RuntimeError("The pinned Windows ARM64 Whisper build must run on a native Windows host")
    runner_temp = Path(os.environ.get("RUNNER_TEMP", ""))
    package_config = ROOT / ".dart_tool/package_config.json"
    generator = os.environ.get("CMAKE_GENERATOR", "")
    if not runner_temp.is_dir() or not package_config.is_file() or generator != "Visual Studio 18 2026":
        raise RuntimeError("Windows ARM64 Whisper preparation requires the pinned Flutter package config and VS 2026")
    if os.environ.get("CMAKE_GENERATOR_TOOLSET") or os.environ.get("CC") or os.environ.get("CXX"):
        raise RuntimeError("The Flutter application must use the default MSVC toolset")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
    if not run_id.isdigit() or not attempt.isdigit():
        raise RuntimeError("GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT must be numeric")

    task_root = runner_temp / f"pleazyng-whisper-arm64-{run_id}-{attempt}"
    if task_root.exists() or task_root.is_symlink():
        raise RuntimeError(f"Refusing to reuse existing Whisper build directory: {task_root}")
    task_root.mkdir()
    cmake_identity_probe(task_root, generator)

    package = package_root(package_config)
    whisper_source = package / "whisper/v1.9.2"
    whisper_header = whisper_source / "include/whisper.h"
    plugin_cmake = package / "windows/CMakeLists.txt"
    if not whisper_header.is_file() or not plugin_cmake.is_file():
        raise RuntimeError("The hash-locked flutter_whisper_ggml package is incomplete")

    output_root = task_root / "libraries"
    output_root.mkdir()
    build_root = task_root / "clang-build"
    cmake_args = [
        "cmake",
        "-S",
        str(whisper_source),
        "-B",
        str(build_root),
        "-G",
        generator,
        "-T",
        "ClangCL",
        "-A",
        "ARM64",
        "-DBUILD_SHARED_LIBS=ON",
        "-DWHISPER_BUILD_TESTS=OFF",
        "-DWHISPER_BUILD_EXAMPLES=OFF",
        "-DWHISPER_BUILD_SERVER=OFF",
        "-DGGML_NATIVE=OFF",
        "-DGGML_OPENMP=OFF",
        "-DGGML_CUDA=OFF",
        "-DGGML_VULKAN=OFF",
        f"-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE={output_root}",
        f"-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE={output_root}",
        f"-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY_RELEASE={output_root}",
    ]
    subprocess.run(cmake_args, check=True)
    subprocess.run(
        ["cmake", "--build", str(build_root), "--config", "Release", "--target", "whisper", "--parallel", "4"],
        check=True,
    )

    required = [output_root / f"{target}.{suffix}" for target in ("whisper", "ggml", "ggml-base", "ggml-cpu") for suffix in ("dll", "lib")]
    missing = [path.name for path in required if not path.is_file()]
    if missing:
        raise RuntimeError("The pinned ARM64 Whisper build did not produce: " + ", ".join(missing))

    patch_plugin_cmake(plugin_cmake, output_root)
    github_env = os.environ.get("GITHUB_ENV")
    if not github_env:
        raise RuntimeError("GITHUB_ENV is required to pass the verified Whisper libraries to Flutter CMake")
    with Path(github_env).open("a", encoding="utf-8", newline="\n") as output:
        output.write(f"FLUTTER_WHISPER_PREBUILT_ROOT={output_root}\n")
    print(f"Built pinned ARM64 Whisper dependencies and verified the plugin CMake file: {output_root}")


def main() -> int:
    try:
        prepare()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
