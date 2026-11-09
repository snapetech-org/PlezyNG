#!/usr/bin/env python3
"""Recover successful platform outputs while rebuilding Android and WebOS after CI fixes."""

import argparse
import ast
import base64
import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path, PurePosixPath

import verify_release_ci as release_ci


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "snapetech-org/pleazyng"
# Application sources, dependency pins, and native toolchain inputs are excluded.
RECOVERY_FILES = frozenset({
    "scripts/prepare_native_downloads.py", "scripts/test_prepare_native_downloads.py",
    "scripts/launch_queued_apple_jit_jobs.py", "scripts/checks/test_apple_jit_queue.py",
    "scripts/retain_macos_app.py", "scripts/test_retain_macos_app.py",
    ".github/workflows/build.yml", ".github/workflows/ci.yml", "CHANGELOG.md",
    "docs/maintainers/full-release-build.md", "docs/maintainers/apple-jit-runner.md",
    "scripts/launch_apple_jit_runner.sh",
    "scripts/release_all_platforms.py",
    "scripts/prepare_gradle_repositories.py", "scripts/gradle/plezyng-maven-mirror.init.gradle",
    "scripts/checks/test_prepare_gradle_repositories.py", "scripts/recover_release_platforms.py",
    "scripts/checks/test_recover_release_platforms.py", "scripts/checks/check_build_workflow.py",
    "scripts/checks/test_check_build_workflow.py", "scripts/checks/test_release_ci_gate.py",
    "tools/webos/build_ipk.sh", "tools/webos/tests/test_source_ndk_environment.py",
    "scripts/recover_macos_app.py", "scripts/test_recover_macos_app.py",
    "scripts/apple/prepare_macos_app_for_signing.py", "scripts/apple/test_prepare_macos_app_for_signing.py",
    "scripts/checks/test_macos_validation_request.py", "scripts/checks/test_macos_packaging_recovery.py",
})
REBUILT_JOBS = frozenset({"build-android", "Build WebOS TV package (ARMv7)"})
REQUIRED_JOBS = (
    "Validate release request",
    "Build tvOS developer package (arm64)", "build-ios", "build-macos",
    "Build Linux (x64)", "Build Linux (arm64)",
    "Build Windows (x64)", "Build Windows (arm64)", "package-windows",
    "Build Samsung Tizen TV package (ARM) / validate",
    "Build Samsung Tizen TV package (ARM) / package",
)
ARTIFACTS = {
    "pleazyng-tizen-arm-experimental": "tizen", "ios-ipa": "ios-ipa", "tvos-ipa": "tvos-ipa",
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


def immutable_ci_source(repository, source_sha, version):
    """Resolve exact app CI only after a complete infrastructure-only comparison."""
    if repository != REPOSITORY or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise RecoveryError("Invalid immutable CI source identity")
    from release_all_platforms import RELEASE_TAG_REUSE_ALLOWLIST
    obj = api(f"repos/{repository}/git/ref/tags/v{version}")["object"]
    for _ in range(8):
        if not re.fullmatch(r"[a-f0-9]{40}", obj.get("sha", "")):
            raise RecoveryError("Invalid immutable CI tag object")
        if obj.get("type") == "commit":
            break
        if obj.get("type") != "tag":
            raise RecoveryError("Invalid immutable CI tag type")
        obj = api(f"repos/{repository}/git/tags/{obj['sha']}")["object"]
    else:
        raise RecoveryError("Immutable CI tag chain is too long")
    tag_sha = obj["sha"]
    if source_sha != tag_sha:
        comparison = api(f"repos/{repository}/compare/{tag_sha}...{source_sha}")
        files = comparison.get("files")
        if (comparison.get("status") not in {"ahead", "identical"}
            or comparison.get("merge_base_commit", {}).get("sha") != tag_sha
            or not isinstance(files, list) or len(files) >= 300
            or any(path not in RELEASE_TAG_REUSE_ALLOWLIST for entry in files
                   for path in (entry.get("filename"), entry.get("previous_filename")) if path)):
            raise RecoveryError("Cannot reuse tag CI: application/native inputs changed or comparison incomplete")
    return tag_sha


def ci_proof(repository, source_sha, version=None):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True)
        token = result.stdout.strip()
    ci_source = immutable_ci_source(repository, source_sha, version) if version else source_sha
    gate = release_ci._manifest_gate()
    run = release_ci._latest_run(token, repository, ci_source, gate)
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise RecoveryError("The source release commit has no successful exact-SHA CI run.")
    errors = release_ci._check_jobs(token, repository, run, gate)
    if errors:
        raise RecoveryError("Source CI is incomplete: " + "; ".join(errors))
    return {"ci_run_id": run["id"], "ci_run_url": run["html_url"], "ci_source_sha": ci_source}


