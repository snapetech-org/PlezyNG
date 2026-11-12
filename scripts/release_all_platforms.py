#!/usr/bin/env python3
"""Orchestrate a native dependency refresh and the complete Pleazyng release.

This is a local control-plane command. Pleazyng 3.0.0 uses compatible
GitHub-hosted runners by default, private Apple JIT for needs the hosted pool
cannot meet, and private JIT for WebOS storage or other private requirements.
It uses the operator's authenticated
`gh` CLI session and never copies credentials into the repos.
With --publish, it promotes the verified draft and runs every configured
package/store publication workflow from main, sequentially and idempotently.
"""

from __future__ import annotations

import argparse
from release_coverage import missing_assets
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
import launch_queued_apple_jit_jobs as apple_queue
from verify_tvos_runner_acquisition import RunnerAcquisitionError, verify_unacquired_hosted_tvos_run


ROOT = Path(__file__).resolve().parents[1]
PLEZY_REPO = "snapetech-org/pleazyng"
MPV_REPO = "snapetech-org/mpv-build"
MPV_WORKFLOW = "publish.yml"
CI_WORKFLOW = "ci.yml"
RELEASE_WORKFLOW = "build.yml"
NATIVE_GROUPS = ("apple", "android", "linux", "windows")
FFMPEG_SIGNING_FINGERPRINT = "FCF986EA15E6E293A5644F10B4322F04D67658D8"
DOWNLOAD_ATTEMPTS = 4
DOWNLOAD_RETRY_INITIAL_DELAY_SECONDS = 1
HOSTED_TVOS_QUEUE_TIMEOUT_SECONDS = 10 * 60
APPLE_JIT_EVIDENCE_ROOT: Path | None = None
RELEASE_TAG_REUSE_ALLOWLIST = frozenset({
    "tools/webos/NATIVE-PREFLIGHT.md",
    "webos/CMakeLists.txt", "scripts/verify_webos_link_patch.py", "scripts/test_verify_webos_link_patch.py",
    "tools/webos/check_audio_plugin_syntax.sh",
    "scripts/fetch_linux_libmpv.py",
    "scripts/fetch_dv_tools.py",

    "tools/webos/build_release_candidate.sh",
    "windows/tool/download-pinned-mpv.ps1",
    "windows/tool/download-pinned-simdutf.ps1",
    "windows/tool/download-pinned-winsparkle.ps1",
    "windows/tool/download-pinned-sdl3.ps1",
    "windows/tool/download-pinned-torrent-dependencies.ps1",
    "windows/tool/prepare-build-toolchain.ps1",

    "windows/tool/install-patched-engine.ps1",
    "scripts/checks/check_codegen.py", "scripts/checks/test_check_codegen.py",
    "scripts/checks/check_capability_manifest.py",
    "tools/webos/package_ipk.py",
    "tools/webos/verify_package.py",
    "tools/webos/tests/test_package_ipk.py",
    "scripts/tizen/package.py",
    "scripts/tizen/test_package.py",
    "scripts/ci_guard_checks.sh",
    "scripts/prepare_native_downloads.py",
    "scripts/test_prepare_native_downloads.py",

    "scripts/retain_macos_app.py", "scripts/test_retain_macos_app.py",
    "scripts/recover_macos_app.py",
    "scripts/test_recover_macos_app.py",
    "scripts/apple/prepare_macos_app_for_signing.py",
    "scripts/apple/test_prepare_macos_app_for_signing.py",
    "scripts/checks/test_macos_validation_request.py",
    "scripts/checks/test_macos_packaging_recovery.py",
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
    "scripts/checks/test_release_core_publication.py",
    "scripts/checks/test_apple_jit_queue.py",
    "scripts/checks/test_verify_tvos_runner_acquisition.py",
    "scripts/launch_apple_jit_runner.sh",
    "scripts/cleanup_apple_jit_derived_data.py",
    "scripts/apple_jit_process_tree.py",
    "scripts/cleanup_apple_jit_scratch.sh",
    "scripts/checks/test_apple_jit_process_tree.py",
    "scripts/copy_apple_jit_sources.py",
    "scripts/checks/test_copy_apple_jit_sources.py",
    "scripts/launch_queued_apple_jit_jobs.py",
    "scripts/prepare_android_sdk.py", "scripts/test_prepare_android_sdk.py",
    "scripts/prepare_gradle_repositories.py", "scripts/run_android_build.py",
    "scripts/gradle/plezyng-maven-mirror.init.gradle",
    "scripts/checks/test_prepare_gradle_repositories.py",
    "scripts/recover_release_platforms.py",
    "scripts/checks/test_recover_release_platforms.py",
    "scripts/release_all_platforms.py",
    "scripts/release_coverage.py",
    "scripts/verify_tvos_runner_acquisition.py",
    "scripts/checks/test_release_platform_coverage.py",
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


def packaging_repair_was_validation_only(run: dict) -> bool:
    """Prove a completed repair never reached build or publication execution."""
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        return False
    run_id = run["id"]
    pages = gh_json("api", "--paginate", "--slurp",
                    f"repos/{PLEZY_REPO}/actions/runs/{run_id}/jobs?filter=all&per_page=100")
    if (not isinstance(pages, list) or not pages or any(not isinstance(page, dict)
            or not isinstance(page.get("jobs"), list) for page in pages)):
        raise ReleaseError("Cannot prove validation-only repair job inventory is complete.")
    jobs = [job for page in pages for job in page["jobs"]]
    if any(page.get("total_count") != len(jobs) for page in pages):
        raise ReleaseError("Validation-only repair job inventory is truncated.")
    validation = [job for job in jobs if job.get("name") == "Validate release request"]
    if (len(validation) != 1 or validation[0].get("status") != "completed"
            or validation[0].get("conclusion") != "success"):
        return False
    required = {"Verify approved frozen packaging checkout", "Verify reusable platform source"}
    steps = validation[0].get("steps", [])
    if any(not any(step.get("name") == name and step.get("status") == "completed"
                   and step.get("conclusion") == "success" for step in steps) for name in required):
        return False
    others = [job for job in jobs if job is not validation[0]]
    # Require the release and both repaired platform gates to be represented,
    # even when GitHub did not expand their skipped matrix jobs.
    if not {"create-release", "build-ios", "Build tvOS developer package (arm64)"}.issubset(
            {job.get("name") for job in others}):
        return False
    if any(job.get("status") != "completed" or job.get("conclusion") != "skipped"
           or job.get("steps") != [] for job in others):
        return False
    artifacts = gh_json("api", f"repos/{PLEZY_REPO}/actions/runs/{run_id}/artifacts?per_page=100")
    if artifacts.get("total_count") != 0 or artifacts.get("artifacts") != []:
        return False
    print(f"Preserving validation-only repair run {run_id}: approved validation succeeded; "
          f"all {len(others)} other jobs skipped without steps; artifact inventory empty. "
          "A corrected workflow snapshot may retry the same immutable packaging source.")
    return True


def matching_packaging_repair_run(title: str) -> dict | None:
    """Find this immutable repair across later main snapshots, without duplicates."""
    pages = gh_json("api", "--paginate", "--slurp",
                    f"repos/{PLEZY_REPO}/actions/workflows/{RELEASE_WORKFLOW}/runs?branch=main&event=workflow_dispatch&per_page=100")
    if not isinstance(pages, list) or any(not isinstance(page, dict)
            or not isinstance(page.get("workflow_runs"), list) for page in pages):
        raise ReleaseError("Cannot prove the packaging repair run inventory is complete.")
    runs = [run for page in pages for run in page["workflow_runs"]]
    if any(page.get("total_count", len(runs)) > len(runs) for page in pages):
        raise ReleaseError("Packaging repair run inventory is truncated; refusing another dispatch.")
    matches = [run for run in runs if run.get("display_title") == title]
    real_matches = []
    for run in matches:
        if (run.get("event") != "workflow_dispatch" or run.get("head_branch") != "main"
            or run.get("path", "").split("@")[0] != ".github/workflows/build.yml"
            or (run.get("head_repository") or {}).get("full_name") != PLEZY_REPO
            or not isinstance(run.get("id"), int)
            or re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", "")) is None):
            raise ReleaseError("Packaging repair run has an unexpected workflow or source identity.")
        if not packaging_repair_was_validation_only(run):
            real_matches.append(run)
    if len(real_matches) > 1:
        raise ReleaseError("Multiple runs already claim this packaging repair; inspect their side effects.")
    if not real_matches:
        return None
    run = real_matches[0]
    return {"databaseId": run["id"], "headSha": run["head_sha"],
            "headBranch": "main", "event": run["event"], "status": run["status"],
            "conclusion": run.get("conclusion"), "url": run.get("html_url")}


def failed_build_has_drained(run: dict, jobs: list[dict]) -> bool:
    """Cancel only obsolete queued Apple work, after all other consumers finish."""
    if not apple_queue.is_failed_release_build(run, jobs):
        return False
    if any(job.get("name") == "create-release" and job.get("status") == "completed"
           and job.get("conclusion") != "skipped" for job in jobs):
        return False  # Release creation may already have external side effects.
    return all(
        job.get("status") == "completed"
        or (job.get("status") == "queued" and (
            apple_queue.is_apple_job(job, str(run.get("id")))
            or job.get("name") == "create-release"
        ))
        for job in jobs
    )


def timed_out_unassigned_hosted_tvos_job(jobs: list[dict], *, now_utc=None) -> int | None:
    """Return a tvOS job ID only after ten minutes queued without a runner or steps."""
    matches = [job for job in jobs if job.get("name") == "Build tvOS developer package (arm64)"]
    if len(matches) != 1:
        return None
    job = matches[0]
    if (job.get("status") not in {"queued", "waiting", "requested", "pending"}
            or not isinstance(job.get("labels"), list) or "macos-26" not in job["labels"]
            or job.get("runner_id") not in (None, 0)
            or job.get("runner_name") not in (None, "")
            or not isinstance(job.get("steps"), list) or job["steps"]
            or type(job.get("id")) is not int or job["id"] < 1):
        return None
    stamp = job.get("created_at")
    if not isinstance(stamp, str):
        return None
    try:
        queued_at = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    if queued_at.tzinfo is None:
        return None
    now = now_utc or dt.datetime.now(dt.timezone.utc)
    age = (now.astimezone(dt.timezone.utc) - queued_at.astimezone(dt.timezone.utc)).total_seconds()
    if age < HOSTED_TVOS_QUEUE_TIMEOUT_SECONDS:
        return None
    return job["id"]


def hosted_tvos_workflow_drained(jobs: list[dict]) -> bool:
    """Allow whole-run cancellation only after all platform work and assembly side effects are drained."""
    assemblies = [job for job in jobs if job.get("name") == "create-release"]
    if len(assemblies) > 1:
        return False
    for job in jobs:
        if job.get("name") == "Build tvOS developer package (arm64)":
            continue
        if job.get("name") == "create-release":
            if job.get("status") == "completed" and job.get("conclusion") == "skipped":
                continue
            if (job.get("status") in {"queued", "waiting", "requested", "pending"}
                    and job.get("runner_id") in (None, 0)
                    and job.get("runner_name") in (None, "")
                    and isinstance(job.get("steps"), list) and not job["steps"]):
                continue
            return False
        if job.get("status") != "completed" or job.get("conclusion") not in {"success", "skipped"}:
            return False
    return True


def trusted_release_workflow_run(run: dict, repository: str) -> bool:
    """Limit hosted-queue fallback to an exact release build on trusted main."""
    head_repository = run.get("head_repository")
    path = run.get("path")
    title = run.get("display_title")
    return (
        run.get("event") == "workflow_dispatch"
        and run.get("head_branch") == "main"
        and isinstance(head_repository, dict)
        and head_repository.get("full_name") == repository
        and isinstance(path, str)
        and path.split("@", 1)[0] == ".github/workflows/build.yml"
        and isinstance(title, str)
        and (
            title.startswith("action:build:pool:private:mode:release:version:")
            or title.startswith("action:release:pool:private:tag:v")
        )
    )


def wait_for_run(repo: str, run: dict, purpose: str, *, private_apple: bool = True,
                 allow_failure: bool = False, watch_hosted_tvos: bool = False) -> dict:
    run_id = str(run["databaseId"])
    print(f"\n{purpose}: {run.get('url', f'https://github.com/{repo}/actions/runs/{run_id}')}", flush=True)
    apple_controller: subprocess.Popen[bytes] | None = None
    if repo == PLEZY_REPO and private_apple:
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

    next_drain_check = 0.0
    cancellation_requested = False
    hosted_tvos_cancel_requested = False
    next_hosted_queue_check = 0.0
    watch_failures = 0
    while True:
        watcher = subprocess.Popen(
            ["gh", "run", "watch", run_id, "--repo", repo, "--interval", "30", "--exit-status"],
            cwd=ROOT,
        )
        while watcher.poll() is None:
            if watch_hosted_tvos and not hosted_tvos_cancel_requested and time.monotonic() >= next_hosted_queue_check:
                next_hosted_queue_check = time.monotonic() + 30
                try:
                    overview = gh_json("api", f"repos/{repo}/actions/runs/{run_id}")
                    if (overview.get("id") == int(run_id)
                            and overview.get("status") != "completed"
                            and trusted_release_workflow_run(overview, repo)):
                        inventory = gh_json("api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")
                        jobs = inventory.get("jobs", [])
                        complete = (isinstance(jobs, list) and all(isinstance(job, dict) for job in jobs)
                                    and inventory.get("total_count", len(jobs)) <= len(jobs))
                        tvos_job_id = timed_out_unassigned_hosted_tvos_job(jobs) if complete else None
                        if tvos_job_id is not None and hosted_tvos_workflow_drained(jobs):
                            # Re-read just before whole-run cancellation so a runner
                            # assigned between the first snapshot and this decision
                            # is not interrupted as an acquisition failure.
                            confirmation = gh_json("api", f"repos/{repo}/actions/runs/{run_id}")
                            if (confirmation.get("id") == int(run_id)
                                    and confirmation.get("status") != "completed"
                                    and trusted_release_workflow_run(confirmation, repo)):
                                confirmed = gh_json(
                                    "api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100"
                                )
                                confirmed_jobs = confirmed.get("jobs", [])
                                confirmed_complete = (
                                    isinstance(confirmed_jobs, list)
                                    and all(isinstance(job, dict) for job in confirmed_jobs)
                                    and confirmed.get("total_count", len(confirmed_jobs)) <= len(confirmed_jobs)
                                )
                                confirmed_tvos_job_id = (
                                    timed_out_unassigned_hosted_tvos_job(confirmed_jobs)
                                    if confirmed_complete else None
                                )
                                if (confirmed_tvos_job_id == tvos_job_id
                                        and hosted_tvos_workflow_drained(confirmed_jobs)):
                                    print(
                                        f"Hosted tvOS job {tvos_job_id} has waited at least "
                                        f"{HOSTED_TVOS_QUEUE_TIMEOUT_SECONDS // 60} minutes without a runner; "
                                        "all other platform jobs passed, and release assembly has not started. "
                                        "Canceling the drained run so the release controller can retry privately.",
                                        flush=True,
                                    )
                                    command(["gh", "run", "cancel", run_id, "--repo", repo])
                                    hosted_tvos_cancel_requested = True
                except ReleaseError as error:
                    print(f"Could not check hosted tvOS runner acquisition: {error}; preserving the job and retrying.",
                          flush=True)
            if apple_controller is not None:
                controller_code = apple_controller.poll()
                if controller_code not in (None, 0):
                    watcher.terminate()
                    watcher.wait(timeout=30)
                    raise ReleaseError(
                        f"Apple JIT queue controller failed with exit code {controller_code}; "
                        "the GitHub workflow was left running and was not canceled."
                    )
                if controller_code == 0 and not cancellation_requested and time.monotonic() >= next_drain_check:
                    next_drain_check = time.monotonic() + 15
                    try:
                        overview = gh_json("api", f"repos/{repo}/actions/runs/{run_id}")
                        if overview.get("status") != "completed":
                            inventory = gh_json("api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")
                            jobs = inventory.get("jobs", [])
                            complete = (isinstance(jobs, list) and all(isinstance(job, dict) for job in jobs)
                                        and inventory.get("total_count", len(jobs)) <= len(jobs))
                            if complete and failed_build_has_drained(overview, jobs):
                                print("Failed build drained; canceling only its remaining queued Apple jobs.", flush=True)
                                command(["gh", "run", "cancel", run_id, "--repo", repo])
                                cancellation_requested = True
                    except ReleaseError:
                        print("Could not confirm failed-build drainage; preserving the workflow and retrying.", flush=True)
            time.sleep(3)
        watch_code = watcher.wait()
        if watch_code == 0:
            break
        try:
            overview = gh_json("api", f"repos/{repo}/actions/runs/{run_id}")
        except ReleaseError:
            overview = {}
        if overview.get("status") == "completed":
            if overview.get("conclusion") == "success":
                break
            if allow_failure:
                break
            raise ReleaseError(f"{purpose} did not succeed: {overview.get('conclusion') or 'unknown'}")
        # A confirmed active run is healthy even when the watch endpoint fails.
        # Count only consecutive failures to confirm its state.
        watch_failures = 0 if overview.get("status") in {
            "queued", "in_progress", "waiting", "requested", "pending"
        } else watch_failures + 1
        if watch_failures >= 6:
            raise ReleaseError(f"gh run watch repeatedly failed for active run {run_id}; preserve and resume it later.")
        print(f"GitHub watch failed for active run {run_id}; retrying status watch.", flush=True)
        time.sleep(10)
    if apple_controller is not None:
        controller_code = apple_controller.wait()
        if controller_code:
            raise ReleaseError(
                f"Apple JIT queue controller failed with exit code {controller_code}; "
                "inspect its per-run evidence before retrying."
            )
    updated = gh_json("run", "view", run_id, "--repo", repo,
                      "--json", "databaseId,status,conclusion,headSha,headBranch,event,url,jobs")
    if updated.get("status") != "completed" or (updated.get("conclusion") != "success" and not allow_failure):
        raise ReleaseError(f"{purpose} did not succeed: {updated.get('conclusion') or updated.get('status')}")
    return updated


def dispatch(repo: str, workflow: str, ref: str, fields: dict[str, str], purpose: str,
             *, expected_title: str | None = None, expected_sha: str | None = None,
             wait: bool = True, allow_failure: bool = False,
             watch_hosted_tvos: bool = False) -> dict:
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
            if not wait:
                return run
            private_apple = (fields.get("execution_profile") != "hybrid"
                             or fields.get("apple_runner_pool") == "private"
                             or fields.get("tvos_runner_pool") == "private")
            return wait_for_run(repo, run, purpose, private_apple=private_apple,
                                allow_failure=allow_failure,
                                watch_hosted_tvos=watch_hosted_tvos and not private_apple)
        time.sleep(5)
    raise ReleaseError(f"Workflow dispatch succeeded, but its run was not visible: {repo}/{workflow} on {ref}")


def active_run(repo: str, workflow: str, *, ref: str) -> dict | None:
    active_states = {"queued", "in_progress", "waiting", "requested", "pending"}
    for run in workflow_runs(repo, workflow, ref=ref):
        if run.get("status") in active_states:
            return run
    return None


def select_apple_runner_pool(requested: str) -> str:
    """Use compatible public macOS first; recover to private JIT after proven non-acquisition."""
    if requested != "auto":
        return requested
    print(
        "Apple route: selecting compatible GitHub-hosted macOS. If GitHub cancels tvOS before "
        "runner acquisition, the release controller will verify the job record and retry on private Apple JIT.",
        flush=True,
    )
    return "hosted"


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
    request = urllib.request.Request(url, headers={"User-Agent": "Pleazyng-release-orchestrator/1"})
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

    if verify_native_groups(checkout):
        sync_native_asset_bases(checkout)
        verify_native_release_assets(checkout)
        native_sha = command(["git", "rev-parse", "HEAD"], cwd=checkout, capture=True).stdout.strip()
        print(f"Reusing all verified native components at {native_sha[:12]}.")
        return checkout, native_sha

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
            "No Pleazyng pin was changed."
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


def create_plezy_worktree(scratch: Path, *, source_ref: str = "origin/main") -> Path:
    worktree = scratch / "plezyng-main"
    command(["git", "fetch", "origin", "main"], cwd=ROOT)
    command(["git", "worktree", "add", "--detach", worktree, source_ref], cwd=ROOT)
    return worktree


def validate_source_metadata(worktree: Path, version: str) -> None:
    declared = command(["python3", "scripts/pubspec_version.py", "pubspec.yaml"],
                       cwd=worktree, capture=True).stdout.strip().split("+", 1)[0]
    if declared != version:
        raise ReleaseError(f"Requested {version}, but selected source declares {declared}.")
    command(["python3", "tools/webos/verify_package.py", "--project-metadata"], cwd=worktree)


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


def ensure_ci(commit_sha: str, *, execution_profile: str = "hybrid", source_ref: str = "main",
              apple_runner_pool: str = "auto") -> dict:
    apple_runner_pool = select_apple_runner_pool(apple_runner_pool)
    if source_ref != "main":
        ensure_frozen_release_source(source_ref, commit_sha)
    existing = matching_run(PLEZY_REPO, CI_WORKFLOW, commit_sha, ref=source_ref)
    if existing:
        if existing.get("status") == "completed" and existing.get("conclusion") != "success":
            raise ReleaseError(f"CI for release commit {commit_sha[:12]} failed; refusing to tag it.")
        if existing.get("status") != "completed":
            existing = wait_for_run(PLEZY_REPO, existing, "Pleazyng CI",
                                    private_apple=execution_profile != "hybrid" or apple_runner_pool == "private")
        if execution_profile != "hybrid" or run_has_successful_job(
            PLEZY_REPO, existing, "Windows native reliability (arm64)"
        ):
            print(f"Reusing successful CI run {existing['databaseId']} for {commit_sha[:12]}.")
            return existing
        print(
            f"CI run {existing['databaseId']} passed without the required Windows ARM64 job; "
            "dispatching the hybrid profile."
        )
    fields = {"action": "ci", "runner_pool": "private", "execution_profile": execution_profile,
              "build_linux_packages": "true"}
    fields["apple_runner_pool"] = apple_runner_pool
    return dispatch(
        PLEZY_REPO,
        CI_WORKFLOW,
        source_ref,
        fields,
        "Pleazyng CI",
        expected_title="action:ci:pool:private",
        expected_sha=commit_sha,
    )


def candidate_build_title(version: str) -> str:
    return f"action:build:pool:private:mode:release:version:{version}"


def candidate_build_runner_retry_title(version: str, failed_run_id: int) -> str:
    return f"{candidate_build_title(version)}:runner-retry-of:{failed_run_id}"


def ensure_candidate_build(
    version: str,
    commit_sha: str,
    *,
    execution_profile: str = "hybrid",
    include_apple_store_build: bool = False,
    prepare_homebrew_cask: bool = False,
    include_webos_build: bool = True,
    tvos_runner_pool: str = "auto",
) -> dict:
    """Require a complete nonpublishing release-mode build before creating the immutable tag."""
    watch_hosted_tvos = tvos_runner_pool == "auto"
    tvos_runner_pool = select_apple_runner_pool(tvos_runner_pool)
    purpose = f"Pleazyng {version} all-platform release-mode candidate"

    def candidate_complete(run: dict) -> bool:
        complete = execution_profile != "hybrid" or run_has_successful_job(
            PLEZY_REPO, run, "Build Windows (arm64)"
        )
        if include_apple_store_build:
            complete = complete and all(
                run_has_successful_step(PLEZY_REPO, run, job_name, step_name)
                for job_name, step_name in (
                    ("build-ios", "Build signed iOS App Store IPA"),
                    ("Build tvOS developer package (arm64)", "Build signed tvOS App Store IPA"),
                )
            )
        if prepare_homebrew_cask:
            complete = complete and all(
                run_has_successful_step(PLEZY_REPO, run, job_name, step_name)
                for job_name, step_name in (
                    ("build-macos", "Notarize Application"),
                    ("build-macos", "Verify Gatekeeper acceptance for Homebrew Cask"),
                )
            )
        return complete

    def candidate_fields(pool: str, retry_of: int | None = None) -> dict[str, str]:
        fields = {
            "action": "build",
            "runner_pool": "private",
            "execution_profile": execution_profile,
            "mode": "release",
            "build_version": version,
            "include_webos_build": "true" if include_webos_build else "false",
            "include_webos_release": "true",
            "include_tizen_build": "true",
            "include_apple_store_build": "true" if include_apple_store_build else "false",
            "tvos_runner_pool": pool,
            "subtitle_gpu_backend": "cpu",
            "prepare_homebrew_cask": "true" if prepare_homebrew_cask else "false",
        }
        if retry_of is not None:
            fields["reuse_repaired_run_id"] = str(retry_of)
            fields["rebuild_tvos"] = "true"
        return fields

    source = matching_run(
        PLEZY_REPO, RELEASE_WORKFLOW, commit_sha, ref="main",
        expected_title=candidate_build_title(version),
    )
    retry_of: int | None = None
    if source and source.get("status") == "completed" and source.get("conclusion") != "success":
        try:
            verify_unacquired_hosted_tvos_run(
                source["databaseId"], commit_sha, version, action="build"
            )
        except RunnerAcquisitionError as error:
            raise ReleaseError(
                f"Release-mode candidate run {source['databaseId']} concluded "
                f"{source.get('conclusion')}; the failure was not a verified hosted tvOS "
                f"runner-acquisition cancellation ({error}). Refusing to tag it."
            ) from error
        retry_of = source["databaseId"]
        print(
            f"GitHub canceled tvOS before assigning a runner in candidate run {retry_of}; "
            "retrying the exact source with the private Apple JIT route.", flush=True
        )

    if retry_of is not None:
        tvos_runner_pool = "private"
    run_title = (candidate_build_runner_retry_title(version, retry_of)
                 if retry_of is not None else candidate_build_title(version))
    existing = (source if retry_of is None else matching_run(
        PLEZY_REPO, RELEASE_WORKFLOW, commit_sha, ref="main", expected_title=run_title,
    ))
    if existing:
        if existing.get("status") != "completed":
            existing = wait_for_run(
                PLEZY_REPO, existing, purpose, private_apple=tvos_runner_pool == "private",
                allow_failure=True,
                watch_hosted_tvos=watch_hosted_tvos and tvos_runner_pool == "hosted",
            )
        if existing.get("conclusion") != "success":
            if retry_of is not None or source is None or existing.get("databaseId") != source.get("databaseId"):
                raise ReleaseError(
                    f"Release-mode candidate retry run {existing['databaseId']} concluded "
                    f"{existing.get('conclusion')}; refusing to tag an unvalidated commit."
                )
            try:
                verify_unacquired_hosted_tvos_run(
                    source["databaseId"], commit_sha, version, action="build"
                )
            except RunnerAcquisitionError as error:
                raise ReleaseError(
                    f"Release-mode candidate run {source['databaseId']} concluded "
                    f"{existing.get('conclusion')}; the failure was not a verified hosted tvOS "
                    f"runner-acquisition cancellation ({error}). Refusing to tag it."
                ) from error
            retry_of = source["databaseId"]
            print(
                f"GitHub canceled tvOS before assigning a runner in candidate run {retry_of}; "
                "retrying the exact source with the private Apple JIT route.", flush=True
            )
            tvos_runner_pool = "private"
            run_title = candidate_build_runner_retry_title(version, retry_of)
            existing = matching_run(
                PLEZY_REPO, RELEASE_WORKFLOW, commit_sha, ref="main", expected_title=run_title,
            )
            if existing and existing.get("status") != "completed":
                existing = wait_for_run(
                    PLEZY_REPO, existing, purpose, private_apple=True, allow_failure=True,
                )
            if existing and existing.get("conclusion") != "success":
                raise ReleaseError(
                    f"Release-mode candidate retry run {existing['databaseId']} concluded "
                    f"{existing.get('conclusion')}; refusing to tag an unvalidated commit."
                )
        if existing:
            if candidate_complete(existing):
                print(f"Reusing successful release-mode candidate run {existing['databaseId']} for {version}.")
                return existing
            print(
                f"Candidate run {existing['databaseId']} passed without all requested platform jobs; "
                "dispatching the required profile."
            )

    active = active_run(PLEZY_REPO, RELEASE_WORKFLOW, ref="main")
    if active:
        raise ReleaseError(
            f"Pleazyng build workflow run {active['databaseId']} is still {active.get('status')}; "
            "wait for it to finish before dispatching the release-mode candidate."
        )
    ensure_remote_main_sha(commit_sha, f"dispatching the {version} release-mode candidate")
    if retry_of is not None:
        tvos_runner_pool = "private"
    result = dispatch(
        PLEZY_REPO, RELEASE_WORKFLOW, "main", candidate_fields(tvos_runner_pool, retry_of),
        purpose, expected_title=run_title, expected_sha=commit_sha, allow_failure=True,
        watch_hosted_tvos=watch_hosted_tvos and tvos_runner_pool == "hosted",
    )
    if result.get("conclusion") == "success":
        if candidate_complete(result):
            return result
        raise ReleaseError(
            f"Candidate run {result['databaseId']} succeeded without all requested platform jobs."
        )
    if retry_of is not None:
        raise ReleaseError(
            f"Private tvOS retry {result.get('databaseId')} concluded "
            f"{result.get('conclusion')}; inspect its runner and build evidence."
        )
    try:
        verify_unacquired_hosted_tvos_run(
            result["databaseId"], commit_sha, version, action="build"
        )
    except RunnerAcquisitionError as error:
        raise ReleaseError(
            f"Release-mode candidate run {result.get('databaseId')} concluded "
            f"{result.get('conclusion')}; it was not a verified hosted tvOS runner-acquisition "
            f"failure ({error})."
        ) from error
    return ensure_candidate_build(
        version, commit_sha, execution_profile=execution_profile,
        include_apple_store_build=include_apple_store_build,
        prepare_homebrew_cask=prepare_homebrew_cask,
        include_webos_build=include_webos_build,
        tvos_runner_pool="private",
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

    if "webos/CMakeLists.txt" in changed.split("\0"):
        from verify_webos_link_patch import verify_local
        verify_local(worktree, tag_commit, main_commit)


def release_ci_source(worktree: Path, tag: str, main_commit: str, tag_commit: str | None) -> str:
    """Reuse exact-source CI only after proving the immutable app source unchanged."""
    if tag_commit is None:
        return main_commit
    validate_immutable_release_tag(worktree, tag, tag_commit, main_commit)
    return tag_commit


def ensure_tag(worktree: Path, version: str, commit_sha: str) -> str:
    tag = f"v{version}"
    existing_commit = existing_release_tag_commit(worktree, tag)
    if existing_commit:
        validate_immutable_release_tag(worktree, tag, existing_commit, commit_sha)
        print(f"Reusing immutable tag {tag} at {existing_commit[:12]}.")
        return tag
    command(["git", "tag", "-a", tag, commit_sha, "-m", f"Pleazyng {version}"], cwd=worktree)
    command(["git", "push", "origin", f"refs/tags/{tag}"], cwd=worktree)
    return tag


def ensure_candidate_tag(worktree: Path, version: str, commit_sha: str) -> str:
    tag = f"v{version}-candidate.{commit_sha}"
    existing = existing_release_tag_commit(worktree, tag)
    if existing is not None and existing != commit_sha:
        raise ReleaseError(f"Immutable candidate {tag} points to a different commit.")
    if existing is None:
        command(["git", "tag", "-a", tag, commit_sha, "-m", f"Pleazyng {version} validation candidate"], cwd=worktree)
        command(["git", "push", "origin", f"refs/tags/{tag}"], cwd=worktree)
    ensure_frozen_release_source(tag, commit_sha)
    return tag


def refresh_published_facts(worktree: Path, tag: str, release_sha: str) -> str:
    """Update public availability last, after publication and delivery checks."""
    ensure_remote_main_sha(release_sha, "recording published release facts")
    command(["python3", "scripts/refresh_release_facts.py", "--tag", tag], cwd=worktree)
    paths = ["README.md", "docs/maintainers/capability-manifest.json",
             f"docs/maintainers/releases/{tag}.json", "linux/packaging/nix/release.json"]
    changed = command(["git", "status", "--porcelain", "--", *paths], cwd=worktree,
                      capture=True).stdout.strip()
    if not changed:
        return release_sha
    command(["python3", "scripts/checks/check_capability_manifest.py"], cwd=worktree)
    command(["git", "diff", "--check"], cwd=worktree)
    command(["git", "add", "--", *paths], cwd=worktree)
    # Publication facts are generated documentation. Product code was validated
    # on the immutable tag; the same checker validates these refreshed facts.
    command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m",
             f"docs: record published {tag} platform availability"], cwd=worktree)
    command(["git", "push", "origin", "HEAD:refs/heads/main"], cwd=worktree)
    return command(["git", "rev-parse", "HEAD"], cwd=worktree, capture=True).stdout.strip()


def refresh_latest_published_facts(scratch: Path, tag: str, product_sha: str) -> str:
    """Write availability on fresh main, never push the frozen product checkout."""
    ensure_frozen_release_source(tag, product_sha)
    command(["git", "fetch", "origin", "main"], cwd=ROOT)
    checkout = scratch / "published-facts"
    command(["git", "worktree", "add", "--detach", checkout, "origin/main"], cwd=ROOT)
    removable = False
    try:
        latest_sha = command(["git", "rev-parse", "HEAD"], cwd=checkout, capture=True).stdout.strip()
        result = refresh_published_facts(checkout, tag, latest_sha)
        removable = True
        return result
    except Exception as error:
        evidence = scratch / "published-facts-evidence"
        evidence.mkdir()
        for relative in ("README.md", "docs/maintainers/capability-manifest.json",
                         f"docs/maintainers/releases/{tag}.json", "linux/packaging/nix/release.json"):
            source = checkout / relative
            if source.is_file():
                destination = evidence / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
        head = command(["git", "rev-parse", "HEAD"], cwd=checkout, capture=True).stdout.strip()
        (evidence / "retry.json").write_text(json.dumps(
            {"tag": tag, "product_sha": product_sha, "metadata_commit": head, "error": str(error)},
            indent=2) + "\n")
        removable = True
        raise
    finally:
        if removable:
            command(["git", "worktree", "remove", "--force", checkout], cwd=ROOT, check=False)


def ensure_release(
    tag: str,
    commit_sha: str,
    *,
    include_webos_release: bool,
    execution_profile: str = "hybrid",
    include_apple_store_build: bool = False,
    prepare_homebrew_cask: bool = False,
    reuse_platform_run_id: int | None = None,
    reuse_android_run_id: int | None = None,
    reuse_macos_run_id: int | None = None,
    include_webos_build: bool = True,
    rebuild_linux: bool = False,
    rebuild_macos: bool = False,
    rebuild_tvos: bool = False,
    rebuild_ios: bool = False,
    reuse_repaired_run_id: int | None = None,
    reuse_tvos_run_id: int | None = None,
    reuse_ios_run_id: int | None = None,
    reuse_webos_run_id: int | None = None,
    candidate_ref: str | None = None,
    start_only: bool = False,
    tvos_runner_pool: str = "auto",
    packaging_source_sha: str | None = None,
    workflow_source_sha: str | None = None,
    runner_acquisition_retry_of: int | None = None,
) -> dict:
    watch_hosted_tvos = tvos_runner_pool == "auto"
    tvos_runner_pool = select_apple_runner_pool(tvos_runner_pool)
    if reuse_android_run_id and not reuse_platform_run_id:
        raise ReleaseError("Android reuse requires a verified platform source run.")
    if not include_webos_release or not include_webos_build:
        raise ReleaseError("Every versioned release requires its successful webOS build and public artifact.")
    if candidate_ref:
        if candidate_ref != f"{tag}-candidate.{commit_sha}":
            raise ReleaseError("A captured main build requires its exact version/SHA candidate reference.")
        ensure_frozen_release_source(candidate_ref, commit_sha)
    run_title = f"action:release:pool:private:tag:{tag}"
    repair = packaging_source_sha is not None
    if runner_acquisition_retry_of is not None:
        if (repair or reuse_platform_run_id or reuse_repaired_run_id is not None
                or type(runner_acquisition_retry_of) is not int or runner_acquisition_retry_of < 1):
            raise ReleaseError("A full runner-acquisition retry requires one exact failed release run.")
        run_title += f":runner-retry-of:{runner_acquisition_retry_of}"
        tvos_runner_pool = "private"
    elif not repair and reuse_platform_run_id and rebuild_tvos:
        run_title += f":recovery:source:{reuse_platform_run_id}:tvos"
    if reuse_tvos_run_id and (not repair or rebuild_tvos or reuse_repaired_run_id):
        raise ReleaseError('Signed TV reuse requires approved Apple packaging recovery without another repair source.')
    if reuse_ios_run_id and (not reuse_tvos_run_id or rebuild_ios or reuse_ios_run_id == reuse_tvos_run_id):
        raise ReleaseError('Signed iOS reuse requires two distinct approved Apple sibling sources.')
    existing = None
    if repair:
        if (packaging_source_sha != commit_sha or not reuse_platform_run_id or candidate_ref
                or re.fullmatch(r"[0-9a-f]{40}", packaging_source_sha) is None):
            raise ReleaseError("Packaging recovery requires the exact repair source and original platform run.")
        run_title += f":repair:{packaging_source_sha}"
        existing = matching_packaging_repair_run(run_title)
        workflow_source_sha = (existing["headSha"] if existing else workflow_source_sha)
        if workflow_source_sha is None:
            workflow_source_sha = gh_json("api", f"repos/{PLEZY_REPO}/branches/main")["commit"]["sha"]
    elif not reuse_platform_run_id:
        existing = matching_run(
            PLEZY_REPO,
            RELEASE_WORKFLOW,
            commit_sha,
            ref="main",
            expected_title=run_title,
        )

    def retry_after_unassigned_tvos(failed_run: dict) -> dict:
        source_run_id = failed_run.get("databaseId")
        try:
            verify_unacquired_hosted_tvos_run(
                source_run_id, commit_sha, tag.removeprefix("v"), action="release"
            )
        except RunnerAcquisitionError as error:
            raise ReleaseError(
                f"Release build run {source_run_id} failed, but GitHub evidence does not prove "
                f"a tvOS runner-acquisition cancellation ({error})."
            ) from error
        print(
            f"GitHub canceled tvOS before assigning a runner in release run {source_run_id}; "
            "starting a private Apple recovery from verified platform outputs.", flush=True
        )
        common = {
            "include_webos_release": include_webos_release,
            "execution_profile": execution_profile,
            "include_apple_store_build": include_apple_store_build,
            "prepare_homebrew_cask": prepare_homebrew_cask,
            "include_webos_build": include_webos_build,
            "candidate_ref": candidate_ref,
            "start_only": False,
            "tvos_runner_pool": "private",
        }
        if include_apple_store_build:
            # The signed Apple recovery gate requires a frozen packaging approval.
            # Rebuild all platforms in the retry instead of reusing unsigned checkpoints.
            return ensure_release(
                tag, commit_sha, **common,
                runner_acquisition_retry_of=int(source_run_id),
            )
        return ensure_release(
            tag, commit_sha, **common,
            reuse_platform_run_id=int(source_run_id),
            reuse_android_run_id=int(source_run_id),
            reuse_webos_run_id=int(source_run_id),
            rebuild_tvos=True,
        )

    if (existing and existing.get("status") == "completed"
            and existing.get("conclusion") != "success"
            and not repair and not reuse_platform_run_id
            and runner_acquisition_retry_of is None):
        return retry_after_unassigned_tvos(existing)

    if reuse_platform_run_id:
        if execution_profile != "hybrid" or (include_apple_store_build and not repair):
            raise ReleaseError("Platform recovery requires the hybrid GitHub-only release profile without fresh Apple or Homebrew qualification.")
        options = {}
        if rebuild_linux:
            options["rebuild_linux"] = True
        if rebuild_macos:
            options["rebuild_macos"] = True
        if rebuild_tvos:
            options["rebuild_tvos"] = True
        if rebuild_ios:
            options["rebuild_ios"] = True
        if reuse_repaired_run_id:
            options["repaired_run"] = reuse_repaired_run_id
        if reuse_tvos_run_id:
            options['tvos_run'] = reuse_tvos_run_id
        if reuse_ios_run_id:
            options['ios_run'] = reuse_ios_run_id
        if reuse_webos_run_id:
            options["webos_run"] = reuse_webos_run_id
        if prepare_homebrew_cask and not reuse_macos_run_id:
            options["require_homebrew_cask"] = True
        if reuse_macos_run_id:
            options["macos_run"] = reuse_macos_run_id
        if reuse_android_run_id:
            options["android_run"] = reuse_android_run_id
        if not include_webos_build:
            options["include_webos_build"] = False
        if repair:
            options.update(packaging_source_sha=packaging_source_sha,
                           workflow_source_sha=workflow_source_sha,
                           include_apple_store_build=include_apple_store_build)
        if reuse_android_run_id and not include_webos_build:
            options["wait_complete"] = True
        proof = verify_platform_recovery(reuse_platform_run_id, commit_sha, tag.removeprefix("v"), **options)
        if repair:
            validate_packaging_repair_proof(proof, tag, packaging_source_sha, workflow_source_sha)
        elif reuse_platform_run_id:
            # Validate the source artifacts before looking for or resuming a
            # retry run. An invalid recovery request must not query or reuse a
            # workflow run as a side effect.
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
            if start_only:
                return existing
            existing = wait_for_run(PLEZY_REPO, existing, f"Pleazyng {tag} all-platform release build",
                                    private_apple=tvos_runner_pool == "private", allow_failure=True,
                                    watch_hosted_tvos=(watch_hosted_tvos
                                                       and tvos_runner_pool == "hosted"
                                                       and not repair and not reuse_platform_run_id
                                                       and runner_acquisition_retry_of is None))
            if (existing.get("conclusion") != "success" and not repair
                    and not reuse_platform_run_id and runner_acquisition_retry_of is None):
                return retry_after_unassigned_tvos(existing)
            if existing.get("conclusion") != "success":
                raise ReleaseError(
                    f"Release build run {existing['databaseId']} concluded "
                    f"{existing.get('conclusion')}; it was not re-run automatically."
                )
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
                if not repair or (rebuild_ios if job_name == "build-ios" else rebuild_tvos)
            )
        if prepare_homebrew_cask:
            complete = complete and all(
                run_has_successful_step(PLEZY_REPO, existing, job_name, step_name)
                for job_name, step_name in (
                    *(("build-macos", name) for name in ("Notarize Application", "Verify Gatekeeper acceptance for Homebrew Cask") if (rebuild_macos or not (reuse_macos_run_id or reuse_platform_run_id))),
                    ("create-release", "Generate Homebrew Cask candidate"),
                    ("create-release", "Attest Homebrew Cask candidate"),
                )
            )
        if complete:
            print(f"Reusing successful release build run {existing['databaseId']} for {tag}.")
            return existing
        if repair:
            raise ReleaseError("Existing packaging repair lacks requested signing/qualification steps; refusing a duplicate dispatch.")
        print(
            f"Release run {existing['databaseId']} passed without all requested platform jobs; "
            "dispatching the required profile."
        )
    dispatch_sha = workflow_source_sha if repair else commit_sha
    ensure_remote_main_sha(dispatch_sha, f"dispatching the {tag} release build")
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
        "prepare_homebrew_cask": "true" if prepare_homebrew_cask else "false",
    }
    if candidate_ref:
        fields["candidate_ref"] = candidate_ref
    if repair:
        fields["recovery_source_sha"] = packaging_source_sha
        fields["recovery_product_sha"] = proof["product_source_sha"]
    fields["tvos_runner_pool"] = tvos_runner_pool
    if rebuild_linux:
        fields["rebuild_linux"] = "true"
    if rebuild_macos:
        fields["rebuild_macos"] = "true"
    if rebuild_tvos:
        fields["rebuild_tvos"] = "true"
    if rebuild_ios:
        fields["rebuild_ios"] = "true"
    if reuse_repaired_run_id:
        fields["reuse_repaired_run_id"] = str(reuse_repaired_run_id)
    if reuse_tvos_run_id:
        # The existing dispatch slot carries the two independently verified
        # signed Apple siblings without exceeding GitHub's 25-input limit.
        fields['reuse_repaired_run_id'] = (f'tvos:{reuse_tvos_run_id},ios:{reuse_ios_run_id}'
                                           if reuse_ios_run_id else str(reuse_tvos_run_id))
    if reuse_webos_run_id:
        fields["reuse_webos_run_id"] = str(reuse_webos_run_id)
    if reuse_platform_run_id:
        fields["reuse_platform_run_id"] = str(reuse_platform_run_id)
    if reuse_android_run_id:
        fields["reuse_android_run_id"] = str(reuse_android_run_id)
    if reuse_macos_run_id:
        fields["reuse_macos_package_run_id"] = str(reuse_macos_run_id)
    if runner_acquisition_retry_of is not None:
        fields["reuse_repaired_run_id"] = str(runner_acquisition_retry_of)
        fields["rebuild_tvos"] = "true"
    allow_failure = (not start_only and not repair and not reuse_platform_run_id
                     and runner_acquisition_retry_of is None)
    result = dispatch(
        PLEZY_REPO,
        RELEASE_WORKFLOW,
        "main",
        fields,
        f"Pleazyng {tag} all-platform release build",
        expected_title=run_title,
        expected_sha=dispatch_sha,
        **({"wait": False} if start_only else {}),
        **({"allow_failure": True} if allow_failure else {}),
        watch_hosted_tvos=watch_hosted_tvos and tvos_runner_pool == "hosted" and allow_failure,
    )
    if allow_failure and result.get("conclusion") != "success":
        return retry_after_unassigned_tvos(result)
    if repair and not start_only:
        required_steps = []
        if include_apple_store_build:
            if rebuild_ios:
                required_steps.append(("build-ios", "Build signed iOS App Store IPA"))
            if rebuild_tvos:
                required_steps.append(("Build tvOS developer package (arm64)", "Build signed tvOS App Store IPA"))
        if prepare_homebrew_cask:
            if rebuild_macos:
                required_steps.extend(("build-macos", name) for name in
                                      ("Notarize Application", "Verify Gatekeeper acceptance for Homebrew Cask"))
            required_steps.extend(("create-release", name) for name in
                                  ("Generate Homebrew Cask candidate", "Attest Homebrew Cask candidate"))
        if any(not run_has_successful_step(PLEZY_REPO, result, job, step) for job, step in required_steps):
            raise ReleaseError("Packaging repair completed without every requested signing/qualification step.")
    return result


