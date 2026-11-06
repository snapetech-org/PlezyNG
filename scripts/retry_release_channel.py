#!/usr/bin/env python3
"""Retry one distribution lane using an existing published GitHub release.

This entry point never builds the app, changes a tag, or republishes a release.
Publisher code comes from current main; artifacts remain bound to release_tag.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import time

from release_all_platforms import PLEZY_REPO, ReleaseError, command, gh_json, workflow_runs


def lane_fields(title: str, tag: str) -> dict[str, str]:
    parts = title.split(":")
    if len(parts) % 2:
        raise ReleaseError("Run title does not identify a publication lane; inspect it manually.")
    fields = dict(zip(parts[::2], parts[1::2]))
    if len(fields) != len(parts) // 2:
        raise ReleaseError("Run title contains ambiguous duplicate lane fields.")
    if fields.get("tag") != tag or not fields.get("action") or not fields.get("pool"):
        raise ReleaseError("Previous run does not identify this exact release tag and publication lane.")
    return {"action": fields["action"], "runner_pool": fields["pool"], "release_tag": tag,
            **{key: value for key, value in fields.items() if key not in {"action", "pool", "tag"}}}


def workflow_file(path: str) -> str:
    prefix = ".github/workflows/"
    if not path.startswith(prefix):
        raise ReleaseError("Previous run is not a repository publication workflow.")
    name = path[len(prefix):]
    if not re.fullmatch(r"[a-z0-9-]+\.yml", name):
        raise ReleaseError("Invalid publication workflow path.")
    if not (name.startswith("publish-") or name in {
        "update-packages.yml", "release-containers.yml", "discord-release.yml",
    }):
        raise ReleaseError("Build, CI and release creation workflows cannot run through channel retry.")
    return name


def retry(tag: str, run_id: int, inputs: list[str], *, retry_failed: bool, wait: bool) -> dict:
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag) or run_id < 1:
        raise ReleaseError("Use an existing vMAJOR.MINOR.PATCH tag and positive publication run ID.")
    release = gh_json("release", "view", tag, "--repo", PLEZY_REPO,
                      "--json", "tagName,isDraft,publishedAt,url")
    if (release.get("tagName") != tag or release.get("isDraft") or not release.get("publishedAt")
            or release.get("url") != f"https://github.com/{PLEZY_REPO}/releases/tag/{tag}"):
        raise ReleaseError("Channel retry requires the exact already-published GitHub release.")
    previous = gh_json("api", f"repos/{PLEZY_REPO}/actions/runs/{run_id}")
    workflow = workflow_file(previous.get("path", ""))
    manual = previous.get("event") == "workflow_dispatch" and previous.get("head_branch") == "main"
    notice = previous.get("event") == "release" and workflow == "discord-release.yml"
    if not (manual or notice):
        raise ReleaseError("Only a previous main publication or release-notification lane can be retried.")
    title = previous.get("display_title", "")
    fields = lane_fields(title, tag)
    for item in inputs:
        key, separator, value = item.partition("=")
        if not separator or not re.fullmatch(r"[a-z][a-z0-9_]*", key) or not value:
            raise ReleaseError("Each --input must be a non-empty NAME=VALUE workflow input.")
        if key in fields and value != fields[key]:
            raise ReleaseError(f"Cannot change lane identity input {key}; choose the correct previous run.")
        fields[key] = value
    if fields.get("channel") == "google-play":
        if not {"play_track", "play_release_status"}.issubset(fields):
            raise ReleaseError("Specify --input play_track=... and play_release_status=... for Google Play.")
        if fields["play_track"] not in {"internal", "alpha", "beta"} or fields["play_release_status"] not in {"draft", "completed"}:
            raise ReleaseError("Automatic Play retries support internal/closed testing and draft/completed only.")
    # Reuse newer successful/in-flight attempts of this exact lane across
    # publisher revisions. A repaired main must not force an application rebuild.
    candidates = [run for run in workflow_runs(PLEZY_REPO, workflow, ref="main")
                  if (run.get("event") == "workflow_dispatch" or (workflow == "discord-release.yml" and run.get("event") == "release"))
                  and run.get("displayTitle") == title]
    candidates.sort(key=lambda run: (run.get("createdAt", ""), run.get("databaseId", 0)), reverse=True)
    current = candidates[0] if candidates else {
        "databaseId": run_id, "status": previous.get("status"), "conclusion": previous.get("conclusion"),
        "url": previous.get("html_url"), "headSha": previous.get("head_sha"),
    }
    report = {"release_tag": tag, "release_status": "published", "release_url": release["url"],
              "workflow": workflow, "lane": title, "rebuild_requested": False}
    if current.get("status") != "completed":
        report.update(channel_status="in_progress", run_id=current["databaseId"], run_url=current.get("url"))
    elif current.get("conclusion") == "success":
        report.update(channel_status="success", run_id=current["databaseId"], run_url=current.get("url"), reused=True)
        return report
    else:
        if not retry_failed:
            raise ReleaseError("Inspect the failed channel's external side effects, then use --retry-failed; the GitHub release remains published.")
        publisher_sha = gh_json("api", f"repos/{PLEZY_REPO}/commits/main")["sha"]
        args = ["gh", "workflow", "run", workflow, "--repo", PLEZY_REPO, "--ref", "main"]
        for key, value in fields.items():
            args.extend(["-f", f"{key}={value}"])
        command(args)
        report.update(channel_status="dispatched", requested_publisher_sha=publisher_sha,
                      previous_run_id=current["databaseId"], inputs=fields)
        # Resolve a new attempt of this exact lane/release. Record its actual
        # publisher SHA: main may advance between preflight and dispatch.
        for attempt in range(15 if wait else 3):
            matches = [run for run in workflow_runs(PLEZY_REPO, workflow, ref="main")
                       if run.get("displayTitle") == title and run.get("event") == "workflow_dispatch"
                       and run.get("databaseId", 0) > current["databaseId"]]
            if matches:
                matches.sort(key=lambda run: run.get("databaseId", 0), reverse=True)
                report.update(run_id=matches[0]["databaseId"], run_url=matches[0].get("url"),
                              publisher_sha=matches[0].get("headSha"))
                break
            if attempt + 1 < (15 if wait else 3):
                time.sleep(2)
        if wait and not report.get("run_id"):
            report["watch_status"] = "run not yet visible; inspect GitHub before any further retry"
    if wait and report.get("run_id"):
        watch_code = 130
        try:
            watched = command(["gh", "run", "watch", str(report["run_id"]), "--repo", PLEZY_REPO,
                               "--interval", "30", "--exit-status"], check=False)
            watch_code = watched.returncode
        except KeyboardInterrupt:
            pass
        state = gh_json("run", "view", str(report["run_id"]), "--repo", PLEZY_REPO,
                        "--json", "status,conclusion")
        report["watch_exit_code"] = watch_code
        report["workflow_conclusion"] = state.get("conclusion")
        if state.get("status") != "completed":
            report["channel_status"] = "in_progress"
            report["watch_status"] = "watcher ended; channel workflow remains " + str(state.get("status"))
        else:
            report["channel_status"] = "success" if state.get("conclusion") == "success" else "failed"
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--run-id", required=True, type=int, help="Previous publication run for this exact channel/tag")
    parser.add_argument("--input", action="append", default=[], help="Additional non-secret workflow input NAME=VALUE")
    parser.add_argument("--retry-failed", action="store_true", help="Retry after reviewing the failed lane's external side effects")
    parser.add_argument("--wait", action="store_true", help="Watch this channel attempt only; does not run application builds")
    parser.add_argument("--receipt", type=Path, help="Save the independent channel result as JSON")
    args = parser.parse_args()
    try:
        result = retry(args.release_tag, args.run_id, args.input, retry_failed=args.retry_failed, wait=args.wait)
    except (ReleaseError, KeyError, TypeError) as error:
        result = {"release_tag": args.release_tag, "release_status": "unchanged", "channel_status": "blocked", "error": str(error), "rebuild_requested": False}
    rendered = json.dumps(result, indent=2) + "\n"
    print(rendered)
    if args.receipt:
        args.receipt.write_text(rendered, encoding="utf-8")
    return 1 if result["channel_status"] in {"failed", "blocked"} else 2 if result.get("watch_status") else 0


if __name__ == "__main__":
    raise SystemExit(main())