def verify_webos_transport_patch(repository, source_sha, head_sha, files):
    path = "scripts/prepare_native_downloads.py"
    if not any(entry.get("filename") == path for entry in files):
        return
    fingerprints = []
    for revision in (source_sha, head_sha):
        response = api(f"repos/{repository}/contents/{path}?ref={revision}")
        if response.get("encoding") != "base64":
            raise RecoveryError("Native transport source evidence is incomplete")
        tree = ast.parse(base64.b64decode(response["content"]).decode())
        tree.body = [node for node in tree.body
                     if not (isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in {"prepare_webos_python", "prepare_apple_pdfium"})
                     and ast.dump(node) != ast.dump(ast.parse('PRODUCERS.add("espresso3389/pdfium-xcframework")').body[0])]
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == "main":
                for child in ast.walk(node):
                    if isinstance(child, ast.If):
                        child.body = [statement for statement in child.body if not (isinstance(statement, ast.If)
                                      and ast.dump(statement.test) == ast.dump(ast.parse('args.sqlite_platform in {"ios", "macos"}', mode="eval").body)
                                      and len(statement.body) == 1 and isinstance(statement.body[0], ast.Expr)
                                      and isinstance(statement.body[0].value, ast.Call)
                                      and isinstance(statement.body[0].value.func, ast.Name)
                                      and statement.body[0].value.func.id == "prepare_apple_pdfium")]
        # Printing verified-download diagnostics to stderr cannot change native
        # inputs. Retain every other print argument and expression in the proof.
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print":
                node.keywords = [kw for kw in node.keywords if not (kw.arg == "file" and ast.dump(kw.value) == ast.dump(ast.Attribute(value=ast.Name(id="sys", ctx=ast.Load()), attr="stderr", ctx=ast.Load())))]
        fingerprints.append(ast.dump(tree, include_attributes=False))
    if fingerprints[0] != fingerprints[1]:
        raise RecoveryError("Native download pins or non-webOS transport code changed; refusing artifact reuse")


