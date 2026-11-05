#!/usr/bin/env python3
"""Verify and reuse successful non-Android release outputs after infrastructure fixes."""

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

import verify_release_ci as release_ci


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "snapetech-org/PlezyNG"
# Application sources, dependency pins, and native toolchain inputs are excluded.
RECOVERY_FILES = frozenset({
    ".github/workflows/build.yml", ".github/workflows/ci.yml", "CHANGELOG.md",
    "docs/maintainers/full-release-build.md", "scripts/release_all_platforms.py",
    "scripts/prepare_gradle_repositories.py", "scripts/gradle/plezyng-maven-mirror.init.gradle",
    "scripts/checks/test_prepare_gradle_repositories.py", "scripts/recover_release_platforms.py",
    "scripts/checks/test_recover_release_platforms.py", "scripts/checks/check_build_workflow.py",
    "scripts/checks/test_check_build_workflow.py", "scripts/checks/test_release_ci_gate.py",
})
REQUIRED_JOBS = (
    "Validate release request", "Build WebOS TV package (ARMv7)",
    "Build tvOS developer package (arm64)", "build-ios", "build-macos",
    "Build Linux (x64)", "Build Linux (arm64)",
    "Build Windows (x64)", "Build Windows (arm64)", "package-windows",
    "Build Samsung Tizen TV package (ARM) / validate",
    "Build Samsung Tizen TV package (ARM) / package",
)
ARTIFACTS = {
    "plezyng-tizen-arm-experimental": "tizen", "ios-ipa": "ios-ipa", "tvos-ipa": "tvos-ipa",
    "macos-dmg": "macos-dmg", "windows-x64-portable": "windows-x64-portable",
    "windows-arm64-build": "windows-arm64-build", "windows-installer": "windows-installer",
    "windows-chocolatey": "windows-chocolatey", "linux-x64": "linux-x64",
    "linux-arm64": "linux-arm64", "linux-x64-appimage": "linux-x64",
}


class RecoveryError(RuntimeError):
    pass


def api(path):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode:
        raise RecoveryError(result.stderr.strip())
    return json.loads(result.stdout)


def collection(path, key):
    result = api(path + ("&" if "?" in path else "?") + "per_page=100")
    values = result.get(key)
    if not isinstance(values, list) or result.get("total_count", len(values)) > len(values):
        raise RecoveryError(f"Incomplete GitHub {key} inventory; refusing recovery.")
    return values


def ci_proof(repository, source_sha):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True)
        token = result.stdout.strip()
    gate = release_ci._manifest_gate()
    run = release_ci._latest_run(token, repository, source_sha, gate)
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise RecoveryError("The source release commit has no successful exact-SHA CI run.")
    errors = release_ci._check_jobs(token, repository, run, gate)
    if errors:
        raise RecoveryError("Source CI is incomplete: " + "; ".join(errors))
    return {"ci_run_id": run["id"], "ci_run_url": run["html_url"]}


def verify_source_run(run_id, head_sha, version, repository=REPOSITORY):
    if repository != REPOSITORY or not str(run_id).isdigit() or not re.fullmatch(r"[0-9a-f]{40}", head_sha):
        raise RecoveryError("Recovery requires the PlezyNG repository and exact run/commit identities.")
    source = api(f"repos/{repository}/actions/runs/{run_id}")
    source_sha = source.get("head_sha", "")
    if (source.get("status") != "completed" or source.get("event") != "workflow_dispatch"
        or source.get("head_branch") != "main"
        or source.get("head_repository", {}).get("full_name") != repository
        or source.get("path", "").split("@")[0] != ".github/workflows/build.yml"
        or source.get("display_title") != f"action:release:pool:private:tag:v{version}"
        or not re.fullmatch(r"[0-9a-f]{40}", source_sha)):
        raise RecoveryError("Source must be a completed trusted-main release run for this version.")
    comparison = api(f"repos/{repository}/compare/{source_sha}...{head_sha}")
    changed = comparison.get("files")
    if (comparison.get("status") not in {"ahead", "identical"}
        or comparison.get("merge_base_commit", {}).get("sha") != source_sha
        or not isinstance(changed, list) or len(changed) >= 300):
        raise RecoveryError("Cannot prove that the source release is an ancestor with complete file evidence.")
    blocked = sorted({path for entry in changed
                      for path in (entry.get("filename"), entry.get("previous_filename"))
                      if path and path not in RECOVERY_FILES})
    if blocked:
        raise RecoveryError("Application or pinned native inputs changed: " + ", ".join(blocked))
    jobs = collection(f"repos/{repository}/actions/runs/{run_id}/jobs", "jobs")
    for name in REQUIRED_JOBS:
        matches = [job for job in jobs if job.get("name") == name]
        if len(matches) != 1 or matches[0].get("status") != "completed" or matches[0].get("conclusion") != "success":
            raise RecoveryError(f"Source platform job is not uniquely successful: {name}")
    failures = [job.get("name") for job in jobs
                if job.get("conclusion") in {"failure", "cancelled", "timed_out"}
                and job.get("name") != "build-android"]
    if failures:
        raise RecoveryError("Other source jobs failed: " + ", ".join(failures))
    android = [job for job in jobs if job.get("name") == "build-android"]
    if len(android) != 1 or android[0].get("conclusion") != "failure":
        raise RecoveryError("Recovery requires exactly one failed Android job.")
    if any(job.get("name") == "create-release" and job.get("conclusion") != "skipped" for job in jobs):
        raise RecoveryError("The source run already attempted release creation; inspect its side effects.")
    return {"source_run_id": int(run_id), "source_sha": source_sha, "head_sha": head_sha,
            "version": version, "reused_jobs": list(REQUIRED_JOBS),
            **ci_proof(repository, source_sha)}


