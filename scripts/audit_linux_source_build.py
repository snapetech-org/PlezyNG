#!/usr/bin/env python3
"""Inventory locked Linux source inputs and known prebuilt runtime blockers.

This is a read-only maintainer audit. It does not generate a Flatpak manifest,
fetch sources, build the app, or qualify either Linux architecture.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

try:
    import yaml
except ModuleNotFoundError:
    yaml = None


ROOT = Path(__file__).resolve().parents[1]
FULL_SHA256 = re.compile(r"^[0-9a-f]{64}$")
FULL_GIT_COMMIT = re.compile(r"^[0-9a-f]{40}$")
LICENSE_PREFIXES = ("LICENSE", "COPYING", "NOTICE", "COPYRIGHT")
ARCHITECTURES = ("x86_64", "aarch64")


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def _relative(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.name


def _license_files(package_root: Path | None) -> list[str]:
    if package_root is None or not package_root.is_dir():
        return []
    found: set[str] = set()
    for item in package_root.iterdir():
        upper = item.name.upper()
        if item.is_file() and upper.startswith(LICENSE_PREFIXES):
            found.add(item.relative_to(package_root).as_posix())
        elif item.is_dir() and upper == "LICENSES":
            for license_file in item.rglob("*"):
                if license_file.is_file() and not license_file.is_symlink():
                    found.add(license_file.relative_to(package_root).as_posix())
    return sorted(found)


def _linux_elf_files(package_root: Path | None) -> list[str]:
    if package_root is None:
        return []
    linux_root = package_root / "linux"
    if not linux_root.is_dir():
        return []
    found: list[str] = []
    for path in linux_root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            with path.open("rb") as source:
                is_elf = source.read(4) == b"\x7fELF"
        except OSError:
            continue
        if is_elf:
            found.append(path.relative_to(package_root).as_posix())
    return sorted(found)


def _hosted_package_root(pub_cache: Path, name: str, version: str, registry: str) -> Path:
    host = urlsplit(registry).netloc or "pub.dev"
    return pub_cache / "hosted" / host / f"{name}-{version}"


def _git_package_root(
    pub_cache: Path,
    description: dict[str, Any],
) -> Path | None:
    resolved_ref = description.get("resolved-ref")
    url = description.get("url")
    subpath = description.get("path", ".")
    if not isinstance(resolved_ref, str) or not isinstance(url, str):
        return None

    repository = Path(urlsplit(url).path.rstrip("/")).name.removesuffix(".git")
    checkout_root = pub_cache / "git" / "checkouts"
    for candidate in checkout_root.glob(f"{repository}-*"):
        checkout = candidate / resolved_ref
        package_root = checkout / subpath
        if package_root.is_dir():
            return package_root
    return None


def _package_root(
    root: Path,
    pub_cache: Path,
    name: str,
    package: dict[str, Any],
) -> Path | None:
    source = package.get("source")
    description = package.get("description")
    if not isinstance(description, dict):
        description = {}
    version = str(package.get("version", ""))

    if source == "hosted":
        registry = description.get("url", "https://pub.dev")
        if isinstance(registry, str):
            return _hosted_package_root(pub_cache, name, version, registry)
    elif source == "git":
        return _git_package_root(pub_cache, description)
    elif source == "path":
        path_value = description.get("path")
        if isinstance(path_value, str):
            path = Path(path_value)
            return (path if path.is_absolute() else root / path).resolve()
    return None


def _package_license_expression(package_root: Path | None) -> str | None:
    if yaml is None or package_root is None:
        return None
    pubspec = package_root / "pubspec.yaml"
    if not pubspec.is_file():
        return None
    try:
        metadata = yaml.safe_load(pubspec.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError):
        return None
    if not isinstance(metadata, dict):
        return None
    license_value = metadata.get("license")
    return license_value if isinstance(license_value, str) and license_value.strip() else None


def _package_inventory(root: Path, pub_cache: Path) -> dict[str, Any]:
    if yaml is None:
        raise RuntimeError(
            "PyYAML is required to read pubspec.lock; install it with "
            "python3 -m pip install PyYAML"
        )
    lock_path = root / "pubspec.lock"
    lock = yaml.safe_load(lock_path.read_text(encoding="utf-8"))
    packages = lock.get("packages") if isinstance(lock, dict) else None
    if not isinstance(packages, dict):
        raise ValueError(f"{lock_path}: missing packages mapping")

    records: list[dict[str, Any]] = []
    for name, package in sorted(packages.items()):
        if not isinstance(package, dict):
            raise ValueError(f"{lock_path}: package {name} must be an object")
        description = package.get("description")
        if not isinstance(description, dict):
            description = {}
        source = package.get("source")
        version = str(package.get("version", ""))
        package_root = _package_root(root, pub_cache, name, package)
        source_cached = bool(package_root and package_root.is_dir())
        license_files = _license_files(package_root)
        license_expression = _package_license_expression(package_root)
        if not license_files and source == "path" and (root / "LICENSE").is_file():
            license_files = ["../../LICENSE (repository license)"]
        if license_files:
            license_status = "license-file-evidence-found"
        elif not source_cached:
            license_status = "source-not-in-local-cache"
        elif license_expression:
            license_status = "expression-present-license-file-not-found"
        else:
            license_status = "license-file-not-found"

        checksum = description.get("sha256") if source == "hosted" else None
        registry = description.get("url") if source == "hosted" else None
        if source == "hosted" and not isinstance(registry, str):
            registry = "https://pub.dev"
        archive_url = None
        if isinstance(registry, str) and urlsplit(registry).hostname == "pub.dev":
            archive_url = f"https://pub.dev/api/archives/{name}-{version}.tar.gz"

        resolved_ref = description.get("resolved-ref") if source == "git" else None
        source_url = description.get("url") if source == "git" else None
        if source == "path":
            source_url = description.get("path")
        elif source == "sdk":
            source_url = description.get("sdk")

        records.append(
            {
                "name": name,
                "version": version,
                "dependency": package.get("dependency"),
                "source": source,
                "registry": registry,
                "sourceUrl": archive_url or source_url,
                "sourceArchiveSha256": checksum,
                "gitCommit": resolved_ref,
                "gitSubpath": description.get("path") if source == "git" else None,
                "sourcePresentInLocalCache": source_cached,
                "licenseExpression": license_expression,
                "licenseEvidenceStatus": license_status,
                "licenseFiles": license_files,
                "linuxElfFiles": _linux_elf_files(package_root),
            }
        )

    hosted = [item for item in records if item["source"] == "hosted"]
    git = [item for item in records if item["source"] == "git"]
    path = [item for item in records if item["source"] == "path"]
    sdk = [item for item in records if item["source"] == "sdk"]
    missing_hosted_hashes = [
        item["name"]
        for item in hosted
        if not isinstance(item["sourceArchiveSha256"], str)
        or FULL_SHA256.fullmatch(item["sourceArchiveSha256"]) is None
    ]
    linux_binary_packages = [item for item in records if item["linuxElfFiles"]]
    license_evidence_missing = [item for item in records if not item["licenseFiles"]]
    license_status_counts: dict[str, int] = {}
    for item in records:
        status = item["licenseEvidenceStatus"]
        license_status_counts[status] = license_status_counts.get(status, 0) + 1

    return {
        "lockFile": "pubspec.lock",
        "packageCount": len(records),
        "sourceCounts": {
            "hosted": len(hosted),
            "git": len(git),
            "path": len(path),
            "sdk": len(sdk),
        },
        "scope": (
            "All locked packages are inventoried. This is a conservative full-lock inventory, "
            "not a platform-filtered Linux dependency graph."
        ),
        "hostedPackagesMissingSha256": missing_hosted_hashes,
        "packagesWithoutLicenseFileEvidence": license_evidence_missing,
        "licenseEvidenceCounts": license_status_counts,
        "linuxElfPackageNames": [item["name"] for item in linux_binary_packages],
        "packages": records,
    }


def _native_inputs(root: Path, package_inventory: dict[str, Any]) -> dict[str, Any]:
    mpv_lock = _read_json(root / "mpv-build.lock.json")
    linux_artifacts = mpv_lock["artifacts"]["linux"]
    mpv_assets = {}
    for architecture in ARCHITECTURES:
        entry = linux_artifacts["assets"][architecture]
        mpv_assets[architecture] = {
            "url": f"{linux_artifacts['assetBase']}/{entry['asset']}",
            "sha256": entry["checksum"],
        }

    sdk = _read_json(root / "scripts/flutter/sdk-pin.json")
    source_repo = f"https://github.com/{mpv_lock['repo']}"
    source_commit = mpv_lock["commit"]
    mpv_driver_files = (
        "platforms/linux/build.sh",
        "platforms/linux/container-build.sh",
        "platforms/linux/package.sh",
        "versions.json",
    )

    dv_runtime = _read_json(root / "tools/dv-engine/offline-runtime.lock.json")
    dv_sources = _read_json(root / "tools/dv-engine/offline.lock.json")
    dv_assets = {}
    for architecture in ARCHITECTURES:
        entry = dv_runtime["assets"][architecture]
        dv_assets[architecture] = {
            "url": f"{dv_runtime['assetBase']}/{entry['asset']}",
            "sha256": entry["checksum"],
        }

    model_manifest = _read_json(root / "assets/motion_models/manifest.json")
    model_records = []
    for model_name in ("anvil-s-1080p", "anvil-m-1080p"):
        model = model_manifest.get("models", {}).get(model_name)
        if not isinstance(model, dict):
            raise ValueError(f"assets/motion_models/manifest.json: missing {model_name}")
        model_records.append(
            {
                "name": model_name,
                "url": (
                    f"{model['source'].rstrip('/')}/resolve/{model['sourceRevision']}"
                    f"/onnx/{model['file']}"
                ),
                "sha256": model.get("sha256"),
                "license": model.get("license"),
                "licenseFile": model.get("licenseFile"),
                "runtimeData": True,
            }
        )

    sherpa_record: dict[str, Any] | None = None
    for package in package_inventory["packages"]:
        if package["name"] == "sherpa_onnx_linux":
            sherpa_record = package
            break

    return {
        "flutter": {
            "version": sdk.get("version"),
            "frameworkRevision": sdk.get("frameworkRevision"),
            "engineRevision": sdk.get("engineRevision"),
            "engineSourceUrl": f"https://github.com/flutter/engine/tree/{sdk.get('engineRevision')}",
            "sourceBuildStatus": (
                "SDK revisions are pinned, but the Linux SDK/engine runtime is distributed "
                "as a precompiled toolchain; this repository has no source-built Flutter engine path."
            ),
        },
        "libmpv": {
            "sourceRepository": source_repo,
            "sourceCommit": source_commit,
            "sourceDriverFiles": [
                {
                    "path": path,
                    "url": f"{source_repo}/blob/{source_commit}/{path}",
                }
                for path in mpv_driver_files
            ],
            "componentSourceLockUrl": f"{source_repo}/blob/{source_commit}/versions.json",
            "lockedLinuxReleaseAssets": mpv_assets,
            "sourceBuildStatus": (
                "The pinned project contains a Linux source driver, but the local app lock consumes "
                "its prebuilt release assets. The driver fetches component sources and installs host "
                "packages during its build; no offline Flatpak source staging is wired here."
            ),
            "licenseEvidence": (
                "The pinned driver describes GPL builds and links to FFmpeg and mpv notices. "
                "This audit does not yet inventory and stage every transitive component license."
            ),
        },
        "sherpaOnnxLinux": sherpa_record,
        "dolbyVisionRuntime": {
            "lockedReleaseAssets": dv_assets,
            "sourceLockFile": "tools/dv-engine/offline.lock.json",
            "sourcePins": dv_sources.get("sources", {}),
            "wheels": dv_sources.get("wheels", {}),
            "sourceBuildStatus": (
                "The app currently installs architecture-specific prebuilt runtime archives. "
                "Their build inputs are partly source-pinned, but the app has no offline source-build "
                "path that produces these runtime archives."
            ),
        },
        "neuralModelRuntimeData": model_records,
    }


def audit(root: Path, pub_cache: Path) -> dict[str, Any]:
    packages = _package_inventory(root, pub_cache)
    native = _native_inputs(root, packages)
    flatpak_manifest = _read_json(root / "linux/packaging/flatpak/org.snapetech.pleazyng.json")
    manifest_sources = [
        source
        for module in flatpak_manifest.get("modules", [])
        if isinstance(module, dict)
        for source in module.get("sources", [])
        if isinstance(source, dict)
    ]
    bundle_directory_sources = [source for source in manifest_sources if source.get("type") == "dir"]

    blockers = [
        {
            "component": "Flutter Linux engine",
            "reason": native["flutter"]["sourceBuildStatus"],
        },
        {
            "component": "Sherpa ONNX Linux runtime",
            "reason": (
                "The locked sherpa_onnx_linux pub archive contains precompiled Linux ELF libraries; "
                "its archive hash and license text are recorded, but this app does not build them from source."
            ),
        },
        {
            "component": "libmpv and its Linux dependency graph",
            "reason": native["libmpv"]["sourceBuildStatus"],
        },
        {
            "component": "Dolby Vision conversion runtime",
            "reason": native["dolbyVisionRuntime"]["sourceBuildStatus"],
        },
        {
            "component": "Human-authored Flathub packaging",
            "reason": (
                "Flathub policy prohibits AI-generated or AI-assisted manifest content. "
                "A qualified source-build manifest must be authored and reviewed by a human."
            ),
        },
    ]

    return {
        "schemaVersion": 1,
        "audit": "Pleazyng Linux source-build inventory",
        "readOnly": True,
        "manifestGenerated": False,
        "buildRun": False,
        "status": "not-ready",
        "ready": False,
        "architecturesRequired": list(ARCHITECTURES),
        "offlineBuildRequired": True,
        "officialRequirements": {
            "url": "https://docs.flathub.org/docs/for-app-authors/requirements",
            "rules": [
                "Dependencies must be manifest sources; Flatpak builds have no network access.",
                "Source-available applications and included runtime dependencies must build entirely from source.",
                "AI-generated or AI-assisted Flathub manifest content is prohibited.",
            ],
        },
        "packageInventory": packages,
        "nativeInputs": native,
        "currentGitHubFlatpakPath": {
            "manifest": "linux/packaging/flatpak/org.snapetech.pleazyng.json",
            "packager": "linux/packaging/build-flatpak.py",
            "mode": "Packages a previously resolved release bundle, not app or native source builds.",
            "localBundleSources": bundle_directory_sources,
            "separateFromGitHubReleaseBundles": True,
        },
        "blockers": blockers,
        "licenseAudit": {
            "status": "source-file inventory only; human license and redistribution review remains required",
            "packageLicenseEvidenceRecorded": True,
            "nativeComponentLicenseClosureComplete": False,
            "note": (
                "Package lock metadata and license-file paths do not establish legal compatibility. "
                "Review each redistributed component and install its required notices in the final app."
            ),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--pub-cache",
        type=Path,
        default=Path.home() / ".pub-cache",
        help="read-only pub cache used to inspect source archives and license files",
    )
    parser.add_argument("--indent", type=int, default=2)
    args = parser.parse_args()
    try:
        report = audit(args.root.resolve(), args.pub_cache.expanduser().resolve())
    except (OSError, KeyError, TypeError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"Source-build inventory failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=max(0, args.indent), sort_keys=True))
    return 2 if not report["ready"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