def verify_source_run(run_id, head_sha, version, repository=REPOSITORY, *, allow_pending=False, rebuild_linux=False, rebuild_macos=False, require_homebrew_cask=False):
    if repository != REPOSITORY or not str(run_id).isdigit() or not re.fullmatch(r"[0-9a-f]{40}", head_sha):
        raise RecoveryError("Recovery requires the Pleazyng repository and exact run/commit identities.")
    source = api(f"repos/{repository}/actions/runs/{run_id}")
    source_sha = source.get("head_sha", "")
    pending = allow_pending and source.get("status") in {"queued", "in_progress", "waiting", "pending"}
    if ((source.get("status") != "completed" and not pending) or source.get("event") != "workflow_dispatch"
        or source.get("head_branch") != "main"
        or source.get("head_repository", {}).get("full_name") != repository
        or source.get("path", "").split("@")[0] != ".github/workflows/build.yml"
        or source.get("display_title") != f"action:release:pool:private:tag:v{version}"
        or not re.fullmatch(r"[0-9a-f]{40}", source_sha)):
        raise RecoveryError("Source must be a trusted-main release run for this version, completed before reuse.")
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
    verify_webos_transport_patch(repository, source_sha, head_sha, changed)
    jobs = collection(f"repos/{repository}/actions/runs/{run_id}/jobs", "jobs")
    pending_jobs = []
    required_jobs = tuple(name for name in REQUIRED_JOBS if not (rebuild_linux and name.startswith("Build Linux (")) and not (rebuild_macos and name == "build-macos"))
    rebuilt_jobs = set(REBUILT_JOBS) | ({"Build Linux (x64)", "Build Linux (arm64)"} if rebuild_linux else set()) | ({"build-macos"} if rebuild_macos else set())
    for name in required_jobs:
        matches = [job for job in jobs if job.get("name") == name]
        if len(matches) == 1 and pending and matches[0].get("status") in {"queued", "in_progress", "waiting", "pending", "requested"} and not matches[0].get("conclusion"):
            pending_jobs.append(name)
            continue
        if len(matches) != 1 or matches[0].get("status") != "completed" or matches[0].get("conclusion") != "success":
            raise RecoveryError(f"Source platform job is not uniquely successful: {name}")
    failures = [job.get("name") for job in jobs
                if job.get("conclusion") in {"failure", "cancelled", "timed_out"}
                and job.get("name") not in rebuilt_jobs]
    if failures:
        raise RecoveryError("Other source jobs failed: " + ", ".join(failures))
    android = [job for job in jobs if job.get("name") == "build-android"]
    android_pending = len(android) == 1 and pending and android[0].get("status") in {"queued", "in_progress", "waiting", "pending", "requested"} and not android[0].get("conclusion")
    if android_pending:
        pending_jobs.append("build-android")
    elif len(android) != 1 or android[0].get("status") != "completed" or android[0].get("conclusion") not in {"failure", "success"}:
        raise RecoveryError("Recovery requires exactly one completed Android build.")
    if any(job.get("name") == "create-release" and job.get("conclusion") != "skipped"
           and not (pending and job.get("status") in {"queued", "waiting", "pending"} and not job.get("conclusion"))
           for job in jobs):
        raise RecoveryError("The source run already attempted release creation; inspect its side effects.")
    macos = next(job for job in jobs if job.get("name") == "build-macos")
    cask_qualified = all(any(step.get("name") == name and step.get("status") == "completed" and step.get("conclusion") == "success" for step in macos.get("steps", []))
                         for name in ("Notarize Application", "Verify Gatekeeper acceptance for Homebrew Cask"))
    if require_homebrew_cask and not rebuild_macos and macos.get("status") == "completed" and not cask_qualified:
        raise RecoveryError("Reusable Mac build lacks successful notarization and Homebrew Gatekeeper qualification")
    return {"source_run_id": int(run_id), "source_sha": source_sha, "head_sha": head_sha,
            "version": version, "reused_jobs": list(required_jobs),
            "rebuilt_jobs": sorted(rebuilt_jobs), "rebuild_linux": rebuild_linux, "rebuild_macos": rebuild_macos,
            "macos_cask_qualified": cask_qualified,
            "platforms_complete": source.get("status") == "completed", "pending_jobs": pending_jobs,
            **ci_proof(repository, source_sha, version)}


