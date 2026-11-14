#!/usr/bin/env python3
"""Keep audit status, release checks, locale claims, and public docs aligned."""

from __future__ import annotations

import json
import argparse
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from workflow_yaml import job_block, scalar


ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = ROOT / "docs/maintainers/capability-manifest.json"
ERRORS: list[str] = []
FINDING_IDS = [f"F{index:02d}" for index in range(1, 18)]
STATUSES = {"implemented", "partial", "gated"}


def require(condition: bool, message: str) -> None:
    if not condition:
        ERRORS.append(message)


def display_name(workflow: str, key: str) -> str:
    block = job_block(workflow, key)
    require(bool(block), f"missing CI job {key}")
    match = re.search(r"(?m)^    name: (.+)$", block)
    require(match is not None, f"CI job {key} has no display name")
    return scalar(match.group(1)) if match else ""


def matrix_job_names(workflow: str, key: str, field: str) -> list[str]:
    template = display_name(workflow, key)
    placeholder = f"${{{{ matrix.{field} }}}}"
    require(placeholder in template, f"CI job {key} no longer names matrix field {field}")
    block = job_block(workflow, key)
    if key == "windows-native-test" and field == "arch":
        require(
            "windows-2025" in block
            and "windows-11-vs2026-arm" in block
            and "self-hosted" not in block,
            "Windows native validation must use public hosted x64 and ARM64 runners",
        )
        values = re.findall(r"(?m)^\s+- arch: ([A-Za-z0-9_-]+)\s*$", block)
        require(set(values) == {"x64", "arm64"}, "public Windows matrix must include native x64 and ARM64")
    else:
        values = re.findall(rf"(?m)^\s+- {re.escape(field)}: ([A-Za-z0-9_-]+)\s*$", block)
    require(bool(values), f"CI job {key} has no {field} matrix values")
    require(len(values) == len(set(values)), f"CI job {key} repeats a {field} matrix value")
    return [template.replace(placeholder, value) for value in values]


def expected_ci_jobs(workflow: str) -> tuple[set[str], set[str]]:
    direct = (
        "analyze",
        "test",
        "android-test",
        "native-format",
        "dependency-check",
        "server",
    )
    required = {display_name(workflow, key) for key in direct}
    for key, field in (
        ("linux-native-test", "sanitizer"),
        ("apple-native-test", "platform"),
        ("windows-native-test", "arch"),
    ):
        required.update(matrix_job_names(workflow, key, field))
    optional_block = job_block(workflow, "linux-packages")
    optional = {display_name(workflow, "linux-packages")}
    require("inputs.build_linux_packages" in optional_block, "Linux package smoke build must remain conditional")
    return required, optional


def _load_manifest() -> dict | None:
    try:
        value = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        ERRORS.append(f"cannot read {MANIFEST_PATH.relative_to(ROOT)}: {error}")
        return None
    if not isinstance(value, dict):
        ERRORS.append("capability manifest root must be an object")
        return None
    return value


def _validate_paths(paths: object, label: str) -> None:
    if not isinstance(paths, list) or not paths:
        ERRORS.append(f"{label} must list at least one evidence path")
        return
    for value in paths:
        if not isinstance(value, str) or not value:
            ERRORS.append(f"{label} contains an invalid evidence path")
            continue
        candidate = (ROOT / value).resolve()
        if ROOT not in candidate.parents and candidate != ROOT:
            ERRORS.append(f"{label} escapes the repository: {value}")
        elif not candidate.exists():
            ERRORS.append(f"{label} references a missing path: {value}")


