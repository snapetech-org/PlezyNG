#!/usr/bin/env python3
"""Build an isolated unsigned Mac App Store candidate and qualification receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT_PATH = ROOT / "macos/Runner.xcodeproj/project.pbxproj"
ENTITLEMENTS_PATH = ROOT / "macos/Runner/AppStore.entitlements"
OLD_ENTITLEMENT_SETTING = b"CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;"
STORE_ENTITLEMENT_SETTING = b"CODE_SIGN_ENTITLEMENTS = Runner/AppStore.entitlements;"
EXPECTED_BUNDLE_ID = "org.snapetech.pleazyng"
PACKAGE_ID = f"{EXPECTED_BUNDLE_ID}.macos-app-store-candidate"
EXPECTED_ARCHITECTURES = {"arm64", "x86_64"}
ARCHIVE_APP_SUFFIX = Path("Products/Applications/Pleazyng.app")


def run(
    command: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    capture_output: bool = False,
) -> str:
    if not capture_output:
        subprocess.run(command, cwd=cwd, env=env, check=True)
        return ""
    result = subprocess.run(command, cwd=cwd, env=env, check=True, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    return result.stdout.strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_entitlements() -> None:
    with ENTITLEMENTS_PATH.open("rb") as source:
        entitlements = plistlib.load(source)
    required = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.cs.allow-jit": True,
        "com.apple.security.device.audio-input": True,
        "com.apple.security.files.user-selected.read-write": True,
        "com.apple.security.network.client": True,
    }
    missing = sorted(key for key, value in required.items() if entitlements.get(key) is not value)
    if missing:
        raise ValueError(f"App Store entitlements are missing required values: {missing}")
    if entitlements.get("com.apple.security.cs.allow-unsigned-executable-memory") is True:
        raise ValueError("App Store entitlements must not enable unsigned executable memory")


def build_app(
    source_sha: str,
    relay_base_url: str,
    discord_application_id: str,
    archive_path: Path,
    derived_data_path: Path,
) -> None:
    if archive_path.exists():
        raise FileExistsError(f"Refusing to overwrite an existing Xcode archive: {archive_path}")
    build_env = os.environ.copy()
    build_env.update({
        "FLUTTER_XCODE_CODE_SIGNING_ALLOWED": "NO",
        "FLUTTER_XCODE_CODE_SIGNING_REQUIRED": "NO",
        "FLUTTER_XCODE_CODE_SIGNING_IDENTITY": "",
    })
    command = [
        "flutter", "build", "macos", "--release", "--no-codesign", "--config-only", "--verbose",
        "--dart-define=SUPPORTER_MODE=iap",
        "--dart-define=ENABLE_UPDATE_CHECK=false",
        f"--dart-define=GIT_COMMIT={source_sha}",
        f"--dart-define=PLEAZYNG_RELAY_BASE_URL={relay_base_url}",
        f"--dart-define=PLEAZYNG_DISCORD_APPLICATION_ID={discord_application_id}",
        "--split-debug-info=debug-info/macos-app-store-candidate",
    ]
    run(command, env=build_env)
    run(["pod", "install", "--deployment"], cwd=ROOT / "macos", env=build_env)

    # Capture the CocoaPods-updated project before temporarily selecting the
    # Store entitlements, then restore those exact post-install bytes.
    original_project = PROJECT_PATH.read_bytes()
    if original_project.count(OLD_ENTITLEMENT_SETTING) != 1:
        raise ValueError("Expected one Release CODE_SIGN_ENTITLEMENTS setting in the macOS Xcode project")
    PROJECT_PATH.write_bytes(original_project.replace(OLD_ENTITLEMENT_SETTING, STORE_ENTITLEMENT_SETTING))
    try:
        run(["plutil", "-lint", str(PROJECT_PATH)])
        run([
            "xcodebuild", "archive",
            "-workspace", str(ROOT / "macos/Runner.xcworkspace"),
            "-scheme", "Runner",
            "-configuration", "Release",
            "-sdk", "macosx",
            "-destination", "generic/platform=macOS",
            "-archivePath", str(archive_path),
            "-derivedDataPath", str(derived_data_path),
            "-clonedSourcePackagesDirPath", str(ROOT / "build/macos/SourcePackages"),
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
            "COMPILER_INDEX_STORE_ENABLE=NO",
        ], env=build_env)
    finally:
        PROJECT_PATH.write_bytes(original_project)


def inspect_app(app_path: Path) -> tuple[dict[str, object], list[str]]:
    info_path = app_path / "Contents/Info.plist"
    if not info_path.is_file():
        raise FileNotFoundError(f"Expected built app metadata at {info_path}")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
        raise ValueError(f"Unexpected macOS bundle identifier: {info.get('CFBundleIdentifier')!r}")
    if info.get("CFBundlePackageType") != "APPL":
        raise ValueError("The Mac App Store candidate must be an application bundle")
    version = info.get("CFBundleShortVersionString")
    build_number = info.get("CFBundleVersion")
    executable_name = info.get("CFBundleExecutable")
    if not all(isinstance(value, str) and value.strip() for value in (version, build_number, executable_name)):
        raise ValueError("Built app must have version, build number, and executable metadata")
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+-]*", version):
        raise ValueError(f"Invalid Mac installer version: {version!r}")
    executable = app_path / "Contents/MacOS" / executable_name
    architecture_text = run(["/usr/bin/lipo", "-archs", str(executable)], capture_output=True)
    architectures = sorted(set(architecture_text.split()))
    if not EXPECTED_ARCHITECTURES.issubset(architectures):
        raise ValueError(f"Mac App Store candidate lacks universal architectures: {architectures}")
    return {
        "bundle_identifier": EXPECTED_BUNDLE_ID,
        "version": version,
        "build_number": build_number,
        "executable": executable_name,
    }, architectures


def create_candidate(source_sha: str, output_dir: Path, archive_path: Path) -> tuple[Path, Path]:
    app_path = archive_path / ARCHIVE_APP_SUFFIX
    app_info, architectures = inspect_app(app_path)
    output_dir.mkdir(parents=True, exist_ok=True)
    package_path = output_dir / "pleazyng-macos-appstore-candidate.pkg"
    receipt_path = output_dir / "pleazyng-macos-appstore-candidate.json"
    if package_path.exists() or receipt_path.exists():
        raise FileExistsError(f"Refusing to overwrite a candidate output in {output_dir}")

    run([
        "productbuild", "--identifier", PACKAGE_ID, "--version", str(app_info["version"]),
        "--component", str(app_path), "/Applications", str(package_path),
    ])
    payload = run(["/usr/sbin/pkgutil", "--payload-files", str(package_path)], capture_output=True)
    if not any("Pleazyng.app/Contents/Info.plist" in line for line in payload.splitlines()):
        raise ValueError("Generated installer payload does not contain Pleazyng.app/Contents/Info.plist")

    receipt = {
        "schema_version": 1,
        "product": "Pleazyng",
        "channel": "Mac App Store candidate",
        "candidate_state": "unsigned-unqualified",
        "source_commit": source_sha,
        "application": {**app_info, "architectures": architectures},
        "archive": {"filename": archive_path.name, "signed": False},
        "package": {
            "filename": package_path.name,
            "identifier": PACKAGE_ID,
            "sha256": sha256_file(package_path),
            "size_bytes": package_path.stat().st_size,
            "signed": False,
        },
        "qualification": {
            "app_signed_for_distribution": False,
            "installer_signed_for_app_store": False,
            "uploadable_to_app_store_connect": False,
            "app_store_connect_processed": False,
            "storekit_purchase_restore": False,
            "sandboxed_runtime": False,
            "jit_runtime": False,
            "apple_review": False,
        },
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return package_path, receipt_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-sha", required=True, help="40-character Git commit used for the build")
    parser.add_argument(
        "--output-dir", type=Path, required=True,
        help="Directory for the candidate package and receipt",
    )
    parser.add_argument(
        "--derived-data-dir", type=Path, required=True,
        help="Separate Xcode DerivedData directory, retained outside the candidate artifact",
    )
    parser.add_argument("--relay-base-url", default="", help="Configured Pleazyng relay URL build define")
    parser.add_argument("--discord-application-id", default="", help="Configured Discord application ID build define")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.source_sha):
        parser.error("--source-sha must be a full 40-character Git commit")
    return args


def main() -> int:
    args = parse_args()
    validate_entitlements()
    output_dir = args.output_dir.resolve()
    derived_data_dir = args.derived_data_dir.resolve()
    archive_path = output_dir / "Pleazyng.xcarchive"
    output_dir.mkdir(parents=True, exist_ok=True)
    for output in (
        archive_path,
        output_dir / "pleazyng-macos-appstore-candidate.pkg",
        output_dir / "pleazyng-macos-appstore-candidate.json",
    ):
        if output.exists():
            raise FileExistsError(f"Refusing to overwrite a candidate output: {output}")
    if derived_data_dir.exists():
        raise FileExistsError(f"Refusing to reuse existing Xcode DerivedData: {derived_data_dir}")
    build_app(args.source_sha, args.relay_base_url, args.discord_application_id, archive_path, derived_data_dir)
    package_path, receipt_path = create_candidate(args.source_sha.lower(), output_dir, archive_path)
    print(f"Created unsigned Mac App Store candidate: {package_path}")
    print(f"Created qualification receipt: {receipt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