def verify_platform_recovery(run_id: int, commit_sha: str, version: str, *,
                             android_run=None, macos_run=None, webos_run=None, include_webos_build=True, wait_complete=False,
                             rebuild_linux=False, rebuild_macos=False, rebuild_tvos=False, rebuild_ios=False, repaired_run=None, require_homebrew_cask=False,
                             packaging_source_sha=None, workflow_source_sha=None, include_apple_store_build=False, tvos_run=None, ios_run=None) -> dict:
    from recover_release_platforms import RecoveryError, compose_proof, verify_source_run, wait_for_source_run, verify_macos_packaging_recovery

    if (rebuild_tvos or rebuild_ios) and (macos_run or repaired_run):
        raise ReleaseError("Apple device rebuilding requires ordinary verified platform recovery")
    options = {}
    if tvos_run:
        if not packaging_source_sha or rebuild_tvos or repaired_run or macos_run:
            raise ReleaseError('Signed TV reuse requires approved frozen packaging recovery.')
        options['tvos_run'] = tvos_run
    if ios_run:
        if not tvos_run or rebuild_ios:
            raise ReleaseError('Signed iOS reuse requires approved assembly-only recovery.')
        options['ios_run'] = ios_run
    if rebuild_linux:
        options["rebuild_linux"] = True
    if rebuild_macos:
        options["rebuild_macos"] = True
    if rebuild_tvos:
        options["rebuild_tvos"] = True
    if rebuild_ios:
        options["rebuild_ios"] = True
    if repaired_run:
        options["repaired_run"] = repaired_run
    if require_homebrew_cask:
        options["require_homebrew_cask"] = True
    if packaging_source_sha is not None:
        options.update(packaging_source_sha=packaging_source_sha, workflow_source_sha=workflow_source_sha,
                       include_apple_store_build=include_apple_store_build)
    elif workflow_source_sha is not None or include_apple_store_build:
        raise ReleaseError("Signed packaging recovery requires an approved packaging source.")
    try:
        source = (verify_macos_packaging_recovery(run_id, macos_run, commit_sha, version) if macos_run else
                  wait_for_source_run(run_id, commit_sha, version, 10800, **options) if wait_complete else
                  verify_source_run(run_id, commit_sha, version, allow_pending=True, **options))
        return compose_proof(source, android_run, include_webos_build, webos_run)
    except (RecoveryError, RuntimeError) as error:
        raise ReleaseError(f"Platform artifact recovery rejected: {error}") from error


