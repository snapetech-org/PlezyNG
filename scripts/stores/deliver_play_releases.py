#!/usr/bin/env python3
"""Reconcile complete published releases with main-only Play delivery runs."""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pubspec_version import parse_pubspec_version
from release_coverage import missing_assets

REPOSITORY = "snapetech-org/pleazyng"
WORKFLOW = "publish-app-stores.yml"


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def api(path):
    return json.loads(gh("api", f"repos/{REPOSITORY}/{path}"))


def pages(path, key=None):
    result = json.loads(gh("api", f"repos/{REPOSITORY}/{path}", "--paginate", "--slurp"))
    return [item for page in result for item in (page[key] if key else page)]


def release_version(release, source, minimum):
    """Return a build number only for a complete, stable, matching release."""
    tag = release.get("tag_name", "")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        return None
    if release.get("draft") is not False or release.get("prerelease") is not False:
        return None
    version, build = parse_pubspec_version(source)
    if int(build) < minimum:
        return None
    if tag != "v" + version.split("+", 1)[0]:
        raise ValueError(f"{tag} differs from its immutable source version")
    names = {asset["name"] for asset in release.get("assets", [])
             if isinstance(asset.get("size"), int) and asset["size"] > 0}
    missing = missing_assets(names)
    missing.extend(name for name in ("pleazyng-android-play.aab", "SHA256SUMS.txt") if name not in names)
    if missing:
        raise ValueError(f"{tag} has incomplete release coverage: {', '.join(missing)}")
    return int(build)


def delivery_state(runs, tag, now, track="internal"):
    title = f"action:publish-app-stores:pool:public:tag:{tag}:channel:google-play:track:{track}:status:completed"
    matching = [run for run in runs if run.get("display_title") == title
                and run.get("head_branch") == "main" and run.get("event") == "workflow_dispatch"]
    if any(run.get("conclusion") == "success" for run in matching):
        return "delivered"
    if any(run.get("status") != "completed" for run in matching):
        return "pending"
    for run in matching:
        updated = dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00"))
        if now - updated < dt.timedelta(minutes=2):
            return "retry_cooldown"
    return "dispatch"


def settings(environment):
    track = environment.get("GOOGLE_PLAY_AUTO_TRACK", "internal")
    if track not in {"internal", "alpha", "beta"}:
        raise ValueError("Automatic Play delivery requires an internal or closed testing track")
    if track != "internal" and environment.get("GOOGLE_PLAY_BOOTSTRAP_COMPLETE") != "true":
        raise ValueError("Closed-track delivery requires completed native/store bootstrap qualification")
    minimum = int(environment.get("GOOGLE_PLAY_MIN_VERSION_CODE", "189"))
    if minimum < 188:
        raise ValueError("Automatic delivery must not backfill the superseded v3.0.7 bootstrap")
    # Version code 188 was rejected as an incompatible phone/AAOS manifest. A
    # repository variable left at 188 must not make that immutable bundle eligible.
    return track, max(minimum, 189)


