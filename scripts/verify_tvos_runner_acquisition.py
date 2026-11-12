#!/usr/bin/env python3
"""Verify that a trusted hosted tvOS job was canceled before runner acquisition."""

import argparse
import json
import re
import subprocess


REPOSITORY = "snapetech-org/pleazyng"
TVOS_JOB = "Build tvOS developer package (arm64)"


class RunnerAcquisitionError(RuntimeError):
    pass


def gh_api(path):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode:
        raise RunnerAcquisitionError(result.stderr.strip() or "GitHub API request failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RunnerAcquisitionError("GitHub returned invalid runner-acquisition evidence") from error


def verify_unacquired_hosted_tvos_run(run_id, expected_sha, version, *, action="release",
                                     repository=REPOSITORY):
    """Return immutable failure evidence, or reject a run that could have built on a runner."""
    if (repository != REPOSITORY or not str(run_id).isdigit()
            or not re.fullmatch(r"[0-9a-f]{40}", str(expected_sha))
            or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(version))
            or action not in {"build", "release"}):
        raise RunnerAcquisitionError("Runner retry requires exact trusted run, source, version, and action identities")

    run = gh_api(f"repos/{repository}/actions/runs/{run_id}")
    expected_title = (
        f"action:build:pool:private:mode:release:version:{version}"
        if action == "build" else f"action:release:pool:private:tag:v{version}"
    )
    if (run.get("id") != int(run_id) or run.get("event") != "workflow_dispatch"
            or run.get("head_branch") != "main"
            or run.get("head_repository", {}).get("full_name") != repository
            or run.get("path", "").split("@")[0] != ".github/workflows/build.yml"
            or run.get("status") != "completed" or run.get("conclusion") != "failure"
            or run.get("head_sha") != expected_sha or run.get("display_title") != expected_title
            or type(run.get("run_attempt")) is not int or run["run_attempt"] < 1):
        raise RunnerAcquisitionError("Source run is not a failed trusted-main release build for this exact commit")

    jobs_response = gh_api(
        f"repos/{repository}/actions/runs/{run_id}/attempts/{run['run_attempt']}/jobs?per_page=100"
    )
    jobs = jobs_response.get("jobs")
    if (not isinstance(jobs, list) or jobs_response.get("total_count", len(jobs)) != len(jobs)
            or any(not isinstance(job, dict) for job in jobs)):
        raise RunnerAcquisitionError("Source run job inventory is incomplete")

    tvos_jobs = [job for job in jobs if job.get("name") == TVOS_JOB]
    if len(tvos_jobs) != 1:
        raise RunnerAcquisitionError("Source run does not contain exactly one tvOS package job")
    tvos = tvos_jobs[0]
    labels = tvos.get("labels")
    if (tvos.get("status") != "completed" or tvos.get("conclusion") != "cancelled"
            or not isinstance(labels, list) or "macos-26" not in labels
            or tvos.get("runner_id") not in (None, 0)
            or tvos.get("runner_name") not in (None, "")
            or not isinstance(tvos.get("steps"), list) or tvos["steps"]):
        raise RunnerAcquisitionError("tvOS was not proven canceled before hosted runner acquisition")

    unrelated = [job.get("name", "unnamed job") for job in jobs if job is not tvos
                 and (job.get("status") != "completed"
                      or job.get("conclusion") not in {"success", "skipped"})]
    if unrelated:
        raise RunnerAcquisitionError(
            "Source run has other incomplete or failed jobs: " + ", ".join(unrelated)
        )
    return {
        "run_id": int(run_id),
        "run_attempt": run["run_attempt"],
        "source_sha": expected_sha,
        "version": version,
        "action": action,
        "tvos_job_id": tvos["id"],
        "labels": labels,
        "runner_id": tvos.get("runner_id"),
        "steps": 0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--action", choices=("build", "release"), default="release")
    args = parser.parse_args()
    proof = verify_unacquired_hosted_tvos_run(
        args.run_id, args.source_sha, args.version, action=args.action
    )
    print(json.dumps(proof, sort_keys=True))


if __name__ == "__main__":
    main()