def validate_packaging_repair_proof(proof: dict, tag: str, packaging_sha: str, workflow_sha: str) -> None:
    if (proof.get("schema_version") != 2
            or proof.get("recovery_policy") != "frozen-apple-packaging-v1"
            or proof.get("packaging_source_sha") != packaging_sha
            or proof.get("workflow_source_sha") != workflow_sha
            or re.fullmatch(r"[0-9a-f]{40}", str(proof.get("product_source_sha", ""))) is None):
        raise ReleaseError("Approved Apple packaging recovery proof is incomplete or mismatched.")
    ensure_frozen_release_source(tag, proof["product_source_sha"])


def verify_packaging_repair_assembly(scratch: Path, tag: str, source_proof: dict, run: dict) -> dict:
    """Bind the assembled recovery receipt to its actual workflow and release bytes."""
    directory = scratch / "packaging-repair-assembly"
    directory.mkdir()
    command(["gh", "release", "download", tag, "--repo", PLEZY_REPO,
             "--pattern", "SHA256SUMS.txt", "--pattern", "platform-reuse-provenance.json",
             "--dir", str(directory)])
    checksums = directory / "SHA256SUMS.txt"
    receipt_path = directory / "platform-reuse-provenance.json"
    workflow_sha = source_proof["workflow_source_sha"]
    result = command(["gh", "attestation", "verify", str(checksums), "--repo", PLEZY_REPO,
                      "--signer-workflow", f"{PLEZY_REPO}/.github/workflows/build.yml",
                      "--source-digest", workflow_sha, "--format", "json"], capture=True)
    verification = json.loads(result.stdout)
    expected_run = f"https://github.com/{PLEZY_REPO}/actions/runs/{run['databaseId']}"
    if not isinstance(verification, list) or not any(
            str(cert.get("sourceRepositoryIdentifier")) == "1433487464"
            and cert.get("sourceRepositoryDigest") == workflow_sha
            and re.fullmatch(re.escape(expected_run) + r"(?:/attempts/[1-9][0-9]*)?",
                             str(cert.get("runInvocationURI", "")))
            for item in verification for cert in
            [item.get("verificationResult", {}).get("signature", {}).get("certificate", {})]):
        raise ReleaseError("Recovery checksums are not attested by the actual assembly run and workflow source.")
    expected = [line.split()[0] for line in checksums.read_text().splitlines()
                if len(line.split()) == 2 and line.split()[1].lstrip("*") == receipt_path.name]
    actual = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
    if expected != [actual]:
        raise ReleaseError("Attested recovery checksums do not uniquely bind the assembly receipt.")
    receipt = json.loads(receipt_path.read_text())
    validate_packaging_repair_proof(receipt, tag, source_proof["packaging_source_sha"], workflow_sha)
    if (receipt["product_source_sha"] != source_proof["product_source_sha"]
            or receipt.get("assembly_run_id") != run["databaseId"]
            or receipt.get("actual_checkout_sha") != source_proof["packaging_source_sha"]
            or receipt.get("source_run_id") != source_proof.get("source_run_id")
            or receipt.get("packaging_approval") != source_proof.get("packaging_approval")
            or re.fullmatch(r"[0-9a-f]{64}", str(receipt.get("linux_archive_sha256", ""))) is None
            or not isinstance(receipt.get("artifacts"), list) or not receipt["artifacts"]):
        raise ReleaseError("Attested recovery receipt differs from its approved sources or assembly identity.")
    expected_tv = source_proof.get('tvos_source')
    actual_tv = receipt.get('tvos_source')
    if expected_tv is not None:
        if (not isinstance(actual_tv, dict)
                or {key: value for key, value in actual_tv.items() if key != 'package_sha256'} != expected_tv):
            raise ReleaseError('Assembled signed TV source differs from independently approved sibling repair.')
        hashes = actual_tv.get('package_sha256', {})
        if set(hashes) != {'pleazyng-tvos-unsigned.ipa', 'pleazyng-tvos-appstore.ipa'}:
            raise ReleaseError('Assembled TV recovery lacks both original attestation-verified package hashes.')
        assets = release_metadata(tag).get('assets', [])
        for name, digest in hashes.items():
            entries = [line.split()[0] for line in checksums.read_text().splitlines()
                       if len(line.split()) == 2 and line.split()[1].lstrip('*') == name]
            published = [asset for asset in assets if asset.get('name') == name]
            if (re.fullmatch('[0-9a-f]{64}', str(digest)) is None or entries != [digest]
                    or len(published) != 1 or published[0].get('digest') != 'sha256:' + digest):
                raise ReleaseError('Published TV package differs from the original attestation-verified recovery bytes.')
    elif actual_tv is not None:
        raise ReleaseError('Assembly introduced an unapproved TV source.')
    expected_ios = source_proof.get('ios_source')
    actual_ios = receipt.get('ios_source')
    if expected_ios is not None:
        if (not isinstance(actual_ios, dict)
                or {key: value for key, value in actual_ios.items() if key != 'package_sha256'} != expected_ios):
            raise ReleaseError('Assembled signed iOS source differs from approved sibling repair.')
        hashes = actual_ios.get('package_sha256', {})
        if set(hashes) != {'pleazyng-ios-unsigned.ipa', 'pleazyng-ios-appstore.ipa'}:
            raise ReleaseError('Assembled iOS recovery lacks attestation-verified package hashes.')
        assets = release_metadata(tag).get('assets', [])
        for name, digest in hashes.items():
            entries = [line.split()[0] for line in checksums.read_text().splitlines()
                       if len(line.split()) == 2 and line.split()[1].lstrip('*') == name]
            published = [asset for asset in assets if asset.get('name') == name]
            if (re.fullmatch('[0-9a-f]{64}', str(digest)) is None or entries != [digest]
                    or len(published) != 1 or published[0].get('digest') != 'sha256:' + digest):
                raise ReleaseError('Published iOS package differs from attestation-verified recovery bytes.')
    elif actual_ios is not None:
        raise ReleaseError('Assembly introduced an unapproved iOS source.')
    names = set()
    for artifact in receipt["artifacts"]:
        name = artifact.get("name")
        source = (source_proof.get('tvos_source', source_proof) if name == 'tvos-ipa' else
                  source_proof.get('ios_source', source_proof) if name == 'ios-ipa' else
                  source_proof.get("android_source", source_proof) if name == "android-apk" else
                  source_proof.get("webos_source", source_proof) if name == "webos-ipk" else source_proof)
        if (not isinstance(name, str) or not name or name in names
                or artifact.get("source_run_id") != source["source_run_id"]
                or artifact.get("source_sha") != source["source_sha"]
                or type(artifact.get("artifact_id")) is not int or artifact["artifact_id"] < 1
                or re.fullmatch(r"sha256:[0-9a-f]{64}", str(artifact.get("digest", ""))) is None):
            raise ReleaseError("Attested recovery artifact record differs from the verified original producer.")
        if name == 'tvos-ipa' and source_proof.get('tvos_source') and (
                artifact['artifact_id'] != source['artifact_id'] or artifact['digest'] != source['artifact_digest']):
            raise ReleaseError('Attested TV artifact differs from the independently approved signed producer.')
        if name == 'ios-ipa' and source_proof.get('ios_source') and (
                artifact['artifact_id'] != source['artifact_id'] or artifact['digest'] != source['artifact_digest']):
            raise ReleaseError('Attested iOS artifact differs from the independently approved signed producer.')
        names.add(name)
    linux = [asset for asset in release_metadata(tag).get("assets", [])
             if asset.get("name") == "pleazyng-linux-x64.tar.gz"]
    if len(linux) != 1 or linux[0].get("digest") != "sha256:" + receipt["linux_archive_sha256"]:
        raise ReleaseError("Published Linux archive differs from the attested recovery receipt.")
    return receipt