def restore_receipt(tag, code, digest, track, destination):
    """Recover only a matching non-secret transaction from this publisher."""
    if code < 189 or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Invalid expected release bundle identity")
    runs = pages(f"actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100", "workflow_runs")
    candidates = [run for run in runs if ':channel:google-play:track:' in run.get('display_title', '')
                  and run.get('head_branch') == 'main' and run.get('status') == 'completed'
                  and str(run['id']) != os.environ.get('GITHUB_RUN_ID')]
    identity = {'release_tag': tag, 'version_code': code, 'aab_sha256': digest, 'track': track}
    seen, others = set(), []
    destination.parent.mkdir(parents=True, exist_ok=True)
    for run in sorted(candidates, key=lambda item: item['id'], reverse=True):
        artifacts = api(f"actions/runs/{run['id']}/artifacts")
        for artifact in artifacts.get('artifacts', []):
            if artifact.get('name') != 'google-play-delivery-receipt' or artifact.get('expired'):
                continue
            if artifact.get('size_in_bytes', 0) > 1048576:
                raise ValueError('Unexpected delivery receipt archive size')
            raw = subprocess.check_output(['gh', 'api', f"repos/{REPOSITORY}/actions/artifacts/{int(artifact['id'])}/zip"])
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                entry = archive.getinfo('receipt.json')
                if entry.file_size > 131072:
                    raise ValueError('Unexpected delivery receipt size')
                previous = json.loads(archive.read(entry))
            key = (previous.get('release_tag'), previous.get('track'))
            if key in seen:
                continue
            seen.add(key)
            if all(previous.get(field) == value for field, value in identity.items()):
                destination.write_text(json.dumps(previous, indent=2) + '\n')
                print(f"Recovered matching Play transaction receipt from run {run['id']}")
            else:
                pending = previous.get('pending_edit') or previous.get('previous_edit')
                if pending and pending.get('upload_attempted') and int(pending.get('expiry', 0)) > dt.datetime.now(dt.timezone.utc).timestamp():
                    others.append({'release_tag': key[0], 'track': key[1], 'pending_edit': pending})
    destination.with_name('pending-other-edits.json').write_text(json.dumps(others, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="")
    parser.add_argument("--dispatch", action="store_true")
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--restore", action="store_true")
    parser.add_argument("--version-code", type=int)
    parser.add_argument("--aab-sha256")
    parser.add_argument("--track", default="internal")
    args = parser.parse_args()
    if os.environ.get("GITHUB_REPOSITORY", REPOSITORY) != REPOSITORY:
        raise ValueError("Delivery is restricted to the canonical repository")
    if args.tag and not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag):
        raise ValueError("Expected an immutable semantic version tag")
    if args.restore:
        if not args.tag or args.version_code is None or args.aab_sha256 is None:
            parser.error("Receipt recovery requires tag, version code and bundle SHA-256")
        restore_receipt(args.tag, args.version_code, args.aab_sha256, args.track, args.receipt)
        return
    track, minimum = settings(os.environ)
    receipt = {"repository": REPOSITORY, "track": track, "minimum_version_code": minimum,
               "enabled": os.environ.get("GOOGLE_PLAY_AUTOMATIC_RELEASES") == "true", "releases": [], "errors": []}
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    try:
        if not receipt["enabled"]:
            return
        releases = [api(f"releases/tags/{args.tag}")] if args.tag else pages("releases?per_page=100")
        candidates = []
        for release in releases:
            tag = release.get("tag_name", "")
            if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
                continue
            if tuple(map(int, tag[1:].split("."))) < (3, 0, 29):
                continue
            try:
                source = api(f"contents/pubspec.yaml?ref={tag}")
                build = release_version(release, base64.b64decode(source["content"]).decode(), minimum)
                if build is not None:
                    comparison = api(f"compare/{tag}...main")
                    if comparison.get("status") not in {"ahead", "identical"}:
                        raise ValueError(f"{tag} is not an ancestor of canonical main")
                    candidates.append((build, tag))
            except (ValueError, KeyError, subprocess.CalledProcessError) as error:
                receipt['errors'].append({'tag': tag, 'error': str(error)})
        runs = pages(f"actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100", "workflow_runs") if candidates else []
        now = dt.datetime.now(dt.timezone.utc)
        for build, tag in sorted(candidates):
            state = delivery_state(runs, tag, now, track)
            record = {"tag": tag, "version_code": build, "state": state}
            receipt["releases"].append(record)
            if state == "dispatch" and args.dispatch:
                gh("workflow", "run", WORKFLOW, "--repo", REPOSITORY, "--ref", "main",
                   "-f", "action=publish-app-stores", "-f", "runner_pool=public",
                   "-f", f"release_tag={tag}", "-f", "channel=google-play",
                   "-f", f"play_track={track}", "-f", "play_release_status=completed")
                record["state"] = "dispatched"
            print(f"{tag}: {record['state']}")
        if receipt['errors']:
            raise ValueError('Some releases need repair; other complete releases were still reconciled')
    finally:
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
