#!/usr/bin/env python3
"""Advance Nix metadata using an authenticated, complete public release."""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from prepare_linux_channel_recipes import ASSETS, release_hashes
from pubspec_version import parse_pubspec_version
from release_coverage import missing_assets
from verify_release_attestation import require_repository_identity
from verify_frozen_packaging_repair import verify_receipt

REPOSITORY = "snapetech-org/pleazyng"
METADATA_PATH = "linux/packaging/nix/release.json"
ACTIVATION_VERSION = (3, 0, 33)


def identity(metadata: dict) -> dict:
    return {"release": {key: metadata.get(key) for key in
                        ("id", "tag_name", "draft", "prerelease", "published_at")},
            "assets": sorted((asset.get("name"), asset.get("id"), asset.get("size"), asset.get("digest"))
                             for asset in metadata.get("assets", []))}


def version(tag: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Expected a stable release tag")
    return tuple(map(int, tag[1:].split(".")))


def validate_release(metadata: dict) -> dict[str, dict]:
    version(metadata.get("tag_name", ""))
    if (metadata.get("draft") is not False or metadata.get("prerelease") is not False
            or not metadata.get("published_at")):
        raise ValueError("Nix metadata requires a published stable release")
    assets = {}
    for asset in metadata.get("assets", []):
        name = asset.get("name")
        if not isinstance(name, str) or asset.get("size", 0) <= 0:
            continue
        if name in assets:
            raise ValueError("Duplicate release asset")
        assets[name] = asset
    missing = missing_assets(set(assets))
    if missing or "SHA256SUMS.txt" not in assets:
        raise ValueError("Nix metadata requires complete release coverage and final checksums")
    return assets


def proposed_metadata(current: dict, tag: str, manifest: str) -> dict:
    incoming = version(tag)
    if incoming < ACTIVATION_VERSION:
        raise ValueError("Retired release is below the Nix activation floor")
    if current.get("repository") != REPOSITORY or current.get("version") != current.get("tag", "")[1:]:
        raise ValueError("Existing Nix metadata identity is invalid")
    hashes = release_hashes(manifest)
    proposed = {"version": tag[1:], "tag": tag, "repository": REPOSITORY,
                "sha256": {arch: hashes[name] for arch, name in ASSETS.items()}}
    existing = version(current["tag"])
    if incoming < existing:
        raise ValueError("Nix metadata cannot downgrade")
    if incoming == existing and current != proposed:
        raise ValueError("Published Nix metadata changed for the same version")
    return proposed


def manifest_run(proofs: list, digest: str, commit: str) -> tuple[int, int]:
    """Inspect only statements already cryptographically verified by gh."""
    matches = set()
    for proof in proofs:
        statement = proof.get("verificationResult", {}).get("statement", {})
        if not any(subject.get("name") == "SHA256SUMS.txt"
                   and subject.get("digest", {}).get("sha256") == digest
                   for subject in statement.get("subject", [])):
            continue
        predicate = statement.get("predicate", {})
        definition = predicate.get("buildDefinition", {})
        workflow = definition.get("externalParameters", {}).get("workflow", {})
        if (workflow.get("repository") != f"https://github.com/{REPOSITORY}"
                or workflow.get("path") != ".github/workflows/build.yml"
                or not any(dependency.get("digest", {}).get("gitCommit") == commit
                           and dependency.get("uri", "").startswith(f"git+https://github.com/{REPOSITORY}@")
                           for dependency in definition.get("resolvedDependencies", []))):
            continue
        invocation = predicate.get("runDetails", {}).get("metadata", {}).get("invocationId", "")
        match = re.fullmatch(rf"https://github.com/{REPOSITORY}/actions/runs/([1-9][0-9]*)/attempts/([1-9][0-9]*)", invocation)
        if match:
            matches.add(tuple(map(int, match.groups())))
    if len(matches) != 1:
        raise ValueError("Final manifest has no unique exact-source assembly attestation")
    return matches.pop()


def recovery_source(directory: str, assets: dict, manifest: str, product_commit: str,
                    tag: str) -> tuple[str, dict | None]:
    """Read an attestation-bound frozen-repair receipt, if this release has one."""
    asset = assets.get("platform-reuse-provenance.json")
    if asset is None:
        return product_commit, None
    if asset.get("size", 0) > 1024 * 1024:
        raise ValueError("Unexpected recovery receipt size")
    subprocess.run(["gh", "release", "download", tag, "--repo", REPOSITORY,
                    "--pattern", "platform-reuse-provenance.json", "--dir", directory], check=True)
    path = Path(directory) / "platform-reuse-provenance.json"
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if len(raw) != asset["size"] or asset.get("digest") != f"sha256:{digest}":
        raise ValueError("Recovery receipt differs from public release asset")
    matches = [line.split()[0] for line in manifest.splitlines()
               if len(line.split()) == 2 and line.split()[1].lstrip("*") == path.name]
    if matches != [digest]:
        raise ValueError("Final checksums do not uniquely bind the recovery receipt")
    receipt = json.loads(raw)
    workflow_commit = receipt.get("workflow_source_sha")
    if (receipt.get("product_source_sha") != product_commit
            or not isinstance(workflow_commit, str)
            or re.fullmatch(r"[0-9a-f]{40}", workflow_commit) is None):
        raise ValueError("Recovery receipt has a different immutable product or workflow source")
    return workflow_commit, receipt


def prepare(root: Path, metadata: dict, commit: str, github) -> tuple[str | None, dict]:
    """Verify all external inputs before returning bytes for a maintained file."""
    assets = validate_release(metadata)
    tag = metadata["tag_name"]
    if version(tag) < ACTIVATION_VERSION:
        return None, {"tag": tag, "state": "below-activation-floor"}
    require_repository_identity(REPOSITORY)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid immutable source")
    comparison = github(f"compare/{commit}...main")
    if comparison.get("status") not in {"identical", "ahead"}:
        raise ValueError("Release source is not on canonical main")
    source = github(f"contents/pubspec.yaml?ref={commit}")
    if source.get("encoding") != "base64" or source.get("size", 0) > 1024 * 1024:
        raise ValueError("Cannot verify immutable application version")
    source_bytes = base64.b64decode("".join(source.get("content", "").split()), validate=True)
    if len(source_bytes) != source.get("size"):
        raise ValueError("Immutable application source size differs")
    pubspec = source_bytes.decode("utf-8")
    marketing, build = parse_pubspec_version(pubspec)
    if "v" + marketing.split("+", 1)[0] != tag:
        raise ValueError("Release tag differs from immutable application version")
    if assets["SHA256SUMS.txt"]["size"] > 1024 * 1024:
        raise ValueError("Unexpected checksum manifest size")
    with tempfile.TemporaryDirectory(prefix="pleazyng-nix-metadata-") as directory:
        subprocess.run(["gh", "release", "download", tag, "--repo", REPOSITORY,
                        "--pattern", "SHA256SUMS.txt", "--dir", directory], check=True)
        manifest = Path(directory) / "SHA256SUMS.txt"
        raw = manifest.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if len(raw) != assets[manifest.name]["size"] or assets[manifest.name].get("digest") != f"sha256:{digest}":
            raise ValueError("Final manifest differs from public release asset")
        workflow_commit, recovery = recovery_source(directory, assets, raw.decode("utf-8"), commit, tag)
        result = subprocess.run(["gh", "attestation", "verify", str(manifest), "--repo", REPOSITORY,
                                 "--source-digest", workflow_commit, "--signer-workflow",
                                 f"{REPOSITORY}/.github/workflows/build.yml", "--format", "json"],
                                check=True, capture_output=True, text=True)
        run_id, attempt = manifest_run(json.loads(result.stdout), digest, workflow_commit)
        assembly = github(f"actions/runs/{run_id}/attempts/{attempt}")
        if (assembly.get("status") != "completed" or assembly.get("conclusion") != "success"
                or assembly.get("head_sha") != workflow_commit or assembly.get("path") != ".github/workflows/build.yml"
                or assembly.get("run_attempt") != attempt
                or assembly.get("repository", {}).get("full_name") != REPOSITORY):
            raise ValueError("Manifest assembly did not successfully build the immutable release source")
        if recovery is not None:
            prefix = f"repos/{REPOSITORY}/"
            def api(path: str) -> dict:
                if path == f"repos/{REPOSITORY}":
                    return json.loads(subprocess.check_output(["gh", "api", path], text=True))
                if not path.startswith(prefix):
                    raise ValueError("Recovery verifier requested a foreign repository")
                return github(path[len(prefix):])
            approval = verify_receipt(
                recovery, product_source_sha=commit,
                packaging_source_sha=recovery.get("packaging_source_sha"),
                workflow_source_sha=workflow_commit,
                source_run_id=recovery.get("source_run_id"), assembly_run_id=run_id,
                api=api,
            )
            if (recovery.get("packaging_approval") != approval
                    or recovery.get("source_sha") != commit
                    or recovery.get("actual_checkout_sha") != recovery.get("packaging_source_sha")):
                raise ValueError("Recovery receipt differs from its independently approved repair")
        hashes = release_hashes(raw.decode("utf-8"))
        for name, expected in hashes.items():
            if assets[name].get("digest") != f"sha256:{expected}":
                raise ValueError("Linux release asset differs from authenticated manifest")
        current = json.loads((root / METADATA_PATH).read_text())
        proposed = proposed_metadata(current, tag, raw.decode("utf-8"))
    # Publication may have advanced during network verification. Reconcile again
    # from fresh main rather than writing facts from a superseded observation.
    if identity(github("releases/latest")) != identity(metadata):
        raise ValueError("Public latest release changed during verification")
    return json.dumps(proposed, indent=2) + "\n", {
        "tag": tag, "source_commit": commit, "manifest_sha256": digest,
        "application_build": build,
        "assembly_run": run_id, "assembly_attempt": attempt,
        "assembly_workflow_source": workflow_commit,
        "sha256": proposed["sha256"], "state": "authenticated-metadata",
        "native_qualification": "separate", "upstream_acceptance": "separate",
    }