def ensure_frozen_release_source(tag: str, expected_sha: str) -> None:
    """Bind the release to its remote tag while permitting later main development."""
    match = re.fullmatch(r"v\d+\.\d+\.\d+(?:-candidate\.([0-9a-f]{40}))?", tag)
    if match is None or (match.group(1) is not None and match.group(1) != expected_sha):
        raise ReleaseError("Frozen releases require an exact version tag or its SHA-bound validation candidate.")
    reference = gh_json("api", f"repos/{PLEZY_REPO}/git/ref/tags/{tag}")
    target = reference.get("object", {})
    if target.get("type") == "tag":
        annotated = gh_json("api", f"repos/{PLEZY_REPO}/git/tags/{target.get('sha')}")
        target = annotated.get("object", {})
    if target.get("type") != "commit" or target.get("sha") != expected_sha:
        raise ReleaseError(f"Immutable release tag {tag} does not resolve to {expected_sha}.")
    ensure_main_ancestor(expected_sha)


def ensure_main_ancestor(expected_sha: str) -> None:
    if re.fullmatch(r"[0-9a-f]{40}", expected_sha) is None:
        raise ReleaseError("Release source must be an exact 40-character commit SHA.")
    ancestry = gh_json("api", f"repos/{PLEZY_REPO}/compare/{expected_sha}...main")
    if (ancestry.get("status") not in ("ahead", "identical")
            or ancestry.get("base_commit", {}).get("sha") != expected_sha):
        raise ReleaseError(f"Release source {expected_sha} is not an ancestor of canonical main.")