def check_manifest(data: dict) -> None:
    require(data.get("schemaVersion") == 1, "unsupported capability manifest schemaVersion")
    require(bool(data.get("reviewedOn")), "capability manifest needs a reviewedOn date")

    findings = data.get("findings")
    if not isinstance(findings, list):
        ERRORS.append("findings must be a list")
        findings = []
    ids = [item.get("id") for item in findings if isinstance(item, dict)]
    require(ids == FINDING_IDS, "findings must contain F01 through F17 once, in order")
    for item in findings:
        if not isinstance(item, dict):
            ERRORS.append("each finding must be an object")
            continue
        require(item.get("implementationStatus") in STATUSES, f"{item.get('id')} has an invalid implementationStatus")
        require(item.get("confidence") in {"high", "medium", "low", "unknown"}, f"{item.get('id')} has invalid confidence")
        require(bool(item.get("title")) and bool(item.get("qualification")), f"{item.get('id')} needs title and qualification")
        _validate_paths(item.get("evidence"), str(item.get("id", "finding")))

    for boundary in data.get("productBoundaries", []):
        if not isinstance(boundary, dict):
            ERRORS.append("each product boundary must be an object")
            continue
        require(boundary.get("status") in STATUSES | {"isolated"}, f"{boundary.get('area')} has an invalid status")
        require(bool(boundary.get("open")), f"{boundary.get('area')} needs an explicit open condition")
        _validate_paths(boundary.get("evidence"), str(boundary.get("area", "product boundary")))

    release = data.get("release")
    if not isinstance(release, dict):
        ERRORS.append("release must be an object")
        return
    gate = release.get("releaseGate")
    if not isinstance(gate, dict):
        ERRORS.append("releaseGate must be an object")
        return

    workflow_file = gate.get("workflowFile")
    workflow_id = gate.get("workflowId")
    require(isinstance(workflow_file, str) and (ROOT / workflow_file).is_file(), "release gate workflow file is missing")
    require(isinstance(workflow_file, str) and Path(workflow_file).name == workflow_id, "release gate workflowId must match its file name")
    require(gate.get("branch") == "main", "release gate must require main")
    require(gate.get("event") == "workflow_dispatch", "release gate must require a manual CI dispatch")
    require(bool(gate.get("workflowName")), "release gate needs the workflow display name")

    ci_path = ROOT / ".github/workflows/ci.yml"
    build_path = ROOT / ".github/workflows/build.yml"
    ci_text = ci_path.read_text(encoding="utf-8") if ci_path.is_file() else ""
    build_text = build_path.read_text(encoding="utf-8") if build_path.is_file() else ""
    require(re.search(r"(?m)^name: CI - Sanity Checks\s*$", ci_text) is not None, "CI display name changed")
    require("workflow_dispatch:" in ci_text, "CI must remain explicitly dispatchable")
    require("python3 scripts/verify_release_ci.py" in build_text, "release workflow must call the exact-SHA CI verifier")
    require("GH_TOKEN: ${{ github.token }}" in build_text, "release gate needs an Actions read token")
    require("COMMIT_SHA: ${{ steps.release-tag.outputs.commit }}" in build_text, "release CI gate must use the validated immutable application tag SHA")
    validate_job = job_block(build_text, "validate-trusted-ref")
    require("actions: read" in validate_job, "release validation job needs Actions read permission")

    required_jobs, optional_jobs = expected_ci_jobs(ci_text)
    manifest_required = release.get("requiredCiJobs")
    manifest_optional = release.get("optionalCiJobs")
    gate_required = gate.get("requiredJobs")
    require(isinstance(manifest_required, list), "release.requiredCiJobs must be a list")
    require(isinstance(manifest_optional, list), "release.optionalCiJobs must be a list")
    require(isinstance(gate_required, list), "releaseGate.requiredJobs must be a list")
    if isinstance(manifest_required, list):
        require(set(manifest_required) == required_jobs, "required CI job names differ from the expanded workflow jobs")
    if isinstance(gate_required, list):
        require(set(gate_required) == required_jobs, "release gate does not require every expanded CI job")
    if isinstance(manifest_optional, list):
        require(set(manifest_optional) == optional_jobs, "optional CI job names differ from the workflow")

    localization = data.get("localization")
    if not isinstance(localization, dict):
        ERRORS.append("localization must be an object")
    else:
        locale_directory = ROOT / str(localization.get("directory", ""))
        file_pattern = localization.get("filePattern")
        locale_count = localization.get("localeChoices")
        actual_count = len(list(locale_directory.glob(file_pattern))) if isinstance(file_pattern, str) else 0
        require(actual_count == locale_count, f"manifest locale count {locale_count} differs from {actual_count} locale files")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        require(f"Localized across {locale_count} locale choices" in readme, "README locale count differs from the manifest")
        require(bool(localization.get("qualityStatus")), "localization must distinguish coverage from language QA")

        coverage_name = localization.get("coverageReport")
        if not isinstance(coverage_name, str):
            ERRORS.append("localization.coverageReport must name the canonical coverage report")
        else:
            _validate_paths([coverage_name], "localization.coverageReport")
            try:
                coverage = json.loads((ROOT / coverage_name).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                ERRORS.append(f"localization coverage report is unreadable: {error}")
            else:
                coverage_locales = coverage.get("locales")
                if not isinstance(coverage_locales, dict) or not coverage_locales:
                    ERRORS.append("localization coverage report must contain locale records")
                else:
                    require(len(coverage_locales) == locale_count,
                            "coverage report locale count differs from the manifest")
                    message_counts = {
                        entry.get("messages") for entry in coverage_locales.values()
                        if isinstance(entry, dict) and isinstance(entry.get("messages"), int)
                    }
                    require(len(message_counts) == 1,
                            "coverage report must contain one consistent message count")
                    message_count = next(iter(message_counts)) if len(message_counts) == 1 else None
                    if message_count is not None:
                        require(localization.get("messagesPerLocale") == message_count,
                                "manifest message count differs from the coverage report")
                    fallback_entries = sum(
                        entry.get("englishFallbacks", 0) for entry in coverage_locales.values()
                        if isinstance(entry, dict) and isinstance(entry.get("englishFallbacks"), int)
                    )
                    require(localization.get("englishFallbackEntries") == fallback_entries,
                            "manifest fallback-entry count differs from the coverage report")
                    quality = str(localization.get("qualityStatus", ""))
                    if message_count is not None:
                        require(f"{message_count:,} messages across {len(coverage_locales)} locales" in quality,
                                "localization qualityStatus message count differs from the coverage report")
                    require(f"{fallback_entries:,} explicitly allowlisted English-fallback entries" in quality,
                            "localization qualityStatus fallback count differs from the coverage report")

        fallback_manifest_path = locale_directory / "english_fallbacks.json"
        try:
            fallback_manifest = json.loads(fallback_manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            ERRORS.append(f"English fallback manifest is unreadable: {error}")
        else:
            fallback_keys = fallback_manifest.get("keys") if isinstance(fallback_manifest, dict) else None
            require(isinstance(fallback_keys, list), "English fallback manifest must contain a key list")
            if isinstance(fallback_keys, list):
                require(localization.get("englishFallbackKeys") == len(fallback_keys),
                        "manifest fallback-key count differs from the English fallback manifest")

    releases_page = release.get("releasesPage")
    public_latest = release.get("publicLatestAvailable")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    privacy = (ROOT / "PRIVACY.md").read_text(encoding="utf-8")
    require(isinstance(releases_page, str) and releases_page in readme, "README must link the configured releases page")
    require(isinstance(public_latest, bool), "release.publicLatestAvailable must be boolean")
    if public_latest is False:
        require("/releases/latest/download" not in readme.lower(), "README links a latest asset while no public latest release exists")
        require(release.get("publicationStatus") in {"draft", "unavailable"}, "a missing public latest release must be labeled draft or unavailable")
        require("draft" in readme.lower() and "no public" in readme.lower(), "README must explain that no public latest download exists")
        if release.get("publicationStatus") == "unavailable":
            try:
                observation = json.loads((ROOT / release["availabilityEvidence"]).read_text(encoding="utf-8"))
                check_release_availability(release, observation)
            except (OSError, ValueError, TypeError, KeyError) as error:
                ERRORS.append(f"release availability evidence is unreadable: {error}")
    elif public_latest is True:
        require(release.get("publicationStatus") == "published", "a public latest release must be labeled published")
        evidence = ROOT / str(release.get("evidence", ""))
        try:
            snapshot = json.loads(evidence.read_text(encoding="utf-8"))
            check_published_release(release, snapshot)
        except (OSError, ValueError, TypeError) as error:
            ERRORS.append(f"published release evidence is unreadable: {error}")
        require(f"/releases/tag/{release.get('tag')}" in readme, "README must link the recorded published tag")
    for phrase in ("off by default", "Trakt", "full source path", "source credentials", "encrypted progress"):
        require(phrase.lower() in privacy.lower(), f"privacy notice is missing '{phrase}'")


def check_published_release(release: dict, metadata: dict) -> None:
    """Compare the ledger with independent GitHub metadata, not README prose."""
    require(metadata.get("draft") is False, "release evidence is still a draft")
    require(metadata.get("prerelease") is False, "latest stable release evidence is a prerelease")
    require(metadata.get("tag_name") == release.get("tag") == f"v{release.get('version')}", "published release tag/version is stale")
    require(metadata.get("published_at") == release.get("publishedAt"), "published release date differs from evidence")
    require(metadata.get("target_commitish") == release.get("targetCommitish", release.get("sourceCommit")), "published release source commit differs from evidence")
    if "targetCommitish" in release:
        require(metadata.get("tag_commit") == release.get("sourceCommit"), "published release immutable tag commit differs from evidence")
    names = metadata.get("assetNames")
    if names is None:
        names = [asset.get("name") for asset in metadata.get("assets", []) if isinstance(asset, dict)]
    require(isinstance(names, list) and bool(names), "published release evidence has no assets")
    missing_webos = not any(isinstance(name, str) and name.endswith(".ipk") for name in names or [])
    require(("webos" in release.get("missingPublicPlatforms", [])) == missing_webos, "webOS publication status differs from actual release assets")


def check_release_availability(release: dict, observation: dict) -> None:
    """Keep historical publication evidence separate from current availability."""
    require(observation.get("observedAt") == release.get("availabilityCheckedOn"), "release availability dates differ")
    require(observation.get("latestStatus") == 404, "unavailable latest release needs an observed 404")
    require(observation.get("tag") == release.get("tag"), "release availability tag differs")
    require(observation.get("tagStatus") == 404, "unavailable recorded release needs an observed tag 404")
    require(observation.get("listStatus") == 200, "release availability needs a successful list response")
    releases = observation.get("listedReleases")
    require(isinstance(releases, list), "release availability needs the observed release list")
    if isinstance(releases, list):
        require(all(isinstance(item, dict) and (item.get("draft") is True or item.get("prerelease") is True)
                    for item in releases), "a stable public release is present in the availability observation")


def _github_json(repository: str, path: str, token: str) -> tuple[int, object]:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/{path}",
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read(16 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return 404, None
        raise ValueError(f"GitHub release request failed (HTTP {error.code}).") from None
    except (urllib.error.URLError, OSError) as error:
        raise ValueError(f"GitHub release request failed ({type(error).__name__}).") from None
    if len(payload) > 16 * 1024 * 1024:
        raise ValueError("GitHub release response exceeded the size limit.")
    return 200, json.loads(payload)


def _release_json(repository: str, suffix: str, token: str) -> tuple[int, object]:
    return _github_json(repository, f"releases{suffix}", token)


def _tag_commit(repository: str, tag: str, token: str) -> str:
    status, data = _github_json(repository, f"git/ref/tags/{urllib.parse.quote(tag, safe='')}", token)
    obj = data.get('object', {}) if status == 200 and isinstance(data, dict) else {}
    for _ in range(5):
        sha = obj.get('sha', '')
        if not re.fullmatch(r'[0-9a-f]{40}', sha):
            break
        if obj.get('type') == 'commit':
            return sha
        if obj.get('type') != 'tag':
            break
        status, data = _github_json(repository, f"git/tags/{sha}", token)
        obj = data.get('object', {}) if status == 200 and isinstance(data, dict) else {}
    raise ValueError('Cannot resolve the published release immutable tag commit.')


def check_live_release(release: dict, repository: str, token: str) -> None:
    """Check documented availability without treating authentication failures as absence."""
    if not token or re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is None:
        raise ValueError("Live release validation requires GH_TOKEN and GITHUB_REPOSITORY.")
    status, latest = _release_json(repository, "/latest", token)
    if status == 200:
        require(release.get("publicLatestAvailable") is True,
                "a public latest release exists; update the release availability ledger")
        if not isinstance(latest, dict):
            raise ValueError("GitHub latest release metadata is not an object.")
        if "targetCommitish" in release:
            latest = {**latest, "tag_commit": _tag_commit(repository, latest.get("tag_name", ""), token)}
        check_published_release(release, latest)
        return

    require(release.get("publicLatestAvailable") is False,
            "the recorded public latest release is unavailable")
    require(release.get("publicationStatus") in {"draft", "unavailable"},
            "missing latest release must be explicitly documented")
    # A successful authenticated list distinguishes an absent latest release
    # from inaccessible repository metadata. Check every bounded list page.
    for page in range(1, 21):
        list_status, listed = _release_json(repository, f"?per_page=100&page={page}", token)
        if list_status != 200 or not isinstance(listed, list):
            raise ValueError("Cannot verify release absence without a successful release list.")
        require(all(isinstance(item, dict) and
                    (item.get("draft") is True or item.get("prerelease") is True)
                    for item in listed), "the release list contains an undocumented public stable release")
        if len(listed) < 100:
            break
    else:
        raise ValueError("GitHub release list exceeded the pagination limit.")
    tag = urllib.parse.quote(str(release.get("tag", "")), safe="")
    tag_status, tagged = _release_json(repository, f"/tags/{tag}", token)
    if release.get("publicationStatus") == "unavailable":
        require(tag_status == 404, "the recorded unavailable release tag has reappeared")
    elif tag_status == 200:
        require(isinstance(tagged, dict) and
                (tagged.get("draft") is True or tagged.get("prerelease") is True),
                "the recorded draft release is now public and stable")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    live = parser.add_mutually_exclusive_group()
    live.add_argument("--release-metadata", type=Path, help="Independently fetched GitHub latest-release JSON")
    live.add_argument("--live", action="store_true", help="Validate current GitHub publication or documented absence")
    args = parser.parse_args()
    data = _load_manifest()
    if data is not None:
        check_manifest(data)
        if args.release_metadata is not None:
            try:
                check_published_release(data["release"], json.loads(args.release_metadata.read_text(encoding="utf-8")))
            except (OSError, ValueError, TypeError) as error:
                ERRORS.append(f"cannot read independent release metadata: {error}")
        if args.live:
            try:
                check_live_release(data["release"], os.environ.get("GITHUB_REPOSITORY", ""),
                                   os.environ.get("GH_TOKEN", ""))
            except (OSError, ValueError, TypeError) as error:
                ERRORS.append(f"cannot validate live release availability: {error}")
    if ERRORS:
        for error in ERRORS:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("capability manifest checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
