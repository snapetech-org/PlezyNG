#!/usr/bin/env python3
"""Run queued Pleazyng Apple jobs one at a time on the private Mac JIT lane."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "snapetech-org/PlezyNG"
RUNNER_GROUP_ID = os.environ.get("APPLE_JIT_RUNNER_GROUP_ID", "8")
APPLE_LABELS = {"private-apple", "macOS", "ARM64"}
POLL_SECONDS = 15
MAX_LAUNCH_ATTEMPTS = 3


class QueueError(RuntimeError):
    pass


def gh_json(*args: str) -> dict:
    result = subprocess.run(
        ["gh", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or "GitHub CLI returned an error."
        raise QueueError(detail)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise QueueError("GitHub CLI returned invalid JSON.") from error
    if not isinstance(value, dict):
        raise QueueError("GitHub CLI returned an unexpected response.")
    return value


def get_run(run_id: str) -> dict:
    run = gh_json("api", f"repos/{REPOSITORY}/actions/runs/{run_id}")
    head_repository = run.get("head_repository")
    if (
        run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != "main"
        or not isinstance(head_repository, dict)
        or head_repository.get("full_name") != REPOSITORY
    ):
        raise QueueError(
            f"Run {run_id} is not a trusted-main Pleazyng workflow_dispatch; refusing private Apple execution."
        )
    return run


def get_jobs(run_id: str) -> list[dict]:
    value = gh_json("api", f"repos/{REPOSITORY}/actions/runs/{run_id}/jobs?per_page=100")
    jobs = value.get("jobs")
    if not isinstance(jobs, list) or any(not isinstance(job, dict) for job in jobs):
        raise QueueError("GitHub Actions did not return the expected job list.")
    return jobs


def is_apple_job(job: dict, run_id: str) -> bool:
    labels = set(job.get("labels", []))
    return (
        APPLE_LABELS.issubset(labels)
        and any(label.startswith(f"gha-{run_id}-") for label in labels)
    )


def active_run_scoped_apple_runner() -> bool:
    value = gh_json(
        "api",
        f"orgs/snapetech-org/actions/runner-groups/{RUNNER_GROUP_ID}/runners?per_page=100",
    )
    runners = value.get("runners")
    if not isinstance(runners, list):
        raise QueueError("GitHub did not return the Apple runner-group inventory.")
    return any(
        isinstance(runner, dict)
        and runner.get("status") == "online"
        and (runner.get("busy") is True or any(
            isinstance(label, dict)
            and isinstance(label.get("name"), str)
            and label["name"].startswith(("ng-main-run-", "gha-"))
            for label in runner.get("labels", [])
        ))
        and any(
            isinstance(label, dict) and label.get("name") == "private-apple"
            for label in runner.get("labels", [])
        )
        for runner in runners
    )


def wait_until_completed(run_id: str, job_id: int) -> dict:
    polls = 0
    while True:
        job = next((item for item in get_jobs(run_id) if item.get("id") == job_id), None)
        if job is None:
            raise QueueError(f"Apple job {job_id} disappeared from run {run_id}.")
        if job.get("status") == "completed":
            return job
        run = get_run(run_id)
        if run.get("status") == "completed":
            return job
        polls += 1
        if polls % 4 == 0:
            print(f"Apple JIT queue: waiting for job {job_id} to finish.", flush=True)
        time.sleep(POLL_SECONDS)


def get_job(run_id: str, job_id: int) -> dict:
    job = next((item for item in get_jobs(run_id) if item.get("id") == job_id), None)
    if job is None:
        raise QueueError(f"Apple job {job_id} disappeared from run {run_id}.")
    return job


def launch_job(run_id: str, job_id: int, attempt: int, evidence_run_dir: Path) -> int:
    evidence_run_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(evidence_run_dir, 0o700)
    log_path = evidence_run_dir / f"{job_id}-launch-{attempt}-{time.time_ns()}.log"
    if log_path.exists() or log_path.is_symlink():
        raise QueueError(f"Refusing to overwrite Apple launcher evidence: {log_path}")
    environment = os.environ.copy()
    environment["APPLE_JIT_EVIDENCE_DIR"] = str(evidence_run_dir)
    with log_path.open("x", encoding="utf-8") as log:
        os.chmod(log_path, 0o600)
        process = subprocess.Popen(
            ["bash", str(ROOT / "scripts/launch_apple_jit_runner.sh"), run_id, str(job_id)],
            cwd=ROOT,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        while True:
            try:
                return process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                print(
                    f"Apple JIT queue: launcher remains attached to run {run_id}, job {job_id}.",
                    flush=True,
                )


def save_github_logs(run_id: str, jobs: list[dict], evidence_run_dir: Path) -> None:
    evidence_run_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(evidence_run_dir, 0o700)
    for job in jobs:
        if not is_apple_job(job, run_id) or job.get("status") != "completed":
            continue
        job_id = job.get("id")
        if not isinstance(job_id, int):
            continue
        log_path = evidence_run_dir / f"{job_id}-github-job.log"
        if log_path.exists() or log_path.is_symlink():
            continue
        for attempt in range(1, 4):
            with log_path.open("x", encoding="utf-8") as log:
                os.chmod(log_path, 0o600)
                result = subprocess.run(
                    [
                        "gh", "run", "view", run_id, "--repo", REPOSITORY,
                        "--job", str(job_id), "--log",
                    ],
                    cwd=ROOT,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
            if result.returncode == 0:
                break
            if attempt < 3:
                log_path.unlink(missing_ok=True)
                time.sleep(10)
            else:
                print(
                    f"GitHub job log for Apple job {job_id} remains available on GitHub; "
                    f"local retrieval failed. See {log_path}.",
                    file=sys.stderr,
                    flush=True,
                )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id", help="Pleazyng workflow run ID")
    parser.add_argument(
        "--evidence-dir",
        required=True,
        type=Path,
        help="Task scratch directory for launcher output, runner diagnostics, and job logs",
    )
    return parser.parse_args()


def run_queue(run_id: str, evidence_root: Path) -> int:
    evidence_run_dir = evidence_root / run_id
    attempts: dict[int, int] = {}
    failures: list[str] = []
    idle_polls = 0

    while True:
        run = get_run(run_id)
        jobs = get_jobs(run_id)
        apple_jobs = [job for job in jobs if is_apple_job(job, run_id)]
        if run.get("status") == "completed":
            break

        active_jobs = [
            job for job in apple_jobs
            if job.get("status") not in {"queued", "completed"}
        ]
        if active_jobs or active_run_scoped_apple_runner():
            time.sleep(POLL_SECONDS)
            continue

        queued = sorted(
            (job for job in apple_jobs if job.get("status") == "queued"),
            key=lambda job: job.get("id", 0),
        )
        if not queued:
            idle_polls += 1
            if idle_polls % 4 == 0:
                print(
                    f"Apple JIT queue: no queued Apple job is ready; waiting for run {run_id}.",
                    flush=True,
                )
            time.sleep(POLL_SECONDS)
            continue

        idle_polls = 0

        job = queued[0]
        job_id = job.get("id")
        if not isinstance(job_id, int):
            raise QueueError("A queued Apple job is missing its numeric job ID.")
        attempt = attempts.get(job_id, 0) + 1
        if attempt > MAX_LAUNCH_ATTEMPTS:
            raise QueueError(
                f"Apple job {job_id} remained queued after {MAX_LAUNCH_ATTEMPTS} launch attempts. "
                "Capacity or runner preflight needs operator attention."
            )
        attempts[job_id] = attempt
        print(
            f"Apple JIT queue: starting {job.get('name', job_id)} "
            f"(run {run_id}, job {job_id}, launch {attempt}/{MAX_LAUNCH_ATTEMPTS}).",
            flush=True,
        )
        return_code = launch_job(run_id, job_id, attempt, evidence_run_dir)
        current = get_job(run_id, job_id)
        if current.get("status") == "queued":
            print(
                f"Apple JIT launcher attempt {attempt} for job {job_id} returned {return_code}; "
                "the job remains queued, so the controller will retry after a short delay.",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(min(15 * attempt, 60))
            continue
        completed = (
            current if current.get("status") == "completed"
            else wait_until_completed(run_id, job_id)
        )
        if completed.get("status") == "completed":
            attempts.pop(job_id, None)
            if completed.get("conclusion") != "success":
                failures.append(
                    f"{completed.get('name', job_id)} concluded {completed.get('conclusion')}"
                )
                print(f"Apple JIT queue: {failures[-1]}.", file=sys.stderr, flush=True)
            else:
                print(f"Apple JIT queue: job {job_id} succeeded.", flush=True)
                if return_code != 0:
                    raise QueueError(
                        f"Apple job {job_id} succeeded, but its launcher returned {return_code}; "
                        "inspect cleanup and diagnostics before using the Mac slot again."
                    )
            continue

    remaining = [
        job for job in apple_jobs if job.get("status") not in {"completed"}
    ]
    if remaining:
        failures.extend(
            f"{job.get('name', job.get('id'))} ended in {job.get('status')}"
            for job in remaining
        )
    save_github_logs(run_id, apple_jobs, evidence_run_dir)
    if failures:
        raise QueueError("Apple JIT jobs did not all pass: " + "; ".join(failures))
    print(f"Apple JIT queue: all {len(apple_jobs)} Apple jobs reached a terminal result.", flush=True)
    return 0



def main() -> int:
    args = parse_args()
    if not args.run_id.isdigit():
        raise QueueError("Workflow run ID must be numeric.")
    requested_evidence_root = args.evidence_dir.expanduser()
    if requested_evidence_root.is_symlink():
        raise QueueError(f"Apple evidence path cannot be a symlink: {requested_evidence_root}")
    evidence_root = requested_evidence_root.resolve()
    evidence_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(evidence_root, 0o700)
    if not evidence_root.is_dir():
        raise QueueError(f"Apple evidence path must be a real directory: {evidence_root}")
    lock_path = evidence_root / f".{args.run_id}.queue.lock"
    try:
        lock_fd = os.open(
            lock_path,
            os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
    except OSError as error:
        raise QueueError(f"Could not open the Apple queue lock: {lock_path}") from error
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        os.close(lock_fd)
        raise QueueError(f"Another Apple queue controller owns run {args.run_id}.") from error
    os.fchmod(lock_fd, 0o600)
    try:
        return run_queue(args.run_id, evidence_root)
    finally:
        os.close(lock_fd)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except QueueError as error:
        print(f"Apple JIT queue stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
