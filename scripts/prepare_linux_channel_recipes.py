#!/usr/bin/env python3
"""Prepare Nix/aerynOS candidates from an authenticated release checksum list.

This offline renderer neither authenticates input nor publishes packages. Verify
the checksum manifest's GitHub attestation before invoking it; see the runbook.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = {arch: f"pleazyng-linux-{arch}.tar.gz" for arch in ("x64", "arm64")}


def release_hashes(manifest: str) -> dict[str, str]:
    hashes = {}
    for line in manifest.splitlines():
        fields = line.split()
        if len(fields) != 2 or fields[1] not in ASSETS.values():
            continue
        digest, name = fields
        if name in hashes or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            raise ValueError(f"Duplicate or invalid SHA-256 for {name}")
        if digest == "0" * 64:
            raise ValueError(f"Placeholder SHA-256 for {name}")
        hashes[name] = digest.lower()
    missing = set(ASSETS.values()) - hashes.keys()
    if missing:
        raise ValueError(f"Missing release assets: {', '.join(sorted(missing))}")
    return hashes


def prepare(tag: str, checksums: Path, output: Path) -> None:
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("tag must be a stable vMAJOR.MINOR.PATCH tag")
    raw = checksums.read_bytes()
    hashes = release_hashes(raw.decode("utf-8"))
    replacements = {
        "@@TAG@@": tag,
        "@@VERSION@@": tag[1:],
        "@@X64_SHA256@@": hashes[ASSETS["x64"]],
        "@@ARM64_SHA256@@": hashes[ASSETS["arm64"]],
    }
    webkit = json.loads((ROOT / "linux/packaging/webkit-runtime.json").read_text())["x64"]
    replacements.update({
        "@@WEBKIT_URL@@": webkit["url"],
        "@@WEBKIT_SHA256@@": webkit["sha256"],
    })
    files = {}
    files['nix/release.json'] = (json.dumps({
        'version': tag[1:], 'tag': tag, 'repository': 'snapetech-org/pleazyng',
        'sha256': {arch: hashes[name] for arch, name in ASSETS.items()},
    }, indent=2) + '\n').encode()
    for channel, name in (("nix", "pleazyng.nix"), ("aerynos", "stone.yaml")):
        template = ROOT / "linux/packaging" / channel / f"{name}.template"
        content = template.read_text(encoding="utf-8")
        for token, value in replacements.items():
            content = content.replace(token, value)
        if "@@" in content:
            raise ValueError(f"Unresolved placeholder in {template}")
        files[f"{channel}/{name}"] = content.encode()
        support = f"{channel}/pkg" if channel == "aerynos" else channel
        files[f"{support}/org.snapetech.pleazyng.desktop"] = (
            ROOT / "linux/packaging/org.snapetech.pleazyng.desktop"
        ).read_bytes()
        files[f"{support}/LICENSE"] = (ROOT / "LICENSE").read_bytes()
        files[f"{support}/relocate-caches.py"] = (
            ROOT / "linux/packaging/flatpak/relocate-caches.py"
        ).read_bytes()
        for name in ('webkit-runtime.json', 'install-webkit-helpers.py', 'rebuild-pixbuf-cache.py'):
            files[f'{support}/{name}'] = (ROOT / 'linux/packaging' / name).read_bytes()
        if channel == "aerynos":
            files[f"{support}/normalize-bundle-rpaths.py"] = (
                ROOT / "linux/packaging/normalize-bundle-rpaths.py"
            ).read_bytes()
    receipt = {
        "release_tag": tag,
        "repository": "snapetech-org/pleazyng",
        "checksum_manifest_sha256": hashlib.sha256(raw).hexdigest(),
        "assets": hashes,
        "state": "prepared-unqualified",
        "published": False,
        "native_builds_verified": False,
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()},
    }
    # A fresh directory prevents accidental edits to an existing handoff.
    output.mkdir(parents=True, exist_ok=False)
    for name, data in files.items():
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    (output / "preparation.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--checksums", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        prepare(args.tag, args.checksums, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Recipe preparation failed: {error}\n")
    print(f"Prepared unqualified channel candidates in {args.output}")


if __name__ == "__main__":
    main()
