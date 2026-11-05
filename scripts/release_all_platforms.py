#!/usr/bin/env python3
"""Orchestrate a native dependency refresh and the complete PlezyNG release.

This is a local control-plane command. PlezyNG 3.0.0 uses compatible
GitHub-hosted runners by default and private JIT for Apple, WebOS storage, or
other private-resource requirements. It uses the operator's authenticated
`gh` CLI session and never copies credentials into the repos.
With --publish, it promotes the verified draft and runs every configured
package/store publication workflow from main, sequentially and idempotently.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLEZY_REPO = "snapetech-org/PlezyNG"
MPV_REPO = "snapetech-org/mpv-build"
MPV_WORKFLOW = "publish.yml"
CI_WORKFLOW = "ci.yml"
RELEASE_WORKFLOW = "build.yml"
NATIVE_GROUPS = ("apple", "android", "linux", "windows")
FFMPEG_SIGNING_FINGERPRINT = "FCF986EA15E6E293A5644F10B4322F04D67658D8"
DOWNLOAD_ATTEMPTS = 4
DOWNLOAD_RETRY_INITIAL_DELAY_SECONDS = 1
APPLE_JIT_EVIDENCE_ROOT: Path | None = None
RELEASE_TAG_REUSE_ALLOWLIST = frozenset({
    ".github/actions/setup-flutter-windows/action.yml",
    ".github/workflows/build.yml",
    ".github/workflows/ci.yml",
    ".github/workflows/tizen.yml",
    "AGENTS.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "docs/games/VALIDATION.md",
    "docs/maintainers/apple-jit-runner.md",
    "docs/maintainers/branch-consolidation-2026-10-27.md",
    "docs/maintainers/capability-manifest.json",
    "docs/maintainers/dv-platform-buildout.md",
    "docs/maintainers/full-release-build.md",
    "docs/maintainers/release-channels.md",
    "docs/maintainers/tizen-tv.md",
    "docs/plezyng/subtitles/PLAN.md",
    "native/games/apple/SteamAppleSinkTests.mm",
    "scripts/checks/check_build_workflow.py",
    "scripts/checks/test_check_build_workflow.py",
    "scripts/checks/test_release_ci_gate.py",
    "scripts/checks/test_apple_jit_queue.py",
    "scripts/launch_apple_jit_runner.sh",
    "scripts/cleanup_apple_jit_derived_data.py",
    "scripts/launch_queued_apple_jit_jobs.py",
    "scripts/prepare_android_sdk.py",
    "scripts/prepare_gradle_repositories.py",
    "scripts/gradle/plezyng-maven-mirror.init.gradle",
    "scripts/checks/test_prepare_gradle_repositories.py",
    "scripts/recover_release_platforms.py",
    "scripts/checks/test_recover_release_platforms.py",
    "scripts/release_all_platforms.py",
    "scripts/refresh_apple_spm.sh",
    "tools/reader-tests/README.md",
    "tools/webos/compatibility.json",
    "tools/webos/build_ipk.sh",
    "tools/webos/tests/test_source_ndk_environment.py",
})


class ReleaseError(RuntimeError):
    pass


def command(args: list[str], *, cwd: Path | None = None, capture: bool = False,
            check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess[str]:
    if not quiet:
        print("+", " ".join(str(part) for part in args), flush=True)
    result = subprocess.run(
        [str(part) for part in args],
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )
    if check and result.returncode:
        detail = (result.stderr or result.stdout or "").strip() if capture else ""
        raise ReleaseError(f"command failed ({result.returncode}): {args[0]} {args[1:]}\n{detail}")
    return result


def gh_json(*args: str) -> object:
    result = command(["gh", *args], capture=True)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseError(f"GitHub CLI returned invalid JSON for: {' '.join(args)}") from error


def workflow_runs(repo: str, workflow: str, *, ref: str | None = None) -> list[dict]:
    args = [
        "run", "list", "--repo", repo, "--workflow", workflow, "--limit", "40",
        "--json", "databaseId,status,conclusion,headSha,headBranch,event,createdAt,displayTitle,url",
    ]
    if ref:
        args.extend(["--branch", ref])
    result = command(["gh", *args], capture=True)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseError(f"Could not read workflow runs for {repo}/{workflow}") from error


def matching_run(
    repo: str,
    workflow: str,
    sha: str,
    *,
    ref: str | None = None,
    expected_title: str | None = None,
) -> dict | None:
    runs = workflow_runs(repo, workflow, ref=ref)
    matches = [
        run for run in runs
        if run.get("headSha") == sha
        and run.get("event") == "workflow_dispatch"
        and (expected_title is None or run.get("displayTitle") == expected_title)
    ]
    matches.sort(key=lambda run: run.get("createdAt", ""), reverse=True)
    return matches[0] if matches else None


def wait_for_run(repo: str, run: dict, purpose: str) -> dict:
    run_id = str(run["databaseId"])
    print(f"\n{purpose}: {run.get('url', f'https://github.com/{repo}/actions/runs/{run_id}')}", flush=True)
    apple_controller: subprocess.Popen[bytes] | None = None
    if repo == PLEZY_REPO:
        if APPLE_JIT_EVIDENCE_ROOT is None:
            raise ReleaseError("No task scratch path is configured for Apple JIT evidence.")
        # Platform jobs appear only after the workflow's validation job passes.
        # Start discovery now so later queued Apple jobs cannot be missed.
        print("Starting continuous Apple JIT job discovery for this run.", flush=True)
        apple_controller = subprocess.Popen(
            [sys.executable, str(ROOT / "scripts/launch_queued_apple_jit_jobs.py"),
             run_id, "--evidence-dir", str(APPLE_JIT_EVIDENCE_ROOT)],
            cwd=ROOT,
        )

    watcher = subprocess.Popen(
        ["gh", "run", "watch", run_id, "--repo", repo, "--interval", "30", "--exit-status"],
        cwd=ROOT,
    )
    while watcher.poll() is None:
        if apple_controller is not None:
            controller_code = apple_controller.poll()
            if controller_code not in (None, 0):
                watcher.terminate()
                watcher.wait(timeout=30)
                raise ReleaseError(
                    f"Apple JIT queue controller failed with exit code {controller_code}; "
                    "the GitHub workflow was left running and was not canceled."
                )
        time.sleep(3)
    watch_code = watcher.wait()
    if apple_controller is not None:
        controller_code = apple_controller.wait()
        if controller_code:
            raise ReleaseError(
                f"Apple JIT queue controller failed with exit code {controller_code}; "
                "inspect its per-run evidence before retrying."
            )
    if watch_code:
        raise ReleaseError(f"gh run watch exited with status {watch_code} for run {run_id}.")
    updated = gh_json("run", "view", run_id, "--repo", repo,
                      "--json", "databaseId,status,conclusion,headSha,headBranch,event,url,jobs")
    if updated.get("status") != "completed" or updated.get("conclusion") != "success":
        raise ReleaseError(f"{purpose} did not succeed: {updated.get('conclusion') or updated.get('status')}")
    return updated


def dispatch(repo: str, workflow: str, ref: str, fields: dict[str, str], purpose: str,
             *, expected_title: str | None = None, expected_sha: str | None = None) -> dict:
    before = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=10)
    args = ["gh", "workflow", "run", workflow, "--repo", repo, "--ref", ref]
    for key, value in fields.items():
        args.extend(["--field", f"{key}={value}"])
    command(args)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        for run in workflow_runs(repo, workflow, ref=ref):
            if run.get("event") != "workflow_dispatch":
                continue
            if run.get("createdAt", "") < before.isoformat().replace("+00:00", "Z"):
                continue
            if expected_title and run.get("displayTitle") != expected_title:
                continue
            if expected_sha and run.get("headSha") != expected_sha:
                raise ReleaseError(
                    f"{purpose} was dispatched on {ref}, but GitHub resolved it to "
                    f"{run.get('headSha') or 'an unknown commit'} instead of expected "
                    f"{expected_sha}. The branch moved during dispatch; no other run was reused."
                )
            return wait_for_run(repo, run, purpose)
        time.sleep(5)
    raise ReleaseError(f"Workflow dispatch succeeded, but its run was not visible: {repo}/{workflow} on {ref}")


def active_run(repo: str, workflow: str, *, ref: str) -> dict | None:
    active_states = {"queued", "in_progress", "waiting", "requested", "pending"}
    for run in workflow_runs(repo, workflow, ref=ref):
        if run.get("status") in active_states:
            return run
    return None


def run_has_successful_job(repo: str, run: dict, job_name: str) -> bool:
    jobs = run.get("jobs")
    if not isinstance(jobs, list):
        run_id = run.get("databaseId")
        if not isinstance(run_id, int):
            raise ReleaseError("Cannot inspect a workflow run without its numeric run ID.")
        details = gh_json("run", "view", str(run_id), "--repo", repo, "--json", "jobs")
        jobs = details.get("jobs") if isinstance(details, dict) else None
    if not isinstance(jobs, list):
        raise ReleaseError(f"Could not inspect jobs for workflow run {run.get('databaseId')}.")
    matches = [job for job in jobs if isinstance(job, dict) and job.get("name") == job_name]
    return (
        len(matches) == 1
        and matches[0].get("status") == "completed"
        and matches[0].get("conclusion") == "success"
    )


def run_has_successful_step(repo: str, run: dict, job_name: str, step_name: str) -> bool:
    jobs = run.get("jobs")
    if not isinstance(jobs, list):
        run_id = run.get("databaseId")
        if not isinstance(run_id, int):
            raise ReleaseError("Cannot inspect a workflow run without its numeric run ID.")
        details = gh_json("api", f"repos/{repo}/actions/runs/{run_id}/jobs")
        jobs = details.get("jobs") if isinstance(details, dict) else None
    if not isinstance(jobs, list):
        raise ReleaseError(f"Could not inspect jobs for workflow run {run.get('databaseId')}.")
    matches = [job for job in jobs if isinstance(job, dict) and job.get("name") == job_name]
    if len(matches) != 1 or not isinstance(matches[0].get("steps"), list):
        return False
    return any(
        isinstance(step, dict)
        and step.get("name") == step_name
        and step.get("status") == "completed"
        and step.get("conclusion") == "success"
        for step in matches[0]["steps"]
    )


def download(url: str, destination: Path) -> None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in {"ffmpeg.org", "www.ffmpeg.org"}:
        raise ReleaseError(f"Refusing non-official FFmpeg source URL: {url}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "PlezyNG-release-orchestrator/1"})
    partial = destination.with_name(destination.name + ".part")
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=90) as response, partial.open("wb") as output:
                shutil.copyfileobj(response, output)
            partial.replace(destination)
            return
        except urllib.error.HTTPError as error:
            error.close()
            partial.unlink(missing_ok=True)
            if error.code not in (408, 429) and not 500 <= error.code < 600:
                raise
            if attempt == DOWNLOAD_ATTEMPTS:
                raise
        except urllib.error.URLError as error:
            partial.unlink(missing_ok=True)
            if not isinstance(error.reason, (TimeoutError, ConnectionError)):
                raise
            if attempt == DOWNLOAD_ATTEMPTS:
                raise
        except (TimeoutError, ConnectionError):
            partial.unlink(missing_ok=True)
            if attempt == DOWNLOAD_ATTEMPTS:
                raise

        delay = DOWNLOAD_RETRY_INITIAL_DELAY_SECONDS * (2 ** (attempt - 1))
        print(
            f"Transient official FFmpeg download failure for {parsed.path} "
            f"(attempt {attempt}/{DOWNLOAD_ATTEMPTS}); retrying in {delay}s.",
            file=sys.stderr,
            flush=True,
        )
        time.sleep(delay)


def verified_ffmpeg_source(
    version_pin: str,
    scratch: Path,
    source_cache: Path | None = None,
) -> tuple[str, str]:
    match = re.fullmatch(r"n(\d+\.\d+\.\d+)", version_pin)
    if not match:
        raise ReleaseError(f"Expected a stable FFmpeg release tag such as n9.0.2, got {version_pin!r}")
    version = match.group(1)
    archive_name = f"ffmpeg-{version}.tar.xz"
    archive = scratch / archive_name
    signature = scratch / f"{archive_name}.asc"
    key = scratch / "ffmpeg-devel.asc"
    if source_cache is None:
        download(f"https://ffmpeg.org/releases/{archive_name}", archive)
        download(f"https://ffmpeg.org/releases/{archive_name}.asc", signature)
        download("https://ffmpeg.org/ffmpeg-devel.asc", key)
    else:
        cache = source_cache.expanduser().resolve()
        scratch.mkdir(parents=True, exist_ok=True)
        for name, destination in (
            (archive_name, archive),
            (f"{archive_name}.asc", signature),
            ("ffmpeg-devel.asc", key),
        ):
            cached = cache / name
            if not cached.is_file():
                raise ReleaseError(f"FFmpeg source cache is missing required file: {name}")
            shutil.copyfile(cached, destination)
    if shutil.which("gpg") is None:
        raise ReleaseError("gpg is required to verify the official FFmpeg release signature.")

    keyring = scratch / "gnupg"
    keyring.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(keyring, 0o700)
    command(["gpg", "--homedir", keyring, "--batch", "--import", key])
    verified = command(
        ["gpg", "--homedir", keyring, "--batch", "--status-fd", "1", "--verify", signature, archive],
        capture=True,
    )
    fingerprints = [
        line.split()[2]
        for line in verified.stdout.splitlines()
        if line.startswith("[GNUPG:] VALIDSIG ") and len(line.split()) > 2
    ]
    if FFMPEG_SIGNING_FINGERPRINT not in fingerprints:
        raise ReleaseError(
            "FFmpeg archive signature was not made by the pinned official signing key "
            f"{FFMPEG_SIGNING_FINGERPRINT}; found {fingerprints!r}"
        )
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    print(f"Verified {archive_name} with FFmpeg release key {FFMPEG_SIGNING_FINGERPRINT}; SHA-256 {digest}")
    return version, digest


def update_android_ffmpeg_pin(repo: Path, version: str, digest: str) -> bool:
    path = repo / "android/app/build.gradle.kts"
    source = path.read_text(encoding="utf-8")
    updated = source

    def replace_pin(pattern: str, value: str) -> None:
        nonlocal updated
        updated, count = re.subn(
            pattern,
            lambda match: f'{match.group(1)}{value}{match.group(2)}',
            updated,
        )
        if count != 1:
            raise ReleaseError(f"Expected one Android FFmpeg pin in {path}, found {count}: {pattern}")

    replace_pin(r'(val mpvFfmpegVersion = ")[^"]+("\s*)', version)
    replace_pin(r'(val mpvFfmpegSourceSha256 = ")[0-9a-f]{64}("\s*)', digest)
    if updated == source:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def prepare_native_checkout(scratch: Path) -> tuple[Path, str]:
    checkout = scratch / "mpv-build"
    command(["git", "clone", "--filter=blob:none", f"https://github.com/{MPV_REPO}.git", checkout])
    command(["git", "fetch", "origin", "main"], cwd=checkout)
    command(["git", "checkout", "--detach", "origin/main"], cwd=checkout)

    running = active_run(MPV_REPO, MPV_WORKFLOW, ref="main")
    if running:
        print(f"Reusing active native build {running['databaseId']} instead of starting a duplicate.")
        try:
            wait_for_run(MPV_REPO, running, "Native mpv/FFmpeg build")
        except ReleaseError:
            # A terminal platform failure can leave other groups fully published.
            # Recover them below only after checking their current content keys.
            state = gh_json("run", "view", str(running["databaseId"]), "--repo", MPV_REPO,
                            "--json", "status,conclusion")
            if state.get("status") != "completed":
                raise
            print(f"Native run ended {state.get('conclusion')}; checking reusable published groups.")
    command(["git", "fetch", "origin", "main"], cwd=checkout)
    command(["git", "checkout", "--detach", "origin/main"], cwd=checkout)

    recover_native_groups(checkout, scratch / "native-recovery")

    native_head = command(["git", "rev-parse", "HEAD"], cwd=checkout, capture=True).stdout.strip()
    native_title = "action:build:pool:private"
    existing = matching_run(
        MPV_REPO,
        MPV_WORKFLOW,
        native_head,
        ref="main",
        expected_title=native_title,
    )
    if existing and existing.get("status") == "completed" and existing.get("conclusion") == "success":
        print(f"Reusing successful native build {existing['databaseId']} for current source {native_head[:12]}.")
    else:
        if existing:
            print(
                f"Current-source native build {existing['databaseId']} concluded "
                f"{existing.get('conclusion') or existing.get('status')}; starting a fresh explicit build."
            )
        dispatch(
            MPV_REPO,
            MPV_WORKFLOW,
            "main",
            {"action_tag": "build", "runner_pool_tag": "private"},
            "Native mpv/FFmpeg build",
            expected_title=native_title,
            expected_sha=native_head,
        )

    command(["git", "fetch", "origin", "main"], cwd=checkout)
    command(["git", "checkout", "--detach", "origin/main"], cwd=checkout)
    # A valid older manifest alone does not prove that current main ran.
    sync_native_asset_bases(checkout)

    native_sha = command(["git", "rev-parse", "HEAD"], cwd=checkout, capture=True).stdout.strip()
    if not verify_native_groups(checkout):
        raise ReleaseError(
            "The native workflow completed, but its manifest/assets do not verify for every platform group. "
            "No PlezyNG pin was changed."
        )
    verify_native_release_assets(checkout)
    return checkout, native_sha


def verify_native_groups(checkout: Path) -> bool:
    for group in NATIVE_GROUPS:
        result = command(
            ["python3", "scripts/keys.py", "verify", "--platform-group", group],
            cwd=checkout,
            check=False,
        )
        if result.returncode:
            print(f"Native manifest verification failed for {group}.", file=sys.stderr)
            return False
    return True


def git_commit_as_current_user(checkout: Path, message: str) -> None:
    identity = gh_json("api", "user")
    login = identity.get("login")
    user_id = identity.get("id")
    if not login or not user_id:
        raise ReleaseError("Could not resolve the authenticated GitHub account for commit attribution.")
    email = f"{user_id}+{login}@users.noreply.github.com"
    command(
        ["git", "-c", f"user.name={login}", "-c", f"user.email={email}", "commit", "-m", message],
        cwd=checkout,
    )


def sync_native_asset_bases(checkout: Path) -> None:
    """Commit manifest URL corrections after the native publish run has drained."""
    command(["python3", "scripts/keys.py", "sync-asset-bases"], cwd=checkout)
    status = command(["git", "status", "--porcelain"], cwd=checkout, capture=True).stdout.strip()
    if not status:
        return
    changed_paths = {
        line[3:]
        for line in status.splitlines()
        if len(line) > 3
    }
    allowed = {"artifacts.json", "Package.swift"}
    if not changed_paths.issubset(allowed):
        raise ReleaseError(f"Asset-base sync changed unexpected files: {sorted(changed_paths - allowed)}")
    command(["git", "add", "artifacts.json", "Package.swift"], cwd=checkout)
    git_commit_as_current_user(checkout, "fix: point native artifacts at the organization fork")
    command(["git", "fetch", "origin", "main"], cwd=checkout)
    behind = command(
        ["git", "rev-list", "--count", "HEAD..origin/main"], cwd=checkout, capture=True
    ).stdout.strip()
    if behind != "0":
        command(["git", "rebase", "origin/main"], cwd=checkout)
    command(["git", "push", "origin", "HEAD:refs/heads/main"], cwd=checkout)
    command(["git", "fetch", "origin", "main"], cwd=checkout)
    command(["git", "checkout", "--detach", "origin/main"], cwd=checkout)


def manifest_assets(section: dict) -> dict[str, str | None]:
    assets: dict[str, str | None] = {}

    def add(value: object) -> None:
        if isinstance(value, str):
            assets.setdefault(value, None)
        elif isinstance(value, dict) and isinstance(value.get("asset"), str):
            checksum = value.get("checksum")
            if checksum is not None or value["asset"] not in assets:
                assets[value["asset"]] = checksum

    for entry in section.get("libraries", {}).values():
        # AAR and framework checksum lives beside asset, not inside its name.
        add(entry)
        for value in (entry.get("prebuilt") or {}).values():
            add(value)
        for collection in ("frameworks", "symbols"):
            for value in (entry.get(collection) or {}).values():
                add(value)
    return assets


def verify_native_release_assets(checkout: Path, *, groups=NATIVE_GROUPS) -> None:
    manifest = json.loads((checkout / "artifacts.json").read_text(encoding="utf-8"))
    for group in groups:
        section = manifest["platforms"][group]
        expected_base = f"https://github.com/{MPV_REPO}/releases/download/binaries-{group}"
        if section.get("assetBase") != expected_base:
            raise ReleaseError(
                f"platforms.{group}.assetBase points to {section.get('assetBase')!r}; "
                f"expected the fork release {expected_base!r}."
            )
        release = gh_json("release", "view", f"binaries-{group}", "--repo", MPV_REPO, "--json", "assets")
        available = {asset["name"]: asset.get("digest") for asset in release.get("assets", [])}
        missing = sorted(set(manifest_assets(section)) - set(available))
        if missing:
            raise ReleaseError(f"{group} release is missing manifest assets: {', '.join(missing[:8])}")
        for name, checksum in manifest_assets(section).items():
            if checksum is None:
                continue
            remote_digest = available.get(name)
            if not remote_digest or not remote_digest.startswith("sha256:"):
                raise ReleaseError(f"GitHub did not provide a SHA-256 digest for {group}/{name}.")
            if remote_digest.removeprefix("sha256:") != checksum:
                raise ReleaseError(
                    f"Published {group}/{name} digest {remote_digest} does not match manifest {checksum}."
                )
        print(f"Verified {len(available)} assets in the {group} private-builder release.")


def native_recovery_run_is_trusted(run: dict) -> bool:
    return (
        run.get("status") == "completed"
        and run.get("event") == "workflow_dispatch"
        and run.get("head_branch") == "main"
        and run.get("path") == ".github/workflows/publish.yml"
        and run.get("display_title") == "action:build:pool:private"
        and (run.get("head_repository") or {}).get("full_name") == MPV_REPO
        and re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", "")) is not None
    )


def read_native_manifest_archive(archive: Path, digest: str) -> dict:
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest or ""):
        raise ReleaseError("Native manifest artifact has no GitHub SHA-256 digest.")
    if archive.stat().st_size > 2 * 1024 * 1024:
        raise ReleaseError("Native manifest artifact exceeds its size limit.")
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest.removeprefix("sha256:"):
        raise ReleaseError("Native manifest artifact does not match its GitHub digest.")
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        names = [item.filename for item in entries]
        if (names.count("artifacts.json") != 1 or len(names) != len(set(names))
                or set(names) - {"artifacts.json", "Package.swift"}
                or sum(item.file_size for item in entries) > 2 * 1024 * 1024):
            raise ReleaseError("Native manifest artifact has unexpected archive entries.")
        # Read data only. Package.swift is regenerated by the current source.
        return json.loads(package.read("artifacts.json"))


def recover_native_groups(checkout: Path, scratch: Path) -> list[str]:
    """Keep complete published groups when another platform failed in a prior run.

    This never pins Plezy to a partial set. Each recovered group must match the
    current builder's source key and every recorded asset digest; the normal
    all-platform build and final verification still run afterwards.
    """
    if active_run(MPV_REPO, MPV_WORKFLOW, ref="main"):
        raise ReleaseError("A native build is active; refusing to change its manifest baseline.")
    pending = {
        group for group in NATIVE_GROUPS
        if command(["python3", "scripts/keys.py", "verify", "--platform-group", group],
                   cwd=checkout, capture=True, check=False, quiet=True).returncode
    }
    if not pending:
        return []
    manifest_path = checkout / "artifacts.json"
    package_path = checkout / "Package.swift"
    recovered = []
    runs = workflow_runs(MPV_REPO, MPV_WORKFLOW, ref="main")
    for summary in runs[:12]:
        if (summary.get("status") != "completed"
                or summary.get("event") != "workflow_dispatch"
                or summary.get("displayTitle") != "action:build:pool:private"):
            continue
        run_id = summary["databaseId"]
        run = gh_json("api", f"repos/{MPV_REPO}/actions/runs/{run_id}")
        if not native_recovery_run_is_trusted(run):
            continue
        if command(["git", "merge-base", "--is-ancestor", run["head_sha"], "HEAD"],
                   cwd=checkout, capture=True, check=False, quiet=True).returncode:
            continue
        jobs = gh_json("api", f"repos/{MPV_REPO}/actions/runs/{run_id}/jobs?per_page=100")
        successful = {
            job["name"] for job in jobs.get("jobs", [])
            if job.get("status") == "completed" and job.get("conclusion") == "success"
        }
        candidates = [group for group in sorted(pending) if f"Publish {group}" in successful]
        if not candidates:
            continue
        artifacts = gh_json("api", f"repos/{MPV_REPO}/actions/runs/{run_id}/artifacts?per_page=100")
        for group in candidates:
            matches = [item for item in artifacts.get("artifacts", [])
                       if item.get("name") == f"manifest-{group}" and not item.get("expired")]
            if len(matches) != 1:
                continue
            artifact = matches[0]
            if not 0 < artifact.get("size_in_bytes", 0) <= 2 * 1024 * 1024:
                raise ReleaseError(f"Unexpected manifest-{group} artifact size.")
            scratch.mkdir(parents=True, exist_ok=True)
            archive = scratch / f"{run_id}-manifest-{group}.zip"
            with archive.open("wb") as output:
                result = subprocess.run(
                    ["gh", "api", f"repos/{MPV_REPO}/actions/artifacts/{artifact['id']}/zip"],
                    stdout=output, stderr=subprocess.PIPE, check=False,
                )
            if result.returncode:
                raise ReleaseError(f"Could not download published {group} manifest from run {run_id}.")
            partial = read_native_manifest_archive(archive, artifact.get("digest"))
            section = (partial.get("platforms") or {}).get(group)
            if not isinstance(section, dict):
                raise ReleaseError(f"Published manifest artifact lacks platform {group}.")
            original_manifest = manifest_path.read_bytes()
            original_package = package_path.read_bytes()
            accepted = False
            try:
                manifest = json.loads(original_manifest)
                manifest["platforms"][group] = section
                manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
                if group == "apple":
                    command(["python3", "scripts/keys.py", "render"], cwd=checkout, capture=True)
                verified = command(
                    ["python3", "scripts/keys.py", "verify", "--platform-group", group],
                    cwd=checkout, capture=True, check=False,
                )
                if verified.returncode:
                    print(f"Run {run_id}'s {group} artifacts do not match current source; rebuilding.")
                    continue
                verify_native_release_assets(checkout, groups=(group,))
                accepted = True
                recovered.append(group)
                pending.remove(group)
                print(f"Recovered verified {group} artifacts published by run {run_id}.")
            finally:
                if not accepted:
                    manifest_path.write_bytes(original_manifest)
                    package_path.write_bytes(original_package)
        if not pending:
            break
    if recovered:
        if active_run(MPV_REPO, MPV_WORKFLOW, ref="main"):
            raise ReleaseError("A native build started during recovery; no manifest was pushed.")
        command(["git", "add", "artifacts.json", "Package.swift"], cwd=checkout)
        git_commit_as_current_user(checkout, "chore: recover verified native groups from completed builds")
        # A changed main rejects this ordinary push. Never rebase a manifest
        # that was verified against different source inputs.
        command(["git", "push", "origin", "HEAD:refs/heads/main"], cwd=checkout)
    return recovered


def create_plezy_worktree(scratch: Path) -> Path:
    worktree = scratch / "plezyng-main"
    command(["git", "fetch", "origin", "main"], cwd=ROOT)
    command(["git", "worktree", "add", "--detach", worktree, "origin/main"], cwd=ROOT)
    return worktree


def commit_and_push_native_pin(worktree: Path, native_repo: Path, native_sha: str,
                               ffmpeg_version: str, ffmpeg_sha256: str) -> str:
    command(["scripts/set_native_revision.sh", native_sha, "--repo", native_repo], cwd=worktree)
    update_android_ffmpeg_pin(worktree, ffmpeg_version, ffmpeg_sha256)
    changelog = worktree / "CHANGELOG.md"
    changelog_source = changelog.read_text(encoding="utf-8")
    unreleased = "## [Unreleased]\n\n"
    pin_note = "- Refresh pinned MPV and FFmpeg artifacts to the verified private native build.\n\n"
    if pin_note.rstrip() not in changelog_source:
        if changelog_source.count(unreleased) != 1:
            raise ReleaseError("Expected one [Unreleased] section before committing native pins.")
        changelog.write_text(changelog_source.replace(unreleased, unreleased + pin_note, 1), encoding="utf-8")
    # The Apple SPM checker needs .dart_tool/package_config.json from `flutter pub get`.
    # Dependency resolution belongs on the selected CI runner, not this host.
    # ci.yml runs pub get and this same checker on the exact release commit before tagging.
    command(["git", "diff", "--check"], cwd=worktree)

    changed = command(["git", "status", "--porcelain"], cwd=worktree, capture=True).stdout.strip()
    if changed:
        command(["git", "add", "-u"], cwd=worktree)
        # This generated pin commit is validated by exact-source CI below.
        # The repository pre-commit hook runs Dart/codegen checks on the host, so skip it here.
        command(
            ["env", "SKIP_HOOKS=1", "git", "commit", "-m",
             f"build: pin verified native artifacts {native_sha[:12]}"],
            cwd=worktree,
        )

    command(["git", "fetch", "origin", "main"], cwd=worktree)
    behind = command(
        ["git", "rev-list", "--count", "HEAD..origin/main"], cwd=worktree, capture=True
    ).stdout.strip()
    if behind != "0":
        command(["git", "rebase", "origin/main"], cwd=worktree)
    command(["git", "push", "origin", "HEAD:refs/heads/main"], cwd=worktree)
    return command(["git", "rev-parse", "HEAD"], cwd=worktree, capture=True).stdout.strip()


def ensure_ci(commit_sha: str, *, execution_profile: str = "hybrid") -> dict:
    existing = matching_run(PLEZY_REPO, CI_WORKFLOW, commit_sha, ref="main")
    if existing:
        if existing.get("status") == "completed" and existing.get("conclusion") != "success":
            raise ReleaseError(f"CI for release commit {commit_sha[:12]} failed; refusing to tag it.")
        if existing.get("status") != "completed":
            existing = wait_for_run(PLEZY_REPO, existing, "PlezyNG CI")
        if execution_profile != "hybrid" or run_has_successful_job(
            PLEZY_REPO, existing, "Windows native reliability (arm64)"
        ):
            print(f"Reusing successful CI run {existing['databaseId']} for {commit_sha[:12]}.")
            return existing
        print(
            f"CI run {existing['databaseId']} passed without the required Windows ARM64 job; "
            "dispatching the hybrid profile."
        )
    return dispatch(
        PLEZY_REPO,
        CI_WORKFLOW,
        "main",
        {"action": "ci", "runner_pool": "private", "execution_profile": execution_profile,
         "build_linux_packages": "true"},
        "PlezyNG CI",
        expected_title="action:ci:pool:private",
        expected_sha=commit_sha,
    )


def candidate_build_title(version: str) -> str:
    return f"action:build:pool:private:mode:release:version:{version}"


def ensure_candidate_build(
    version: str,
    commit_sha: str,
    *,
    execution_profile: str = "hybrid",
    include_apple_store_build: bool = False,
    include_webos_build: bool = True,
) -> dict:
    """Require a complete nonpublishing release-mode build before creating the immutable tag."""
    run_title = candidate_build_title(version)
    existing = matching_run(
        PLEZY_REPO,
        RELEASE_WORKFLOW,
        commit_sha,
        ref="main",
        expected_title=run_title,
    )
    if existing:
        if existing.get("status") == "completed" and existing.get("conclusion") != "success":
            raise ReleaseError(
                f"Release-mode candidate run {existing['databaseId']} concluded "
                f"{existing.get('conclusion')}; refusing to tag an unvalidated commit."
            )
        if existing.get("status") != "completed":
            existing = wait_for_run(
                PLEZY_REPO, existing, f"PlezyNG {version} all-platform release-mode candidate"
            )
        complete = execution_profile != "hybrid" or run_has_successful_job(
            PLEZY_REPO, existing, "Build Windows (arm64)"
        )
        if include_apple_store_build:
            complete = complete and all(
                run_has_successful_step(PLEZY_REPO, existing, job_name, step_name)
                for job_name, step_name in (
                    ("build-ios", "Build signed iOS App Store IPA"),
                    ("Build tvOS developer package (arm64)", "Build signed tvOS App Store IPA"),
                )
            )
        if complete:
            print(f"Reusing successful release-mode candidate run {existing['databaseId']} for {version}.")
            return existing
        print(
            f"Candidate run {existing['databaseId']} passed without all requested platform jobs; "
            "dispatching the required profile."
        )

    active = active_run(PLEZY_REPO, RELEASE_WORKFLOW, ref="main")
    if active:
        raise ReleaseError(
            f"PlezyNG build workflow run {active['databaseId']} is still {active.get('status')}; "
            "wait for it to finish before dispatching the release-mode candidate."
        )
    ensure_remote_main_sha(commit_sha, f"dispatching the {version} release-mode candidate")
    return dispatch(
        PLEZY_REPO,
        RELEASE_WORKFLOW,
        "main",
        {
            "action": "build",
            "runner_pool": "private",
            "execution_profile": execution_profile,
            "mode": "release",
            "build_version": version,
            "include_webos_build": "true" if include_webos_build else "false",
            "include_webos_release": "false",
            "include_tizen_build": "true",
            "include_apple_store_build": "true" if include_apple_store_build else "false",
            "subtitle_gpu_backend": "cpu",
            "prepare_homebrew_cask": "false",
        },
        f"PlezyNG {version} all-platform release-mode candidate",
        expected_title=run_title,
        expected_sha=commit_sha,
    )


def existing_release_tag_commit(worktree: Path, tag: str) -> str | None:
    command(["git", "fetch", "--tags", "origin"], cwd=worktree)
    existing = command(
        ["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"],
        cwd=worktree,
        capture=True,
        check=False,
        quiet=True,
    )
    return existing.stdout.strip() if existing.returncode == 0 else None


def validate_immutable_release_tag(
    worktree: Path,
    tag: str,
    tag_commit: str,
    main_commit: str,
) -> None:
    ancestry = command(
        ["git", "merge-base", "--is-ancestor", tag_commit, main_commit],
        cwd=worktree,
        check=False,
        quiet=True,
    )
    if ancestry.returncode != 0:
        raise ReleaseError(
            f"Tag {tag} at {tag_commit[:12]} is not an ancestor of main "
            f"at {main_commit[:12]}; refusing to reuse or move it."
        )
    changed = command(
        ["git", "diff", "--name-only", "-z", tag_commit, main_commit],
        cwd=worktree,
        capture=True,
        quiet=True,
    ).stdout
    blocked = sorted(
        path for path in changed.split("\0")
        if path and path not in RELEASE_TAG_REUSE_ALLOWLIST
    )
    if blocked:
        raise ReleaseError(
            f"Tag {tag} is immutable and cannot be reused because main differs in "
            f"non-release source files: {', '.join(blocked)}."
        )


def ensure_tag(worktree: Path, version: str, commit_sha: str) -> str:
    tag = f"v{version}"
    existing_commit = existing_release_tag_commit(worktree, tag)
    if existing_commit:
        validate_immutable_release_tag(worktree, tag, existing_commit, commit_sha)
        print(f"Reusing immutable tag {tag} at {existing_commit[:12]}.")
        return tag
    command(["git", "tag", "-a", tag, commit_sha, "-m", f"PlezyNG {version}"], cwd=worktree)
    command(["git", "push", "origin", f"refs/tags/{tag}"], cwd=worktree)
    return tag


def ensure_release(
    tag: str,
    commit_sha: str,
    *,
    include_webos_release: bool,
    execution_profile: str = "hybrid",
    include_apple_store_build: bool = False,
    reuse_platform_run_id: int | None = None,
    reuse_android_run_id: int | None = None,
    include_webos_build: bool = True,
) -> dict:
    if reuse_android_run_id and not reuse_platform_run_id:
        raise ReleaseError("Android reuse requires a verified platform source run.")
    if include_webos_release and not include_webos_build:
        raise ReleaseError("Public WebOS attachment requires a successful candidate build.")
    run_title = f"action:release:pool:private:tag:{tag}"
    if reuse_platform_run_id:
        if execution_profile != "hybrid" or include_webos_release or include_apple_store_build:
            raise ReleaseError("Platform recovery requires the hybrid GitHub-only release profile.")
        options = {}
        if reuse_android_run_id:
            options["android_run"] = reuse_android_run_id
        if not include_webos_build:
            options["include_webos_build"] = False
        if reuse_android_run_id and not include_webos_build:
            options["wait_complete"] = True
        verify_platform_recovery(reuse_platform_run_id, commit_sha, tag.removeprefix("v"), **options)
    existing = matching_run(
        PLEZY_REPO,
        RELEASE_WORKFLOW,
        commit_sha,
        ref="main",
        expected_title=run_title,
    )
    if existing:
        if existing.get("status") == "completed" and existing.get("conclusion") != "success":
            raise ReleaseError(
                f"Release build run {existing['databaseId']} concluded {existing.get('conclusion')}; "
                "it was not re-run to avoid duplicating publication side effects."
            )
        if existing.get("status") != "completed":
            existing = wait_for_run(PLEZY_REPO, existing, f"PlezyNG {tag} all-platform release build")
        complete = bool(reuse_platform_run_id) or execution_profile != "hybrid" or run_has_successful_job(
            PLEZY_REPO, existing, "Build Windows (arm64)"
        )
        if include_apple_store_build:
            complete = complete and all(
                run_has_successful_step(PLEZY_REPO, existing, job_name, step_name)
                for job_name, step_name in (
                    ("build-ios", "Build signed iOS App Store IPA"),
                    ("Build tvOS developer package (arm64)", "Build signed tvOS App Store IPA"),
                )
            )
        if complete:
            print(f"Reusing successful release build run {existing['databaseId']} for {tag}.")
            return existing
        print(
            f"Release run {existing['databaseId']} passed without all requested platform jobs; "
            "dispatching the required profile."
        )
    ensure_remote_main_sha(commit_sha, f"dispatching the {tag} release build")
    fields = {
        "action": "release",
        "runner_pool": "private",
        "execution_profile": execution_profile,
        "mode": "release",
        "build_version": tag.removeprefix("v"),
        "include_webos_build": "true" if include_webos_build else "false",
        "include_webos_release": "true" if include_webos_release else "false",
        "include_tizen_build": "true",
        "include_apple_store_build": "true" if include_apple_store_build else "false",
    }
    if reuse_platform_run_id:
        fields["reuse_platform_run_id"] = str(reuse_platform_run_id)
    if reuse_android_run_id:
        fields["reuse_android_run_id"] = str(reuse_android_run_id)
    return dispatch(
        PLEZY_REPO,
        RELEASE_WORKFLOW,
        "main",
        fields,
        f"PlezyNG {tag} all-platform release build",
        expected_title=run_title,
        expected_sha=commit_sha,
    )


def verify_platform_recovery(run_id: int, commit_sha: str, version: str, *,
                             android_run=None, include_webos_build=True, wait_complete=False) -> dict:
    from recover_release_platforms import RecoveryError, compose_proof, verify_source_run, wait_for_source_run

    try:
        source = (wait_for_source_run(run_id, commit_sha, version, 10800) if wait_complete else
                  verify_source_run(run_id, commit_sha, version, allow_pending=True))
        return compose_proof(source, android_run, include_webos_build)
    except (RecoveryError, RuntimeError) as error:
        raise ReleaseError(f"Platform artifact recovery rejected: {error}") from error


def ensure_remote_main_sha(expected_sha: str, purpose: str) -> None:
    branch = gh_json("api", f"repos/{PLEZY_REPO}/branches/main")
    actual_sha = branch.get("commit", {}).get("sha") if isinstance(branch, dict) else None
    if actual_sha != expected_sha:
        raise ReleaseError(
            f"Cannot continue with {purpose}: PlezyNG main is {actual_sha or 'unavailable'}, "
            f"but release tag source is {expected_sha}. Reconcile main before publishing."
        )


def release_metadata(tag: str) -> dict:
    pages = gh_json(
        "api",
        "--paginate",
        "--slurp",
        f"repos/{PLEZY_REPO}/releases?per_page=100",
    )
    if isinstance(pages, list):
        for page in pages:
            if not isinstance(page, list):
                continue
            for release in page:
                if isinstance(release, dict) and release.get("tag_name") == tag:
                    return release
    raise ReleaseError(f"No GitHub release (draft or published) exists for tag {tag}.")


def publish_github_release(tag: str) -> dict:
    release = release_metadata(tag)
    if release.get("tag_name") != tag:
        raise ReleaseError(f"GitHub returned a different release tag while resolving {tag}.")
    if release.get("draft"):
        command([
            "gh", "api", "--method", "PATCH",
            f"repos/{PLEZY_REPO}/releases/{release['id']}",
            "-F", "draft=false",
        ])
    published = release_metadata(tag)
    if published.get("draft") or not published.get("published_at"):
        raise ReleaseError(f"GitHub release {tag} was not promoted to a published release.")
    return published


def validate_release_outputs(
    tag: str,
    version: str,
    *,
    include_webos_release: bool,
    execution_profile: str = "private",
    include_apple_store_build: bool = False,
) -> None:
    release = release_metadata(tag)
    assets = {
        asset.get("name")
        for asset in release.get("assets", [])
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    }
    required = {
        "SHA256SUMS.txt", "appcast.xml",
        "plezy-android-arm64-v8a.tar.gz", "plezy-android-armeabi-v7a.tar.gz", "plezy-android-x86_64.tar.gz",
        "plezy-ios-unsigned.ipa", "plezy-tvos-unsigned.ipa", "plezyng-macos.dmg",
        "plezy-windows-x64-portable.7z", "plezy-windows-installer.exe",
        f"plezyng-winget-manifests-{version}.zip", f"plezyng.{version}.nupkg",
        "plezy-linux-x64.tar.gz", "plezy-linux-x64.deb", "plezy-linux-x64.rpm",
        "plezy-linux-x64.pkg.tar.zst", "plezy-linux-x64.flatpak", "plezyng-linux-x64.snap",
        "plezy-linux-arm64.tar.gz", "plezy-linux-arm64.deb", "plezy-linux-arm64.rpm",
        "plezy-linux-arm64.pkg.tar.zst", "plezy-linux-arm64.flatpak", "plezyng-linux-arm64.snap",
        "plezyng-linux-x86_64.AppImage",
        "PlezyNG-tizen-arm-tester-handoff.zip",
    }
    if include_webos_release:
        required.update({
            "webos-engine-provenance.json", "webos-compatibility.json",
            "webos-SHA256SUMS.txt", "PlezyNG-lg-webos-submission.zip",
        })
        if not any(name.endswith(".ipk") for name in assets if isinstance(name, str)):
            required.add("<eligible webOS .ipk>")
    if execution_profile == "hybrid":
        required.add("plezy-windows-arm64-portable.zip")

    secrets = configured_repo_names("secret")
    android_signing = {
        "ANDROID_KEYSTORE_BASE64", "ANDROID_STORE_PASSWORD", "ANDROID_KEY_PASSWORD", "ANDROID_KEY_ALIAS",
    }
    if android_signing.issubset(secrets):
        required.update({"plezyng-android-play.aab", "plezyng-amazon-firetv.apk"})
    apple_store_signing = {
        "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_PRIVATE_KEY", "APPLE_TEAM_ID",
    }
    if include_apple_store_build and apple_store_signing.issubset(secrets):
        required.add("plezyng-ios-appstore.ipa")
    if include_apple_store_build and apple_store_signing.issubset(secrets):
        required.add("plezyng-tvos-appstore.ipa")

    missing = sorted(required - assets)
    if missing:
        raise ReleaseError(
            f"The draft release {tag} is missing expected platform/channel assets: {', '.join(missing)}. "
            "It remains a draft; no public release or store/package publication was started."
        )
    print(f"Verified {len(required)} required release assets for {tag} before publication.")


def configured_repo_names(kind: str) -> set[str]:
    rows = gh_json(kind, "list", "--repo", PLEZY_REPO, "--json", "name")
    if not isinstance(rows, list):
        raise ReleaseError(f"Could not read configured repository {kind}s.")
    return {row["name"] for row in rows if isinstance(row, dict) and isinstance(row.get("name"), str)}


def ensure_channel_run(
    workflow: str,
    title: str,
    fields: dict[str, str],
    purpose: str,
    *,
    release_sha: str,
) -> dict:
    for run in workflow_runs(PLEZY_REPO, workflow, ref="main"):
        if run.get("event") != "workflow_dispatch" or run.get("displayTitle") != title:
            continue
        if run.get("headSha") != release_sha:
            raise ReleaseError(
                f"Previous {purpose} run {run['databaseId']} used source "
                f"{run.get('headSha') or 'unknown'}, not the exact release commit {release_sha}."
            )
        if run.get("status") == "completed":
            if run.get("conclusion") != "success":
                raise ReleaseError(
                    f"Previous {purpose} run {run['databaseId']} concluded "
                    f"{run.get('conclusion')}; inspect its external side effects before retrying."
                )
            print(f"Reusing successful {purpose} run {run['databaseId']}.")
            return run
        return wait_for_run(PLEZY_REPO, run, purpose)
    ensure_remote_main_sha(release_sha, f"dispatching {purpose}")
    return dispatch(
        PLEZY_REPO,
        workflow,
        "main",
        fields,
        purpose,
        expected_title=title,
        expected_sha=release_sha,
    )


def publish_configured_channels(
    tag: str,
    version: str,
    *,
    release_sha: str,
    include_webos_release: bool,
) -> tuple[list[dict], list[dict], list[str]]:
    release = release_metadata(tag)
    assets = {asset.get("name") for asset in release.get("assets", []) if isinstance(asset, dict)}
    secrets = configured_repo_names("secret")
    variables = configured_repo_names("variable")

    specs = [
        {
            "name": "Google Play internal draft",
            "workflow": "publish-app-stores.yml",
            "title": f"action:publish-app-stores:pool:private:tag:{tag}:channel:google-play",
            "fields": {"action": "publish-app-stores", "runner_pool": "private", "release_tag": tag,
                       "channel": "google-play", "play_track": "internal", "play_release_status": "draft"},
            "secrets": {"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"}, "variables": set(),
            "assets": {"plezyng-android-play.aab", "SHA256SUMS.txt"},
        },
        {
            "name": "Amazon Appstore upload",
            "workflow": "publish-app-stores.yml",
            "title": f"action:publish-app-stores:pool:private:tag:{tag}:channel:amazon-appstore",
            "fields": {"action": "publish-app-stores", "runner_pool": "private", "release_tag": tag,
                       "channel": "amazon-appstore", "play_track": "internal", "play_release_status": "draft"},
            "secrets": {"AMAZON_APPSTORE_CLIENT_ID", "AMAZON_APPSTORE_CLIENT_SECRET"}, "variables": set(),
            "assets": {"plezyng-amazon-firetv.apk", "SHA256SUMS.txt"},
        },
        {
            "name": "Apple App Store Connect iOS upload",
            "workflow": "publish-app-stores.yml",
            "title": f"action:publish-app-stores:pool:private:tag:{tag}:channel:app-store-ios",
            "fields": {"action": "publish-app-stores", "runner_pool": "private", "release_tag": tag,
                       "channel": "app-store-ios", "play_track": "internal", "play_release_status": "draft"},
            "secrets": {"APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_PRIVATE_KEY"}, "variables": set(),
            "assets": {"plezyng-ios-appstore.ipa", "SHA256SUMS.txt"},
        },
        {
            "name": "Apple App Store Connect tvOS upload",
            "workflow": "publish-app-stores.yml",
            "title": f"action:publish-app-stores:pool:private:tag:{tag}:channel:app-store-tvos",
            "fields": {"action": "publish-app-stores", "runner_pool": "private", "release_tag": tag,
                       "channel": "app-store-tvos", "play_track": "internal", "play_release_status": "draft"},
            "secrets": {"APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_PRIVATE_KEY"}, "variables": set(),
            "assets": {"plezyng-tvos-appstore.ipa", "SHA256SUMS.txt"},
        },
        {
            "name": "AUR",
            "workflow": "publish-aur.yml",
            "title": f"action:publish-aur:pool:private:tag:{tag}",
            "fields": {"action": "publish-aur", "runner_pool": "private", "release_tag": tag},
            "secrets": {"AUR_SSH_KEY"}, "variables": {"AUR_PACKAGE_NAME"},
            "assets": {"plezy-linux-x64.tar.gz", "plezy-linux-arm64.tar.gz", "SHA256SUMS.txt"},
        },
        {
            "name": "Fedora COPR",
            "workflow": "publish-copr.yml",
            "title": f"action:publish-copr:pool:private:tag:{tag}",
            "fields": {"action": "publish-copr", "runner_pool": "private", "release_tag": tag},
            "secrets": {"COPR_LOGIN", "COPR_USERNAME", "COPR_TOKEN"}, "variables": {"COPR_PROJECT"},
            "assets": {"plezy-linux-x64.tar.gz", "plezy-linux-arm64.tar.gz", "SHA256SUMS.txt"},
        },
        {
            "name": "Launchpad PPA",
            "workflow": "publish-ppa.yml",
            "title": f"action:publish-ppa:pool:private:tag:{tag}",
            "fields": {"action": "publish-ppa", "runner_pool": "private", "release_tag": tag},
            "secrets": {"GPG_PRIVATE_KEY"}, "variables": {"LAUNCHPAD_PPA"},
            "assets": {"plezy-linux-x64.tar.gz", "plezy-linux-arm64.tar.gz", "SHA256SUMS.txt"},
        },
        {
            "name": "Snap Store stable",
            "workflow": "publish-snap.yml",
            "title": f"action:publish-snap:pool:private:tag:{tag}:channel:stable",
            "fields": {"action": "publish-snap", "runner_pool": "private", "release_tag": tag,
                       "channel": "stable"},
            "secrets": {"SNAPCRAFT_STORE_CREDENTIALS"}, "variables": set(),
            "assets": {"plezyng-linux-x64.snap", "plezyng-linux-arm64.snap", "SHA256SUMS.txt"},
        },
        {
            "name": "Chocolatey",
            "workflow": "publish-chocolatey.yml",
            "title": f"action:publish-chocolatey:pool:private:tag:{tag}:publish:true",
            "fields": {"action": "publish-chocolatey", "runner_pool": "private", "release_tag": tag,
                       "publish": "true"},
            "secrets": {"CHOCO_API_KEY"}, "variables": set(),
            "assets": {"plezy-windows-installer.exe", "SHA256SUMS.txt"},
            "asset_predicate": lambda name: name.startswith("plezyng.") and name.endswith(".nupkg"),
        },
        {
            "name": "WinGet community submission",
            "workflow": "publish-winget.yml",
            "title": f"action:publish-winget:pool:private:tag:{tag}:submit:true",
            "fields": {"action": "publish-winget", "runner_pool": "private", "release_tag": tag,
                       "submit": "true"},
            "secrets": {"WINGET_CREATE_GITHUB_TOKEN"}, "variables": set(),
            "assets": {f"plezyng-winget-manifests-{version}.zip", "plezy-windows-installer.exe", "SHA256SUMS.txt"},
        },
        {
            "name": "GitHub Container Registry and Docker Hub",
            "workflow": "release-containers.yml",
            "title": f"action:publish-containers:pool:private:tag:{tag}",
            "fields": {"action": "publish-containers", "runner_pool": "private", "release_tag": tag},
            "secrets": set(), "variables": set(),
            "assets": {"SHA256SUMS.txt"},
        },
        {
            "name": "Discord release announcement",
            "workflow": "discord-release.yml",
            "title": f"action:announce-release:pool:private:tag:{tag}",
            "fields": {"action": "announce-release", "runner_pool": "private", "release_tag": tag},
            "secrets": {"DISCORD_RELEASE_WEBHOOK"}, "variables": set(),
            "assets": set(),
        },
        {
            "name": "Homebrew cask and Sparkle appcast",
            "workflow": "update-packages.yml",
            "title": f"action:update-packages:pool:private:tag:{tag}",
            "fields": {"action": "update-packages", "runner_pool": "private", "release_tag": tag},
            "secrets": set(), "variables": set(),
            "assets": {"plezyng-macos.dmg", "appcast.xml"},
        },
    ]

    completed: list[dict] = []
    skipped: list[dict] = []
    failures: list[str] = []
    macos_signing = {
        "MACOS_CERTIFICATE_BASE64", "MACOS_CERTIFICATE_PASSWORD", "KEYCHAIN_PASSWORD",
        "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID",
    }
    if not macos_signing.issubset(secrets):
        skipped.append({
            "channel": "Homebrew Cask",
            "reason": "Developer ID signing and notarization secrets are not configured; appcast update remains enabled.",
        })
    if not {"WINDOWS_SIGNING_CERTIFICATE_BASE64", "WINDOWS_SIGNING_CERTIFICATE_PASSWORD"}.issubset(secrets):
        skipped.append({
            "channel": "Windows Authenticode signature",
            "reason": "certificate secrets are not configured; Windows release files will be unsigned.",
        })
    skipped.append({
        "channel": "Microsoft Store",
        "reason": "MSSTORE_PACKAGE_NAME, MSSTORE_PUBLISHER, and MSSTORE_PUBLISHER_DISPLAY_NAME are not configured.",
    })
    skipped.append({
        "channel": "Samsung Tizen Seller Office",
        "reason": "no Samsung TV signing profile is configured; the release builds a tester TPK only.",
    })
    if not include_webos_release:
        skipped.append({
            "channel": "LG webOS public release",
            "reason": "the webOS IPK is built as a candidate; exact-artifact eligibility is not enabled.",
        })
    for spec in specs:
        missing_secrets = sorted(spec["secrets"] - secrets)
        missing_variables = sorted(spec["variables"] - variables)
        if missing_secrets or missing_variables:
            skipped.append({
                "channel": spec["name"],
                "reason": f"missing secrets={missing_secrets}, variables={missing_variables}",
            })
            print(f"Skipping {spec['name']}: missing configured credentials or variables.")
            continue
        predicate = spec.get("asset_predicate")
        required_assets = set(spec["assets"])
        if predicate:
            matching = {name for name in assets if isinstance(name, str) and predicate(name)}
            if not matching:
                required_assets.add("<Chocolatey .nupkg>")
        missing_assets = sorted(required_assets - assets)
        if missing_assets:
            failures.append(f"{spec['name']} lacks release assets: {missing_assets}")
            continue
        try:
            result = ensure_channel_run(
                spec["workflow"],
                spec["title"],
                spec["fields"],
                spec["name"],
                release_sha=release_sha,
            )
            completed.append({"channel": spec["name"], "run_id": result["databaseId"], "url": result.get("url")})
        except ReleaseError as error:
            failures.append(f"{spec['name']}: {error}")
    return completed, skipped, failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Release version matching pubspec.yaml, such as 3.0.0")
    parser.add_argument(
        "--reuse-platform-run", type=int,
        help="Rebuild Android/WebOS and reuse other verified platform outputs after infrastructure-only fixes.",
    )
    parser.add_argument("--reuse-android-run", type=int, help="Reuse a separately successful Android release artifact.")
    parser.add_argument("--skip-webos-build", action="store_true", help="Exclude the non-public experimental WebOS candidate from this release.")
    parser.add_argument(
        "--include-webos-release",
        action="store_true",
        help="Attach the webOS IPK to the public draft release when the existing eligibility gate passes.",
    )
    parser.add_argument(
        "--execution-profile",
        choices=("private", "hybrid"),
        default=None,
        help="Use hosted runners for compatible jobs by default; private JIT remains available for constrained work.",
    )
    publication = parser.add_mutually_exclusive_group()
    publication.add_argument(
        "--publish",
        action="store_true",
        help=(
            "After every release build succeeds, publish the GitHub release and run each configured "
            "package/store channel sequentially. Store lanes upload binaries but do not submit them for review."
        ),
    )
    publication.add_argument(
        "--publish-github-only",
        action="store_true",
        help="Publish the verified GitHub release without starting package, store, or announcement workflows.",
    )
    parser.add_argument(
        "--scratch",
        type=Path,
        help="Keep temporary checkouts and signature-verification inputs under this directory.",
    )
    parser.add_argument(
        "--ffmpeg-source-cache",
        type=Path,
        help=(
            "Reuse a retained directory containing the pinned FFmpeg archive, its .asc signature, and "
            "ffmpeg-devel.asc; the archive is still verified against the pinned release key."
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        raise ReleaseError("--version must be MAJOR.MINOR.PATCH, without a leading v.")
    if args.execution_profile is None:
        args.execution_profile = "hybrid"
    package_version = command(
        ["python3", "scripts/pubspec_version.py", "pubspec.yaml"], cwd=ROOT, capture=True
    ).stdout.strip().split("+", 1)[0]
    if package_version != args.version:
        raise ReleaseError(f"Requested {args.version}, but pubspec.yaml declares {package_version}.")
    if args.version == "3.0.0" and args.execution_profile != "hybrid":
        raise ReleaseError("The PlezyNG 3.0.0 release requires the hybrid profile, including native Windows ARM64 CI.")
    if args.reuse_platform_run and (
        args.reuse_platform_run < 1 or args.publish or args.include_webos_release
        or args.execution_profile != "hybrid"
    ):
        raise ReleaseError("Platform recovery supports hybrid GitHub-only or draft publication.")
    if args.reuse_android_run and (args.reuse_android_run < 1 or not args.reuse_platform_run):
        raise ReleaseError("Android reuse requires a verified platform source run.")
    if args.skip_webos_build and args.include_webos_release:
        raise ReleaseError("A public WebOS artifact requires its successful candidate build.")
    command(["gh", "auth", "status", "--hostname", "github.com"], capture=True, quiet=True)

    scratch = args.scratch.resolve() if args.scratch else Path(tempfile.mkdtemp(prefix="plezyng-release-"))
    if scratch.exists() and any(scratch.iterdir()):
        raise ReleaseError(f"Scratch directory must be empty so task-owned cleanup is exact: {scratch}")
    scratch.mkdir(parents=True, exist_ok=True)
    global APPLE_JIT_EVIDENCE_ROOT
    APPLE_JIT_EVIDENCE_ROOT = scratch / "apple-jit-evidence"
    summary_path = scratch / "release-summary.json"
    progress_path = scratch / "release-progress.json"
    worktree: Path | None = None
    stage = "startup"
    progress = {"version": args.version, "execution_profile": args.execution_profile,
                "status": "running", "stage": stage}

    def save_progress() -> None:
        progress_path.write_text(json.dumps(progress, indent=2) + "\n", encoding="utf-8")

    try:
        print(f"Release scratch: {scratch}", flush=True)
        worktree = create_plezy_worktree(scratch)
        main_commit = command(
            ["git", "rev-parse", "HEAD"], cwd=worktree, capture=True, quiet=True
        ).stdout.strip()
        ensure_remote_main_sha(main_commit, "starting the PlezyNG release")
        tag = f"v{args.version}"
        existing_tag_commit = existing_release_tag_commit(worktree, tag)
        tag_reused = existing_tag_commit is not None
        if args.reuse_platform_run and not tag_reused:
            raise ReleaseError("Platform recovery requires an existing immutable release tag.")
        native_sha = None
        ffmpeg_version = None
        ffmpeg_sha256 = None

        if tag_reused:
            validate_immutable_release_tag(
                worktree, tag, existing_tag_commit, main_commit
            )
            pin_sha = main_commit
            progress["tag_commit"] = existing_tag_commit
            progress["immutable_tag_reused"] = True
            print(
                f"Using existing immutable {tag} at {existing_tag_commit[:12]}; "
                "main differs only in allowlisted release infrastructure, so the "
                "release action will perform the complete platform build."
            )
        else:
            stage = "native build and manifest verification"
            progress["stage"] = stage
            save_progress()
            native_repo, native_sha = prepare_native_checkout(scratch)
            progress["native_manifest_commit"] = native_sha
            versions = json.loads((native_repo / "versions.json").read_text(encoding="utf-8"))
            ffmpeg_pin = versions["components"]["ffmpeg"]["version"]
            stage = "FFmpeg signature and checksum verification"
            progress["stage"] = stage
            save_progress()
            ffmpeg_version, ffmpeg_sha256 = verified_ffmpeg_source(
                ffmpeg_pin,
                scratch / "ffmpeg",
                source_cache=args.ffmpeg_source_cache,
            )
            progress["ffmpeg_version"] = ffmpeg_version
            progress["ffmpeg_source_sha256"] = ffmpeg_sha256

            stage = "PlezyNG pin update and push"
            progress["stage"] = stage
            save_progress()
            pin_sha = commit_and_push_native_pin(
                worktree, native_repo, native_sha, ffmpeg_version, ffmpeg_sha256
            )
        progress["plezyng_commit"] = pin_sha
        stage = "PlezyNG CI"
        progress["stage"] = stage
        save_progress()
        if args.reuse_platform_run:
            proof = verify_platform_recovery(
                args.reuse_platform_run, pin_sha, args.version,
                android_run=args.reuse_android_run, include_webos_build=not args.skip_webos_build,
                wait_complete=bool(args.reuse_android_run and args.skip_webos_build),
            )
            ci = {"databaseId": proof["ci_run_id"]}
            progress["platform_recovery"] = proof
            print(f"Verified unchanged product inputs and exact-source CI from run {proof['ci_run_id']}.")
        else:
            ci = ensure_ci(pin_sha, execution_profile=args.execution_profile)
        progress["ci_run"] = ci["databaseId"]
        apple_store_secrets = {
            "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_PRIVATE_KEY", "APPLE_TEAM_ID",
        }
        include_apple_store_build = (
            args.publish and apple_store_secrets.issubset(configured_repo_names("secret"))
        )
        if not tag_reused:
            stage = "all-platform release-mode candidate build"
            progress["stage"] = stage
            save_progress()
            candidate = ensure_candidate_build(
                args.version,
                pin_sha,
                execution_profile=args.execution_profile,
                include_apple_store_build=include_apple_store_build,
                **({"include_webos_build": False} if args.skip_webos_build else {}),
            )
            progress["candidate_build_run"] = candidate["databaseId"]
            stage = "release tag"
            progress["stage"] = stage
            save_progress()
            tag = ensure_tag(worktree, args.version, pin_sha)
        else:
            stage = "reuse immutable release tag"
            progress["stage"] = stage
            save_progress()
        progress["tag"] = tag
        stage = "all-platform release build"
        progress["stage"] = stage
        save_progress()
        release = ensure_release(
            tag,
            pin_sha,
            include_webos_release=args.include_webos_release,
            execution_profile=args.execution_profile,
            include_apple_store_build=include_apple_store_build,
            **({"reuse_platform_run_id": args.reuse_platform_run} if args.reuse_platform_run else {}),
            **({"reuse_android_run_id": args.reuse_android_run} if args.reuse_android_run else {}),
            **({"include_webos_build": False} if args.skip_webos_build else {}),
        )
        progress["release_run"] = release["databaseId"]
        progress["release_url"] = f"https://github.com/{PLEZY_REPO}/releases/tag/{tag}"

        stage = "release asset validation"
        progress["stage"] = stage
        save_progress()
        validate_release_outputs(
            tag,
            args.version,
            include_webos_release=args.include_webos_release,
            execution_profile=args.execution_profile,
            include_apple_store_build=include_apple_store_build,
        )

        published_channels: list[dict] = []
        skipped_channels: list[dict] = []
        channel_failures: list[str] = []
        release_published = False
        if args.publish or args.publish_github_only:
            ensure_remote_main_sha(pin_sha, f"publishing PlezyNG {tag}")
            stage = "publish GitHub release"
            progress["stage"] = stage
            save_progress()
            publish_github_release(tag)
            release_published = True
            progress["release_published"] = True
            if args.publish:
                stage = "publish configured release channels"
                progress["stage"] = stage
                save_progress()
                published_channels, skipped_channels, channel_failures = publish_configured_channels(
                    tag,
                    args.version,
                    release_sha=pin_sha,
                    include_webos_release=args.include_webos_release,
                )
                progress["published_channels"] = published_channels
                progress["skipped_channels"] = skipped_channels
                progress["channel_failures"] = channel_failures
                save_progress()
                if channel_failures:
                    raise ReleaseError("Release channel publication failures:\n- " + "\n- ".join(channel_failures))
            else:
                skipped_channels = [{"channel": "configured release channels", "reason": "GitHub-only publication requested"}]
        else:
            metadata = release_metadata(tag)
            release_published = not metadata.get("draft") and bool(metadata.get("published_at"))

        summary = {
            "version": args.version,
            "tag": tag,
            "native_manifest_commit": native_sha,
            "ffmpeg_version": ffmpeg_version,
            "ffmpeg_source_sha256": ffmpeg_sha256,
            "plezyng_commit": pin_sha,
            "ci_run": ci["databaseId"],
            "release_run": release["databaseId"],
            "release_url": f"https://github.com/{PLEZY_REPO}/releases/tag/{tag}",
            "release_published": release_published,
            "published_channels": published_channels,
            "skipped_channels": skipped_channels,
            "webos_built": True,
            "webos_attached_to_public_release": args.include_webos_release,
            "tizen_built": True,
            "tizen_seller_office_submission": "not configured; tester artifact only",
            "microsoft_store": "not configured; package identity variables are absent",
            "runner_pool": "private broker pool for constrained jobs",
            "execution_profile": args.execution_profile,
            "publication_scope": "github-and-configured-channels" if args.publish else "github-only" if args.publish_github_only else "draft-only",
        }
        progress.update(summary)
        progress["status"] = "success"
        progress["stage"] = "complete"
        save_progress()
        summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        print("\nRelease orchestration completed:")
        print(json.dumps(summary, indent=2))
        print(f"Evidence: {summary_path}")
        return 0
    except Exception as error:
        progress["status"] = "failed"
        progress["stage"] = stage
        progress["error"] = str(error)
        save_progress()
        failure_path = scratch / "release-failure.json"
        failure_path.write_text(
            json.dumps({"failed_at": stage, "error": str(error)}, indent=2) + "\n",
            encoding="utf-8",
        )
        raise
    finally:
        if worktree is not None:
            command(["git", "worktree", "remove", "--force", worktree], cwd=ROOT, check=False, quiet=True)
        # Remove only the checkouts and downloads this run created; keep receipts.
        for name in ("mpv-build", "plezyng-main", "ffmpeg"):
            child = scratch / name
            if child.is_symlink() or child.is_file():
                child.unlink(missing_ok=True)
            elif child.is_dir():
                shutil.rmtree(child, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReleaseError as error:
        print(f"release orchestration stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