def extract_verified(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise RecoveryError("Artifact destination must not be a symlink.")
    with zipfile.ZipFile(archive) as source:
        if sum(member.file_size for member in source.infolist()) > 20 * 1024**3:
            raise RecoveryError("Reusable artifact exceeds the extraction budget.")
        seen = set()
        for member in source.infolist():
            path = PurePosixPath(member.filename)
            if (not path.parts or path.is_absolute() or ".." in path.parts or "\\" in member.filename
                or ":" in member.filename or str(path) in seen
                or stat.S_ISLNK(member.external_attr >> 16)):
                raise RecoveryError("Reusable artifact contains an unsafe member.")
            seen.add(str(path))
            target = destination.joinpath(*path.parts)
            if any(parent.is_symlink() for parent in (target, *target.parents)):
                raise RecoveryError("Artifact extraction must not follow symlinks.")
            if target.exists() and not member.is_dir():
                raise RecoveryError(f"Artifact would overwrite another platform file: {target}")
        source.extractall(destination)


def download_platforms(proof, destination, repository=REPOSITORY):
    run_id = proof["source_run_id"]
    inventory = collection(f"repos/{repository}/actions/runs/{run_id}/artifacts", "artifacts")
    wanted = dict(ARTIFACTS)
    if any(item.get("name") == "windows-msix" for item in inventory):
        wanted["windows-msix"] = "windows-msix"
    records = []
    for name, folder in wanted.items():
        matches = [item for item in inventory if item.get("name") == name and not item.get("expired")]
        if len(matches) != 1:
            raise RecoveryError(f"Reusable artifact is missing or ambiguous: {name}")
        item = matches[0]
        identity = item.get("workflow_run", {})
        digest = item.get("digest") or ""
        if (identity.get("id") != run_id or identity.get("head_sha") != proof["source_sha"]
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
            raise RecoveryError(f"Artifact lacks matching run, source, or digest evidence: {name}")
        with tempfile.TemporaryDirectory(prefix="plezyng-release-artifact-") as scratch:
            archive = Path(scratch) / "artifact.zip"
            with archive.open("wb") as output:
                result = subprocess.run(["gh", "api", "--allow-escape-sequences",
                                         f"repos/{repository}/actions/artifacts/{item['id']}/zip"], stdout=output)
            with archive.open("rb") as downloaded:
                actual_digest = hashlib.file_digest(downloaded, "sha256").hexdigest()
            if result.returncode or actual_digest != digest[7:]:
                raise RecoveryError(f"Reusable artifact download/digest verification failed: {name}")
            extract_verified(archive, destination / folder)
        records.append({"name": name, "artifact_id": item["id"], "digest": digest})
        print(f"Recovered verified {name} from run {run_id}.", flush=True)
    proof = {**proof, "artifacts": records}
    (destination / "platform-reuse-provenance.json").write_text(json.dumps(proof, indent=2) + "\n")
    return proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_run")
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--download", type=Path)
    args = parser.parse_args()
    proof = verify_source_run(args.source_run, args.head_sha, args.version)
    if args.download:
        proof = download_platforms(proof, args.download)
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"source_sha={proof['source_sha']}\nci_run_id={proof['ci_run_id']}\n")
    print(json.dumps(proof, indent=2))


if __name__ == "__main__":
    main()