def verify_macos_packaging_recovery(run_id, macos_run, head_sha, version, repository=REPOSITORY):
    """Replace only failed Mac packaging; require every original platform build."""
    import base64
    from recover_macos_app import build_contract
    if repository != REPOSITORY or not all(str(v).isdigit() for v in (run_id, macos_run)) or not re.fullmatch(r"[0-9a-f]{40}", head_sha):
        raise RecoveryError("Mac recovery requires exact trusted run and source identities.")
    source = api(f"repos/{repository}/actions/runs/{run_id}")
    native = api(f"repos/{repository}/actions/runs/{macos_run}")
    for run in (source, native):
        if (run.get("status") != "completed" or run.get("event") != "workflow_dispatch"
            or run.get("head_branch") != "main" or run.get("head_repository", {}).get("full_name") != repository
            or run.get("path", "").split("@")[0] != ".github/workflows/build.yml"):
            raise RecoveryError("Mac recovery requires completed trusted-main workflow runs.")
    if source.get("display_title") != f"action:release:pool:private:tag:v{version}" or native.get("conclusion") != "success":
        raise RecoveryError("Mac packaging recovery must be successful and match the original versioned release.")
    source_sha = source["head_sha"]
    for target in dict.fromkeys((head_sha, native["head_sha"])):
        comparison = api(f"repos/{repository}/compare/{source_sha}...{target}")
        files = comparison.get("files")
        if (comparison.get("status") not in {"ahead", "identical"}
            or comparison.get("merge_base_commit", {}).get("sha") != source_sha
            or not isinstance(files, list) or len(files) >= 300
            or any(p not in RECOVERY_FILES for entry in files
                   for p in (entry.get("filename"), entry.get("previous_filename")) if p)):
            raise RecoveryError("Mac recovery changed application or native inputs, or comparison evidence is incomplete.")
    contracts = []
    for revision in dict.fromkeys((source_sha, native["head_sha"], head_sha)):
        content = api(f"repos/{repository}/contents/.github/workflows/build.yml?ref={revision}")
        contracts.append(build_contract(base64.b64decode(content["content"]).decode()))
    if any(c != contracts[0] for c in contracts):
        raise RecoveryError("Mac compiler configuration differs from the retained compilation.")
    jobs = collection(f"repos/{repository}/actions/runs/{run_id}/jobs", "jobs")
    required = tuple(name for name in REQUIRED_JOBS if name != "build-macos") + ("build-android", "Build WebOS TV package (ARMv7)")
    for name in required:
        matches = [j for j in jobs if j.get("name") == name]
        if len(matches) != 1 or matches[0].get("status") != "completed" or matches[0].get("conclusion") != "success":
            raise RecoveryError(f"Original platform must be uniquely successful: {name}")
    macs = [j for j in jobs if j.get("name") == "build-macos"]
    if len(macs) != 1 or macs[0].get("conclusion") != "failure":
        raise RecoveryError("Expected exactly one failed Mac packaging job.")
    mac = api(f"repos/{repository}/actions/jobs/{macs[0]['id']}")
    if not any(s.get("name") == "Build macOS" and s.get("conclusion") == "success" for s in mac.get("steps", [])):
        raise RecoveryError("The original native application compilation did not succeed.")
    if any(j.get("conclusion") in {"failure", "cancelled", "timed_out"} and j.get("name") != "build-macos" for j in jobs):
        raise RecoveryError("Another original platform failed; do not assemble a partial release.")
    if any(j.get("name") == "create-release" and j.get("conclusion") != "skipped" for j in jobs):
        raise RecoveryError("Original run attempted release creation; inspect side effects.")
    recovered_jobs = collection(f"repos/{repository}/actions/runs/{macos_run}/jobs", "jobs")
    recovered = [j for j in recovered_jobs if j.get("name") == "build-macos" and j.get("conclusion") == "success"]
    if len(recovered) != 1:
        raise RecoveryError("Mac replacement job is missing or ambiguous.")
    recovered_job = api(f"repos/{repository}/actions/jobs/{recovered[0]['id']}")
    required_steps = ("Recover verified native macOS compilation", "Import Code Signing Certificate",
                      "Sign Application", "Verify Signature", "Notarize Application",
                      "Verify Gatekeeper acceptance for Homebrew Cask", "Sign DMG for Sparkle (EdDSA)",
                      "Attest macOS DMG", "Attest recovered macOS compilation provenance", "Upload macOS DMG")
    for name in required_steps:
        if not any(s.get("name") == name and s.get("conclusion") == "success" for s in recovered_job.get("steps", [])):
            raise RecoveryError(f"Recovered Mac package lacks successful qualification: {name}")
    return {"profile": "macos-packaging", "source_run_id": int(run_id), "source_sha": source_sha,
            "head_sha": head_sha, "version": version, "reused_jobs": list(required),
            "rebuilt_jobs": [], "recovered_jobs": ["build-macos"], "platforms_complete": True,
            "pending_jobs": [], "excluded_optional_jobs": [], "compiled_macos_job": mac["id"],
            "macos_source": {"source_run_id": int(macos_run), "source_sha": native["head_sha"],
                             "job_id": recovered_job["id"]},
            "android_source": {"source_run_id": int(run_id), "source_sha": source_sha},
            **ci_proof(repository, source_sha, version)}


def verify_macos_receipt(receipt, proof):
    if (receipt.get("compiled_source") != proof["source_sha"]
        or receipt.get("compiled_run") != proof["source_run_id"]
        or receipt.get("compiled_job") != proof["compiled_macos_job"]
        or receipt.get("packaging_workflow_source") != proof["macos_source"]["source_sha"]
        or receipt.get("version", "").split("+", 1)[0] != proof["version"]
        or receipt.get("application_inputs_unchanged") is not True
        or receipt.get("compilation_reused") is not True
        or not re.fullmatch(r"[0-9a-f]{64}", receipt.get("recovered_app_tree_sha256", ""))):
        raise RecoveryError("Mac compilation receipt differs from verified GitHub evidence.")


def wait_for_source_run(run_id, head_sha, version, seconds, **options):
    deadline = time.monotonic() + seconds
    while True:
        proof = verify_source_run(run_id, head_sha, version, allow_pending=True, **options)
        if proof["platforms_complete"]:
            return proof
        if time.monotonic() >= deadline:
            raise RecoveryError("Timed out waiting for successful source platform builds; no artifacts reused.")
        print(f"Source run {run_id} is still building: {', '.join(proof['pending_jobs'])}.", flush=True)
        time.sleep(min(60, max(0, deadline - time.monotonic())))