def embedded_ci_proof(run_id: int, source_sha: str) -> dict:
    from verify_embedded_release_ci import verify_jobs
    run = gh_json("api", f"repos/{PLEZY_REPO}/actions/runs/{run_id}")
    attempt = run.get("run_attempt")
    if not isinstance(attempt, int) or attempt < 1:
        raise ReleaseError("Captured build omitted its qualification attempt.")
    pages = gh_json("api", "--paginate", "--slurp",
                    f"repos/{PLEZY_REPO}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
    if not isinstance(pages, list) or any(not isinstance(page, dict) or not isinstance(page.get("jobs"), list) for page in pages):
        raise ReleaseError("Captured build omitted its qualification jobs.")
    jobs = [job for page in pages for job in page["jobs"]]
    manifest = json.loads(command(["git", "show", f"{source_sha}:docs/maintainers/capability-manifest.json"],
                                  cwd=ROOT, capture=True).stdout)
    required = manifest["release"]["releaseGate"]["requiredJobs"]
    proof = verify_jobs(run, jobs, source_sha, run_id, attempt, required)
    freeze = [job for job in jobs if job.get("name") == "Freeze qualified source"]
    if len(freeze) != 1 or freeze[0].get("status") != "completed" or freeze[0].get("conclusion") != "success":
        raise ReleaseError("Captured source was not successfully frozen after qualification.")
    return proof


def ensure_remote_main_sha(expected_sha: str, purpose: str) -> None:
    branch = gh_json("api", f"repos/{PLEZY_REPO}/branches/main")
    actual_sha = branch.get("commit", {}).get("sha") if isinstance(branch, dict) else None
    if actual_sha != expected_sha:
        raise ReleaseError(
            f"Cannot continue with {purpose}: Pleazyng main is {actual_sha or 'unavailable'}, "
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


def dispatch_automatic_play(tag: str) -> dict | None:
    """Wake the non-scheduled controller even for token-created releases."""
    if configured_repo_variables().get("GOOGLE_PLAY_AUTOMATIC_RELEASES") != "true":
        return None
    command(["gh", "workflow", "run", "deliver-google-play.yml", "--repo", PLEZY_REPO,
             "--ref", "main", "-f", f"release_tag={tag}"])
    return {"tag": tag, "workflow": "deliver-google-play.yml", "state": "dispatched"}


def dispatch_aerynos_delivery(tag: str) -> dict:
    """Wake the independent qualified package consumer after core publication."""
    command(["gh", "workflow", "run", "reconcile.yml", "--repo", "snapetech-org/pleazyng-aerynos",
             "--ref", "main"])
    return {"tag": tag, "workflow": "reconcile.yml", "repository": "snapetech-org/pleazyng-aerynos",
            "state": "dispatched"}


def post_release_actions(tag: str, version: str, *, release_sha: str,
                         include_webos_release: bool, publish_channels: bool,
                         notify_discord: bool = True) -> dict:
    """Retryable delivery follows the already verified GitHub publication."""
    result = {"published_channels": [], "skipped_channels": [],
              "channel_failures": [], "notification_failures": [], "google_play_automation": [],
              "aerynos_automation": [], "discord_notification_requested": notify_discord}
    try:
        play = dispatch_automatic_play(tag)
        if play:
            result["google_play_automation"].append(play)
    except Exception as error:
        result["channel_failures"].append(f"Automatic Google Play delivery: {error}")
    try:
        result["aerynos_automation"].append(dispatch_aerynos_delivery(tag))
    except Exception as error:
        result["channel_failures"].append(f"Automatic aerynOS delivery: {error}")
    # GITHUB_TOKEN publication does not emit another workflow's release event.
    # Tag serialization and persisted receipts make a repeated dispatch safe.
    if notify_discord:
        try:
            command(["gh", "workflow", "run", "discord-release.yml", "--repo", PLEZY_REPO,
                     "--ref", "main", "-f", "action=announce-release", "-f", "runner_pool=hosted",
                     "-f", f"release_tag={tag}"])
        except Exception as error:
            result["notification_failures"].append(str(error))
    if publish_channels:
        try:
            completed, skipped, failures = publish_configured_channels(
                tag, version, release_sha=release_sha,
                include_webos_release=include_webos_release,
            )
            result["published_channels"].extend(completed)
            result["skipped_channels"].extend(skipped)
            result["channel_failures"].extend(failures)
        except Exception as error:
            result["channel_failures"].append(str(error))
    else:
        result["skipped_channels"] = [{"channel": "configured release channels",
                                       "reason": "GitHub-only publication requested"}]
    return result


def validate_release_outputs(
    tag: str,
    version: str,
    *,
    include_webos_release: bool,
    execution_profile: str = "private",
    include_apple_store_build: bool = False,
    prepare_homebrew_cask: bool = False,
) -> None:
    release = release_metadata(tag)
    assets = {
        asset.get("name")
        for asset in release.get("assets", [])
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    }
    required = {
        "SHA256SUMS.txt", "appcast.xml",
        "pleazyng-android-arm64-v8a.tar.gz", "pleazyng-android-armeabi-v7a.tar.gz", "pleazyng-android-x86_64.tar.gz",
        "pleazyng-ios-unsigned.ipa", "pleazyng-tvos-unsigned.ipa", "pleazyng-macos.dmg",
        "pleazyng-windows-x64-portable.7z", "pleazyng-windows-installer.exe",
        "pleazyng-linux-x64.tar.gz", "pleazyng-linux-x64.deb", "pleazyng-linux-x64.rpm",
        "pleazyng-linux-x64.pkg.tar.zst", "pleazyng-linux-x64.flatpak", "pleazyng-linux-x64.snap",
        "pleazyng-linux-arm64.tar.gz", "pleazyng-linux-arm64.deb", "pleazyng-linux-arm64.rpm",
        "pleazyng-linux-arm64.pkg.tar.zst", "pleazyng-linux-arm64.flatpak", "pleazyng-linux-arm64.snap",
        "pleazyng-linux-x86_64.AppImage",
        "pleazyng-tizen-arm-tester-handoff.zip",
        "pleazyng-amazon-firetv.apk", "pleazyng-amazon-firetv-provenance.json",
    }
    if include_webos_release:
        required.update({
            "webos-SHA256SUMS.txt", "pleazyng-lg-webos-submission.zip",
        })
        if not any(name.endswith(".ipk") for name in assets if isinstance(name, str)):
            required.add("<eligible webOS .ipk>")
    if execution_profile == "hybrid":
        required.add("pleazyng-windows-arm64-portable.zip")

    missing_platforms = missing_assets(assets)
    if missing_platforms:
        raise ReleaseError("Required public platform assets are missing: " + "; ".join(missing_platforms))

    secrets = configured_repo_names("secret")
    android_signing = {
        "ANDROID_KEYSTORE_BASE64", "ANDROID_STORE_PASSWORD", "ANDROID_KEY_PASSWORD", "ANDROID_KEY_ALIAS",
    }
    if android_signing.issubset(secrets):
        required.update({"pleazyng-android-play.aab", "pleazyng-amazon-firetv.apk"})
    if include_apple_store_build:
        required.update({"pleazyng-ios-appstore.ipa", "pleazyng-tvos-appstore.ipa"})
    if prepare_homebrew_cask:
        required.add("snapetech-pleazyng.rb")

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


def configured_repo_variables() -> dict[str, str]:
    rows = gh_json("variable", "list", "--repo", PLEZY_REPO, "--json", "name,value")
    if not isinstance(rows, list):
        raise ReleaseError("Could not read repository publication settings.")
    return {row["name"]: str(row.get("value", "")) for row in rows
            if isinstance(row, dict) and isinstance(row.get("name"), str)}


def play_publication_settings(settings: dict[str, str]) -> tuple[str, str]:
    track = settings.get("GOOGLE_PLAY_TRACK", "internal")
    status = settings.get("GOOGLE_PLAY_RELEASE_STATUS", "draft")
    if track not in {"internal", "alpha", "beta"}:
        raise ReleaseError("Automatic Google Play publication must use an internal or closed testing track.")
    if status not in {"draft", "completed"}:
        raise ReleaseError("Automatic Google Play status must be draft or completed.")
    return track, status


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
    publication_settings = configured_repo_variables()
    variables = set(publication_settings)
    play_error = None
    try:
        play_track, play_status = play_publication_settings(publication_settings)
    except ReleaseError as error:
        play_error = str(error)
        play_track, play_status = "internal", "draft"

    specs = [
        {
            "name": f"Google Play {play_track} {play_status}",
            "readiness_flag": "GOOGLE_PLAY_BOOTSTRAP_COMPLETE",
            "workflow": "publish-app-stores.yml",
            "title": f"action:publish-app-stores:pool:public:tag:{tag}:channel:google-play:track:{play_track}:status:{play_status}",
            "fields": {"action": "publish-app-stores", "runner_pool": "public", "release_tag": tag,
                       "channel": "google-play", "play_track": play_track, "play_release_status": play_status},
            "secrets": {"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"}, "variables": set(),
            "assets": {"pleazyng-android-play.aab", "SHA256SUMS.txt"},
        },
        {
            "name": "Amazon Appstore upload",
            "readiness_flag": "AMAZON_APPSTORE_BOOTSTRAP_COMPLETE",
            "workflow": "publish-app-stores.yml",
            "title": f"action:publish-app-stores:pool:public:tag:{tag}:channel:amazon-appstore",
            "fields": {"action": "publish-app-stores", "runner_pool": "public", "release_tag": tag,
                       "channel": "amazon-appstore", "play_track": "internal", "play_release_status": "draft"},
            "secrets": {"AMAZON_APPSTORE_CLIENT_ID", "AMAZON_APPSTORE_CLIENT_SECRET"}, "variables": {"AMAZON_APPSTORE_APP_ID"},
            "assets": {"pleazyng-amazon-firetv.apk", "SHA256SUMS.txt"},
        },
        {
            "name": "Apple App Store Connect iOS upload",
            "readiness_flag": "APPLE_STORE_UPLOAD_READY",
            "workflow": "publish-app-stores.yml",
            "title": f"action:publish-app-stores:pool:public:tag:{tag}:channel:app-store-ios",
            "fields": {"action": "publish-app-stores", "runner_pool": "public", "release_tag": tag,
                       "channel": "app-store-ios", "play_track": "internal", "play_release_status": "draft"},
            "secrets": {"APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_PRIVATE_KEY"}, "variables": set(),
            "assets": {"pleazyng-ios-appstore.ipa", "SHA256SUMS.txt"},
        },
        {
            "name": "Apple App Store Connect tvOS upload",
            "readiness_flag": "APPLE_STORE_UPLOAD_READY",
            "workflow": "publish-app-stores.yml",
            "title": f"action:publish-app-stores:pool:public:tag:{tag}:channel:app-store-tvos",
            "fields": {"action": "publish-app-stores", "runner_pool": "public", "release_tag": tag,
                       "channel": "app-store-tvos", "play_track": "internal", "play_release_status": "draft"},
            "secrets": {"APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_PRIVATE_KEY"}, "variables": set(),
            "assets": {"pleazyng-tvos-appstore.ipa", "SHA256SUMS.txt"},
        },
        {
            "name": "AUR",
            "workflow": "publish-aur.yml",
            "title": f"action:publish-aur:pool:public:tag:{tag}",
            "fields": {"action": "publish-aur", "runner_pool": "public", "release_tag": tag},
            "secrets": {"AUR_SSH_KEY"}, "variables": {"AUR_PACKAGE_NAME"},
            "assets": {"pleazyng-linux-x64.tar.gz", "pleazyng-linux-arm64.tar.gz", "SHA256SUMS.txt"},
        },
        {
            "name": "Fedora COPR",
            "workflow": "publish-copr.yml",
            "title": f"action:publish-copr:pool:public:tag:{tag}",
            "fields": {"action": "publish-copr", "runner_pool": "public", "release_tag": tag},
            "secrets": {"COPR_LOGIN", "COPR_USERNAME", "COPR_TOKEN"}, "variables": {"COPR_PROJECT"},
            "assets": {"pleazyng-linux-x64.tar.gz", "pleazyng-linux-arm64.tar.gz", "SHA256SUMS.txt"},
        },
        {
            "name": "Launchpad PPA",
            "workflow": "publish-ppa.yml",
            "title": f"action:publish-ppa:pool:public:tag:{tag}",
            "fields": {"action": "publish-ppa", "runner_pool": "public", "release_tag": tag},
            "secrets": {"GPG_PRIVATE_KEY"}, "variables": {"LAUNCHPAD_PPA"},
            "assets": {"pleazyng-linux-x64.tar.gz", "pleazyng-linux-arm64.tar.gz", "SHA256SUMS.txt"},
        },
        {
            "name": "Snap Store stable",
            "workflow": "publish-snap.yml",
            "title": f"action:publish-snap:pool:public:tag:{tag}:channel:stable",
            "fields": {"action": "publish-snap", "runner_pool": "public", "release_tag": tag,
                       "channel": "stable"},
            "secrets": {"SNAPCRAFT_STORE_CREDENTIALS"}, "variables": set(),
            "assets": {"pleazyng-linux-x64.snap", "pleazyng-linux-arm64.snap", "SHA256SUMS.txt"},
        },
        {
            "name": "Chocolatey",
            "workflow": "publish-chocolatey.yml",
            "title": f"action:publish-chocolatey:pool:public:tag:{tag}:publish:true",
            "fields": {"action": "publish-chocolatey", "runner_pool": "public", "release_tag": tag,
                       "publish": "true"},
            "secrets": {"CHOCO_API_KEY"}, "variables": set(),
            "assets": {"pleazyng-windows-installer.exe", "SHA256SUMS.txt"},
            "asset_predicate": lambda name: name.startswith("pleazyng.") and name.endswith(".nupkg"),
        },
        {
            "name": "WinGet community submission",
            "workflow": "publish-winget.yml",
            "title": f"action:publish-winget:pool:public:tag:{tag}:submit:true",
            "fields": {"action": "publish-winget", "runner_pool": "public", "release_tag": tag,
                       "submit": "true"},
            "secrets": {"WINGET_CREATE_GITHUB_TOKEN"}, "variables": set(),
            "assets": {f"pleazyng-winget-manifests-{version}.zip", "pleazyng-windows-installer.exe", "SHA256SUMS.txt"},
        },
        {
            "name": "GitHub Container Registry and Docker Hub",
            "workflow": "release-containers.yml",
            "title": f"action:publish-containers:pool:public:tag:{tag}",
            "fields": {"action": "publish-containers", "runner_pool": "public", "release_tag": tag},
            "secrets": set(), "variables": set(),
            "assets": {"SHA256SUMS.txt"},
        },
        {
            "name": "Sparkle appcast (Homebrew when configured)",
            "workflow": "update-packages.yml",
            "title": f"action:update-packages:pool:public:tag:{tag}",
            "fields": {"action": "update-packages", "runner_pool": "public", "release_tag": tag},
            "secrets": set(), "variables": set(),
            "assets": {"pleazyng-macos.dmg", "appcast.xml"},
        },
    ]

    completed: list[dict] = []
    skipped: list[dict] = []
    failures: list[str] = []
    macos_signing = {
        "MACOS_CERTIFICATE_BASE64", "MACOS_CERTIFICATE_PASSWORD",
        "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID", "APPLE_API_PRIVATE_KEY", "APPLE_TEAM_ID",
    }
    if not (macos_signing | {"HOMEBREW_TAP_TOKEN"}).issubset(secrets):
        skipped.append({
            "channel": "Homebrew Cask",
            "reason": "Developer ID signing/notarization or tap token is not configured; appcast update remains enabled.",
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
        if spec["fields"].get("channel") == "google-play" and publication_settings.get("GOOGLE_PLAY_AUTOMATIC_RELEASES") == "true":
            skipped.append({"channel": spec["name"], "reason": "Handled by the automatic Google Play release controller and its configured test track."})
            continue
        if spec["fields"].get("channel") == "google-play" and play_error:
            failures.append(f"Google Play configuration: {play_error}")
            continue
        readiness_flag = spec.get("readiness_flag")
        if readiness_flag and publication_settings.get(readiness_flag) != "true":
            skipped.append({
                "channel": spec["name"],
                "reason": f"{readiness_flag} is not true; first-console submission or signed-build validation is incomplete.",
            })
            continue
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
    parser.add_argument("--freeze-release", action=argparse.BooleanOptionalAction, default=True,
                        help="Capture one main source for reusable CI and builds; create its stable tag only after qualification.")
    parser.add_argument("--source-commit", help="Resume a selected 40-character canonical-main ancestor without incorporating later development.")
    parser.add_argument(
        "--apple-arm-runner-pool", choices=("auto", "hosted", "private"), default="auto",
        help=("Auto uses compatible hosted macOS first; a verified tvOS no-runner cancellation retries on private Apple JIT. "
              "Explicitly select hosted or private to force a route."),
    )
    parser.add_argument(
        "--reuse-platform-run", type=int,
        help="Rebuild Android/WebOS and reuse other verified platform outputs after infrastructure-only fixes.",
    )
    parser.add_argument("--reuse-macos-run", type=int, help="Use a qualified signing-only Mac recovery with every original platform artifact.")
    parser.add_argument("--rebuild-linux", action="store_true", help="Rebuild Linux during verified platform recovery")
    parser.add_argument("--reuse-webos-run", type=int, help="Reuse a verified webOS package and wait locally for completed source outputs before assembly")
    parser.add_argument("--reuse-repaired-run", type=int, help="Reuse successful Linux and fully qualified Mac jobs from a prior repair run")
    parser.add_argument('--reuse-tvos-run', type=int, help='Reuse successful signed TV output from an approved sibling Apple packaging repair')
    parser.add_argument('--reuse-ios-run', type=int, help='Reuse successful signed iOS output from an approved sibling Apple packaging repair')
    parser.add_argument("--rebuild-ios", action="store_true", help="Rebuild iOS during verified platform recovery")
    parser.add_argument("--rebuild-tvos", action="store_true", help="Rebuild only tvOS during verified platform recovery")
    parser.add_argument("--rebuild-macos", action="store_true", help="Build and qualify macOS during verified platform recovery")
    parser.add_argument("--reuse-android-run", type=int, help="Reuse a separately successful Android release artifact.")
    parser.add_argument("--skip-webos-build", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument(
        "--include-webos-release",
        action="store_true", default=True,
        help="Include the verified webOS package (required and enabled by default).",
    )
    parser.add_argument(
        "--execution-profile",
        choices=("private", "hybrid"),
        default=None,
        help="Use hosted runners for compatible jobs by default; private JIT remains available for constrained work.",
    )
    parser.add_argument(
        "--include-apple-store-build", action="store_true",
        help="Build and qualify signed iOS/tvOS archives, including with GitHub-only publication; does not enable store uploads.",
    )
    parser.add_argument(
        "--prepare-homebrew-cask", action="store_true",
        help="Notarize macOS and prepare/attest its Homebrew Cask candidate; does not publish to a tap.",
    )
    publication = parser.add_mutually_exclusive_group()
    parser.add_argument("--skip-discord-notification", action="store_true",
                        help="Skip this controller's manual Discord dispatch; release-event workflows are controlled separately.")
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
        help="Publish the verified GitHub release and its automatic Discord notice without starting package or store workflows.",
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
    if not getattr(args, "freeze_release", False):
        # Preserve the legacy main/recovery preflight. Frozen resumptions must
        # validate the selected tag instead of a later local main checkout.
        validate_source_metadata(ROOT, args.version)
    if args.execution_profile != "hybrid":
        raise ReleaseError("Complete releases require the hybrid profile, including native Windows ARM64 CI.")
    packaging_repair = bool(args.reuse_platform_run and getattr(args, "source_commit", None))
    if args.reuse_tvos_run and (args.reuse_tvos_run < 1 or not packaging_repair
                               or (not args.rebuild_ios and not args.reuse_ios_run)
                               or args.rebuild_tvos or args.reuse_repaired_run or args.reuse_macos_run):
        raise ReleaseError('Signed TV reuse requires approved iOS-only sibling packaging recovery.')
    if args.reuse_ios_run and (args.reuse_ios_run < 1 or not args.reuse_tvos_run or args.rebuild_ios):
        raise ReleaseError('Signed iOS reuse requires a distinct signed TV sibling source.')
    if packaging_repair and (not (args.rebuild_ios or args.rebuild_tvos or args.rebuild_macos or args.reuse_ios_run)
                            or args.rebuild_linux
                            or args.reuse_macos_run or args.reuse_repaired_run):
        raise ReleaseError("Approved packaging recovery rebuilds only requested Apple packages.")
    if args.reuse_platform_run and (
        args.reuse_platform_run < 1 or ((args.publish or args.include_apple_store_build) and not packaging_repair)
        or args.execution_profile != "hybrid"
    ):
        raise ReleaseError("Platform recovery supports hybrid GitHub-only or draft publication without fresh Apple or Homebrew qualification.")
    if args.reuse_webos_run and (args.reuse_webos_run < 1 or not args.reuse_platform_run or args.reuse_macos_run):
        raise ReleaseError("WebOS reuse requires verified platform recovery without signing-only substitution")
    if args.reuse_repaired_run and (args.reuse_repaired_run < 1 or not args.reuse_platform_run or args.reuse_macos_run or args.rebuild_linux or args.rebuild_macos):
        raise ReleaseError("Repaired Linux/Mac reuse requires original platform recovery without rebuilding those platforms")
    if args.rebuild_ios and (not args.reuse_platform_run or args.reuse_macos_run or args.reuse_repaired_run):
        raise ReleaseError("iOS rebuilding requires ordinary verified platform recovery")
    if args.rebuild_tvos and (not args.reuse_platform_run or args.reuse_macos_run or args.reuse_repaired_run):
        raise ReleaseError("tvOS rebuilding requires ordinary verified platform recovery")
    if args.rebuild_macos and (not args.reuse_platform_run or args.reuse_macos_run):
        raise ReleaseError("Fresh Mac rebuilding requires ordinary verified platform recovery")
    if args.rebuild_linux and (not args.reuse_platform_run or args.reuse_macos_run):
        raise ReleaseError("Linux rebuilding requires ordinary verified platform recovery")
    if args.reuse_macos_run:
        if args.reuse_macos_run < 1 or not args.reuse_platform_run:
            raise ReleaseError("Mac recovery requires its complete original platform source run.")
        if args.reuse_android_run and args.reuse_android_run != args.reuse_platform_run:
            raise ReleaseError("Mac packaging recovery must reuse Android from the same original source run.")
        args.reuse_android_run = args.reuse_platform_run
    if args.reuse_android_run and (args.reuse_android_run < 1 or not args.reuse_platform_run):
        raise ReleaseError("Android reuse requires a verified platform source run.")
    if args.skip_webos_build:
        raise ReleaseError("Complete versioned releases require webOS; omission is no longer supported.")
    command(["gh", "auth", "status", "--hostname", "github.com"], capture=True, quiet=True)

    scratch = args.scratch.resolve() if args.scratch else Path(tempfile.mkdtemp(prefix="pleazyng-release-"))
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
                "status": "running", "stage": stage,
                "include_apple_store_build": args.include_apple_store_build,
                "prepare_homebrew_cask": args.prepare_homebrew_cask}

    def save_progress() -> None:
        progress_path.write_text(json.dumps(progress, indent=2) + "\n", encoding="utf-8")

    try:
        print(f"Release scratch: {scratch}", flush=True)
        frozen = bool(getattr(args, "freeze_release", False)) and not args.reuse_platform_run
        tag = f"v{args.version}"
        frozen_commit = existing_release_tag_commit(ROOT, tag) if frozen else None
        selected_commit = getattr(args, "source_commit", None)
        if selected_commit:
            if (not frozen and not packaging_repair) or (frozen_commit is not None and frozen_commit != selected_commit):
                raise ReleaseError("Selected source requires a normal frozen release and must match any existing version tag.")
            ensure_main_ancestor(selected_commit)
        if frozen_commit or selected_commit:
            worktree = create_plezy_worktree(scratch,
                source_ref=f"refs/tags/{tag}" if frozen_commit else selected_commit)
        else:
            worktree = create_plezy_worktree(scratch)
        main_commit = command(
            ["git", "rev-parse", "HEAD"], cwd=worktree, capture=True, quiet=True
        ).stdout.strip()
        if frozen_commit:
            ensure_frozen_release_source(tag, main_commit)
        elif selected_commit:
            ensure_main_ancestor(main_commit)
        else:
            ensure_remote_main_sha(main_commit, "starting the Pleazyng release")
        validate_source_metadata(worktree, args.version)
        existing_tag_commit = existing_release_tag_commit(worktree, tag)
        tag_reused = existing_tag_commit is not None
        if args.reuse_platform_run and not tag_reused:
            raise ReleaseError("Platform recovery requires an existing immutable release tag.")
        native_sha = None
        ffmpeg_version = None
        ffmpeg_sha256 = None

        if tag_reused and frozen:
            pin_sha = existing_tag_commit
            ci_source = pin_sha
            progress["tag_commit"] = pin_sha
            progress["immutable_tag_reused"] = True
            print(f"Resuming frozen {tag} at {pin_sha}; later main changes do not alter this release.")
        elif selected_commit:
            pin_sha = main_commit
            ci_source = pin_sha
            progress["selected_source_commit"] = pin_sha
        elif tag_reused:
            ci_source = release_ci_source(worktree, tag, main_commit, existing_tag_commit)
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

            stage = "Pleazyng pin update and push"
            progress["stage"] = stage
            save_progress()
            pin_sha = commit_and_push_native_pin(
                worktree, native_repo, native_sha, ffmpeg_version, ffmpeg_sha256
            )
        if args.reuse_platform_run:
            repair_options = {}
            if packaging_repair:
                repair_title = f"action:release:pool:private:tag:{tag}:repair:{pin_sha}"
                prior_repair = matching_packaging_repair_run(repair_title)
                workflow_sha = (prior_repair["headSha"] if prior_repair else
                                gh_json("api", f"repos/{PLEZY_REPO}/branches/main")["commit"]["sha"])
                repair_options = {"packaging_source_sha": pin_sha, "workflow_source_sha": workflow_sha,
                                  "include_apple_store_build": args.include_apple_store_build}
            proof = verify_platform_recovery(
                args.reuse_platform_run, pin_sha, args.version,
                android_run=args.reuse_android_run, include_webos_build=not args.skip_webos_build,
                **({"rebuild_linux": True} if args.rebuild_linux else {}),
                **({"rebuild_macos": True} if args.rebuild_macos else {}),
                **({"rebuild_tvos": True} if args.rebuild_tvos else {}),
                **({"rebuild_ios": True} if args.rebuild_ios else {}),
                **({"repaired_run": args.reuse_repaired_run} if args.reuse_repaired_run else {}),
                **({'tvos_run': args.reuse_tvos_run} if args.reuse_tvos_run else {}),
                **({'ios_run': args.reuse_ios_run} if args.reuse_ios_run else {}),
                **({"webos_run": args.reuse_webos_run} if args.reuse_webos_run else {}),
                **({"require_homebrew_cask": True} if args.prepare_homebrew_cask and not args.reuse_macos_run else {}),
                **({"macos_run": args.reuse_macos_run} if args.reuse_macos_run else {}),
                wait_complete=bool(args.reuse_webos_run or (args.reuse_android_run and args.skip_webos_build)),
                **repair_options,
            )
            if packaging_repair:
                validate_packaging_repair_proof(proof, tag, pin_sha, workflow_sha)
                product_sha = proof["product_source_sha"]
                progress.update(packaging_source_commit=pin_sha, workflow_source_commit=workflow_sha,
                                plezyng_commit=product_sha, ci_source_commit=proof["ci_source_sha"])
        # Include immutable-tag reuse: that path otherwise skips native refresh.
        # Stale tagged native inputs require the next version, never a moved tag.
        if packaging_repair:
            # The verified S-to-R tree proof preserves every native pin. A
            # later native-fork main cannot invalidate immutable product bytes.
            progress["native_pin_policy"] = "preserved-approved-product-pins"
        else:
            command(["python3", "scripts/sync_native_revision.py", "--check"], cwd=worktree)
        validate_source_metadata(worktree, args.version)
        if frozen:
            # Candidate names include their source SHA. Failed validation can
            # produce another candidate without consuming a stable version tag.
            candidate_ref = ensure_candidate_tag(worktree, args.version, pin_sha)
            progress["candidate_ref"] = candidate_ref
            progress["frozen_source"] = True
        ci_source = proof["ci_source_sha"] if packaging_repair else ci_source if tag_reused else pin_sha
        progress["ci_source_commit"] = ci_source
        progress["plezyng_commit"] = product_sha if packaging_repair else pin_sha
        stage = "Pleazyng CI"
        progress["stage"] = stage
        save_progress()
        apple_pool = getattr(args, "apple_arm_runner_pool", "auto")
        if apple_pool == "auto":
            apple_pool = select_apple_runner_pool(apple_pool)
        if frozen:
            # One main workflow captures the source for reusable CI and every
            # platform. Existing main-only private runner authorization remains
            # unchanged; the stable tag is created inside only after CI passes.
            captured = ensure_release(tag, pin_sha, include_webos_release=args.include_webos_release,
                execution_profile=args.execution_profile, include_apple_store_build=args.include_apple_store_build,
                prepare_homebrew_cask=args.prepare_homebrew_cask, candidate_ref=candidate_ref,
                tvos_runner_pool=apple_pool)
            ci = {"databaseId": captured["databaseId"]}
            progress["release_run"] = captured["databaseId"]
            progress["ci_mode"] = "embedded"
            progress["apple_arm_runner_pool"] = apple_pool
            save_progress()
        elif args.reuse_platform_run:
            ci = {"databaseId": proof["ci_run_id"]}
            progress["platform_recovery"] = proof
            progress["ci_mode"] = proof.get("ci_mode", "standalone")
            if proof.get("embedded_ci") is not None:
                progress["embedded_ci"] = proof["embedded_ci"]
            print(f"Verified unchanged product inputs and exact-source CI from run {proof['ci_run_id']}.")
        else:
            ci = ensure_ci(
                ci_source,
                execution_profile=args.execution_profile,
                apple_runner_pool=apple_pool,
            )
        progress["ci_run"] = ci["databaseId"]
        # Store variants are explicit preparation, never implied by publishing.
        include_apple_store_build = args.include_apple_store_build
        progress["include_apple_store_build"] = include_apple_store_build
        if not tag_reused and not frozen:
            # Exact-source CI runs first. Build every release package once after
            # tagging; never publish until the complete artifact checks pass.
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
        progress["apple_arm_runner_pool"] = apple_pool
        save_progress()
        release = ensure_release(
            tag,
            pin_sha,
            include_webos_release=args.include_webos_release,
            execution_profile=args.execution_profile,
            include_apple_store_build=include_apple_store_build,
            prepare_homebrew_cask=args.prepare_homebrew_cask,
            **({"candidate_ref": candidate_ref} if frozen else {}),
            tvos_runner_pool=apple_pool,
            **({"rebuild_linux": True} if args.rebuild_linux else {}),
            **({"rebuild_macos": True} if args.rebuild_macos else {}),
            **({"rebuild_tvos": True} if args.rebuild_tvos else {}),
            **({"rebuild_ios": True} if args.rebuild_ios else {}),
            **({"reuse_repaired_run_id": args.reuse_repaired_run} if args.reuse_repaired_run else {}),
            **({'reuse_tvos_run_id': args.reuse_tvos_run} if args.reuse_tvos_run else {}),
            **({'reuse_ios_run_id': args.reuse_ios_run} if args.reuse_ios_run else {}),
            **({"reuse_webos_run_id": args.reuse_webos_run} if args.reuse_webos_run else {}),
            **({"reuse_platform_run_id": args.reuse_platform_run} if args.reuse_platform_run else {}),
            **({"reuse_android_run_id": args.reuse_android_run} if args.reuse_android_run else {}),
            **({"reuse_macos_run_id": args.reuse_macos_run} if args.reuse_macos_run else {}),
            **({"include_webos_build": False} if args.skip_webos_build else {}),
            **({"packaging_source_sha": pin_sha, "workflow_source_sha": workflow_sha} if packaging_repair else {}),
        )
        progress["release_run"] = release["databaseId"]
        progress["release_url"] = f"https://github.com/{PLEZY_REPO}/releases/tag/{tag}"
        if frozen:
            ensure_frozen_release_source(tag, pin_sha)
            proof = embedded_ci_proof(release["databaseId"], pin_sha)
            progress["embedded_ci"] = proof
            (scratch / "embedded-ci-proof.json").write_text(json.dumps(proof, indent=2) + "\n")

        stage = "release asset validation"
        progress["stage"] = stage
        save_progress()
        validate_release_outputs(
            tag,
            args.version,
            include_webos_release=args.include_webos_release,
            execution_profile=args.execution_profile,
            include_apple_store_build=include_apple_store_build,
            prepare_homebrew_cask=args.prepare_homebrew_cask,
        )
        if packaging_repair:
            assembly_proof = verify_packaging_repair_assembly(scratch, tag, proof, release)
            progress["packaging_repair_assembly"] = assembly_proof
            save_progress()

        published_channels: list[dict] = []
        skipped_channels: list[dict] = []
        channel_failures: list[str] = []
        notification_failures: list[str] = []
        aerynos_automation: list[dict] = []
        publication_facts_commit = None
        publication_facts_failures: list[str] = []
        release_published = False
        if args.publish or args.publish_github_only:
            if frozen or packaging_repair:
                ensure_frozen_release_source(tag, product_sha if packaging_repair else pin_sha)
            else:
                ensure_remote_main_sha(pin_sha, f"publishing Pleazyng {tag}")
            stage = "publish GitHub release"
            progress["stage"] = stage
            save_progress()
            publish_github_release(tag)
            release_published = True
            progress["release_published"] = True
            # Persist core success before any notification/store/package work.
            progress["status"] = "success"
            progress["stage"] = "post-release followups"
            save_progress()
            try:
                delivery_sha = (gh_json("api", f"repos/{PLEZY_REPO}/branches/main")["commit"]["sha"]
                                if frozen or packaging_repair else pin_sha)
                progress["delivery_tooling_commit"] = delivery_sha
                followups = post_release_actions(
                    tag, args.version, release_sha=delivery_sha,
                    include_webos_release=args.include_webos_release,
                    publish_channels=args.publish,
                    notify_discord=not args.skip_discord_notification,
                )
            except Exception as error:
                followups = {"published_channels": [], "skipped_channels": [],
                             "channel_failures": [f"Post-publication delivery: {error}"],
                             "notification_failures": [], "aerynos_automation": []}
            published_channels = followups["published_channels"]
            skipped_channels = followups["skipped_channels"]
            channel_failures = followups["channel_failures"]
            notification_failures = followups["notification_failures"]
            aerynos_automation = followups.get("aerynos_automation", [])
            progress.update(followups)
            save_progress()
            if channel_failures or notification_failures:
                print("GitHub release is published; post-release delivery needs a separate retry.")
            try:
                publication_facts_commit = (refresh_latest_published_facts(scratch, tag, product_sha if packaging_repair else pin_sha)
                                            if frozen or packaging_repair else refresh_published_facts(worktree, tag, pin_sha))
            except Exception as error:
                # Preserve core publication success; do not rebuild published
                # binaries merely because documentation needs a separate retry.
                publication_facts_failures.append(str(error))
                print("GitHub release is published; publication facts need a separate retry.")
        else:
            metadata = release_metadata(tag)
            release_published = not metadata.get("draft") and bool(metadata.get("published_at"))

        summary = {
            "version": args.version,
            "tag": tag,
            "native_manifest_commit": native_sha,
            "ffmpeg_version": ffmpeg_version,
            "ffmpeg_source_sha256": ffmpeg_sha256,
            "plezyng_commit": product_sha if packaging_repair else pin_sha,
            "packaging_source_commit": pin_sha if packaging_repair else None,
            "workflow_source_commit": workflow_sha if packaging_repair else None,
            "ci_run": ci["databaseId"],
            "ci_mode": progress.get("ci_mode", "standalone"),
            "embedded_ci": progress.get("embedded_ci"),
            "release_run": release["databaseId"],
            "release_url": f"https://github.com/{PLEZY_REPO}/releases/tag/{tag}",
            "release_published": release_published,
            "include_apple_store_build": include_apple_store_build,
            "prepare_homebrew_cask": args.prepare_homebrew_cask,
            "published_channels": published_channels,
            "skipped_channels": skipped_channels,
            "channel_failures": channel_failures,
            "notification_failures": notification_failures,
            "discord_notification_requested": not args.skip_discord_notification,
            "aerynos_automation": aerynos_automation,
            "publication_facts_commit": publication_facts_commit,
            "publication_facts_failures": publication_facts_failures,
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
        if progress.get("release_published"):
            # Remote core publication already succeeded. Unexpected follow-up
            # failures must not invite another all-platform build.
            progress["status"] = "success"
            progress["stage"] = "post-release followups require retry"
            progress.setdefault("channel_failures", []).append(str(error))
            save_progress()
            summary_path.write_text(json.dumps(progress, indent=2) + "\n", encoding="utf-8")
            print(f"GitHub release is published; retry follow-ups against its immutable artifacts: {error}")
            return 0
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