def verify_android_run(run_id, head_sha, version, repository=REPOSITORY, *, allow_pending=False):
    if repository != REPOSITORY or not str(run_id).isdigit() or not re.fullmatch(r"[0-9a-f]{40}", head_sha):
        raise RecoveryError("Android recovery requires an exact Pleazyng run identity.")
    source = api(f"repos/{repository}/actions/runs/{run_id}")
    source_sha = source.get("head_sha", "")
    pending = allow_pending and source.get("status") in {"queued", "in_progress", "waiting", "pending"}
    if ((source.get("status") != "completed" and not pending) or source.get("event") != "workflow_dispatch"
        or source.get("head_branch") != "main"
        or source.get("head_repository", {}).get("full_name") != repository
        or source.get("path", "").split("@")[0] != ".github/workflows/build.yml"
        or source.get("display_title") != f"action:release:pool:private:tag:v{version}"
        or not re.fullmatch(r"[0-9a-f]{40}", source_sha)):
        raise RecoveryError("Android source must be a completed trusted-main release for this version.")
    comparison = api(f"repos/{repository}/compare/{source_sha}...{head_sha}")
    files = comparison.get("files")
    if (comparison.get("status") not in {"ahead", "identical"}
        or comparison.get("merge_base_commit", {}).get("sha") != source_sha
        or not isinstance(files, list) or len(files) >= 300
        or any(path not in RECOVERY_FILES for entry in files
               for path in (entry.get("filename"), entry.get("previous_filename")) if path)):
        raise RecoveryError("Android product input equivalence could not be proven.")
    verify_webos_transport_patch(repository, source_sha, head_sha, files)
    jobs = collection(f"repos/{repository}/actions/runs/{run_id}/jobs", "jobs")
    android = [job for job in jobs if job.get("name") == "build-android"]
    android_pending = len(android) == 1 and pending and android[0].get("status") in {"queued", "in_progress", "waiting", "pending", "requested"} and not android[0].get("conclusion")
    if not android_pending and (len(android) != 1 or android[0].get("status") != "completed" or android[0].get("conclusion") != "success"):
        raise RecoveryError("The reused Android job must be uniquely successful.")
    if any(job.get("name") == "create-release" and job.get("conclusion") != "skipped"
           and not (pending and job.get("status") in {"queued", "waiting", "pending"} and not job.get("conclusion")) for job in jobs):
        raise RecoveryError("Android source already attempted publication; inspect its side effects.")
    return {"source_run_id": int(run_id), "source_sha": source_sha, "job_id": android[0]["id"],
            **({"pending": True} if android_pending else {})}


def compose_proof(proof, android_run=None, include_webos_build=True):
    if proof.get("profile") == "macos-packaging":
        if not include_webos_build or (android_run and str(android_run) != str(proof["source_run_id"])):
            raise RecoveryError("Mac packaging recovery requires every original platform without substitution or omission.")
        return proof
    if "build-android" in proof.get("pending_jobs", []) and not android_run:
        raise RecoveryError("A pending Android source requires explicit reuse; do not launch a duplicate build")
    rebuilt = set(proof.get("rebuilt_jobs", REBUILT_JOBS))
    if android_run:
        proof = {**proof, "android_source": verify_android_run(android_run, proof["head_sha"], proof["version"], allow_pending=not proof.get("platforms_complete", True))}
        rebuilt.remove("build-android")
    if not include_webos_build:
        rebuilt.remove("Build WebOS TV package (ARMv7)")
    return {**proof, "rebuilt_jobs": sorted(rebuilt),
            "excluded_optional_jobs": [] if include_webos_build else ["Build WebOS TV package (ARMv7)"]}


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
    wanted = {name: folder for name, folder in ARTIFACTS.items() if not (proof.get("rebuild_linux") and name.startswith("linux-")) and not (proof.get("rebuild_macos") and name == "macos-dmg")}
    if any(item.get("name") == "windows-msix" for item in inventory):
        wanted["windows-msix"] = "windows-msix"
    inventories = {run_id: inventory}
    if proof.get("android_source"):
        android = proof["android_source"]
        inventories[android["source_run_id"]] = collection(
            f"repos/{repository}/actions/runs/{android['source_run_id']}/artifacts", "artifacts")
        wanted["android-apk"] = "android-apk"
    if proof.get("macos_source"):
        macos = proof["macos_source"]
        inventories[macos["source_run_id"]] = collection(
            f"repos/{repository}/actions/runs/{macos['source_run_id']}/artifacts", "artifacts")
        wanted["webos-ipk"] = "webos"
    records = []
    for name, folder in wanted.items():
        source = (proof["android_source"] if name == "android-apk" else
                  proof["macos_source"] if name == "macos-dmg" and proof.get("macos_source") else proof)
        artifact_run = source["source_run_id"]
        matches = [item for item in inventories[artifact_run] if item.get("name") == name and not item.get("expired")]
        if len(matches) != 1:
            raise RecoveryError(f"Reusable artifact is missing or ambiguous: {name}")
        item = matches[0]
        identity = item.get("workflow_run", {})
        digest = item.get("digest") or ""
        if (identity.get("id") != artifact_run or identity.get("head_sha") != source["source_sha"]
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
            raise RecoveryError(f"Artifact lacks matching run, source, or digest evidence: {name}")
        with tempfile.TemporaryDirectory(prefix="pleazyng-release-artifact-") as scratch:
            archive = Path(scratch) / "artifact.zip"
            with archive.open("wb") as output:
                result = subprocess.run(["gh", "api", "--allow-escape-sequences",
                                         f"repos/{repository}/actions/artifacts/{item['id']}/zip"], stdout=output)
            with archive.open("rb") as downloaded:
                actual_digest = hashlib.file_digest(downloaded, "sha256").hexdigest()
            if result.returncode or actual_digest != digest[7:]:
                raise RecoveryError(f"Reusable artifact download/digest verification failed: {name}")
            extract_verified(archive, destination / folder)
            if name == "macos-dmg" and proof.get("macos_source"):
                verify_macos_receipt(json.loads((destination / folder / "macos-compilation-recovery.json").read_text()), proof)
        records.append({"name": name, "artifact_id": item["id"], "digest": digest,
                        "source_run_id": artifact_run, "source_sha": source["source_sha"]})
        print(f"Recovered verified {name} from run {artifact_run}.", flush=True)
    proof = {**proof, "artifacts": records}
    (destination / "platform-reuse-provenance.json").write_text(json.dumps(proof, indent=2) + "\n")
    return proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_run")
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--download", type=Path)
    parser.add_argument("--macos-run", help="Reuse a qualified signing-only Mac recovery after every original platform succeeds.")
    parser.add_argument("--rebuild-linux", action="store_true", help="Rebuild both Linux architectures instead of reusing their artifacts")
    parser.add_argument("--rebuild-macos", action="store_true", help="Build and qualify a fresh Mac package instead of reusing a failed Mac job")
    parser.add_argument("--require-homebrew-cask", action="store_true", help="Require the reused Mac notarization and Gatekeeper checks")
    parser.add_argument("--android-run", help="Reuse a separately successful Android release build.")
    parser.add_argument("--skip-webos-build", action="store_true", help="Exclude the non-public experimental WebOS candidate.")
    parser.add_argument("--allow-building", action="store_true", help="Preflight only: native jobs may still be running.")
    parser.add_argument("--wait-for-source", type=int, default=0, help="Wait up to this many seconds before recovering completed outputs.")
    args = parser.parse_args()
    if args.macos_run and (args.rebuild_macos or args.rebuild_linux):
        parser.error("Signing-only Mac recovery cannot be combined with fresh platform rebuilding")
    if args.allow_building and args.download:
        parser.error("--allow-building is only a preflight; downloads require completed successful platform jobs")
    if not 0 <= args.wait_for_source <= 10800:
        parser.error("--wait-for-source must be between 0 and 10800 seconds")
    proof = (verify_macos_packaging_recovery(args.source_run, args.macos_run, args.head_sha, args.version)
             if args.macos_run else
             wait_for_source_run(args.source_run, args.head_sha, args.version, args.wait_for_source, rebuild_linux=args.rebuild_linux, rebuild_macos=args.rebuild_macos, require_homebrew_cask=args.require_homebrew_cask)
             if args.wait_for_source else
             verify_source_run(args.source_run, args.head_sha, args.version, allow_pending=args.allow_building, rebuild_linux=args.rebuild_linux, rebuild_macos=args.rebuild_macos, require_homebrew_cask=args.require_homebrew_cask))
    proof = compose_proof(proof, args.android_run, not args.skip_webos_build)
    if args.download:
        proof = download_platforms(proof, args.download)
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"source_sha={proof['source_sha']}\nci_run_id={proof['ci_run_id']}\n")
            if proof.get("android_source"):
                output.write(f"android_source_sha={proof['android_source']['source_sha']}\n")
    print(json.dumps(proof, indent=2))


if __name__ == "__main__":
    main()
