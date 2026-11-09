#!/usr/bin/env python3
"""Record independently fetched public release facts without changing product code."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import subprocess

from release_coverage import missing_assets


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "snapetech-org/pleazyng"


def github(path: str) -> dict:
    result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/{path}"],
                            check=True, capture_output=True, text=True)
    data = json.loads(result.stdout)
    if not isinstance(data, dict):
        raise ValueError("Expected a GitHub metadata object")
    return data


def tag_commit(tag: str) -> str:
    obj = github(f"git/ref/tags/{tag}").get("object", {})
    for _ in range(5):
        sha = obj.get("sha", "")
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            break
        if obj.get("type") == "commit":
            return sha
        if obj.get("type") != "tag":
            break
        obj = github(f"git/tags/{sha}").get("object", {})
    raise ValueError("Cannot resolve the immutable release tag")


def update(root: Path, metadata: dict, commit: str, observed: str) -> list[str]:
    tag = metadata.get("tag_name", "")
    if (not re.fullmatch(r"v\d+\.\d+\.\d+", tag)
            or metadata.get("draft") is not False or metadata.get("prerelease") is not False
            or not metadata.get("published_at") or not re.fullmatch(r"[0-9a-f]{40}", commit)):
        raise ValueError("Only an actual stable published release with an immutable tag is recordable")
    names = sorted(asset["name"] for asset in metadata.get("assets", [])
                   if isinstance(asset, dict) and isinstance(asset.get("name"), str) and asset.get("size", 0) > 0)
    missing = missing_assets(set(names))
    if missing:
        raise ValueError("Published release is incomplete: " + "; ".join(missing))
    page = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    snapshot = {"schemaVersion": 1, "observedAt": observed,
                "source": f"https://api.github.com/repos/{REPOSITORY}/releases/latest",
                **{key: metadata.get(key) for key in ("id", "tag_name", "target_commitish", "draft", "prerelease", "published_at")},
                "tag_commit": commit, "html_url": page, "assetNames": names}
    manifest_path = root / "docs/maintainers/capability-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    release = manifest["release"]
    release.update(version=tag[1:], tag=tag, publicationStatus="published", publicLatestAvailable=True,
                   publishedAt=metadata["published_at"], sourceCommit=commit,
                   targetCommitish=metadata.get("target_commitish"),
                   evidence=f"docs/maintainers/releases/{tag}.json", coverageStatus="complete", missingPublicPlatforms=[])
    release.pop("availabilityEvidence", None)
    release.pop("availabilityCheckedOn", None)
    readme_path = root / "README.md"
    readme = readme_path.read_text()
    start, end = readme.index("## Download\n"), readme.index("<details>", readme.index("## Download\n"))
    download = f"""## Download

[Pleazyng {tag[1:]} is published]({page}) with Android, Fire TV, Linux x64/ARM64, Windows x64/ARM64, universal macOS, iOS, tvOS, Tizen and webOS packages. See the [recorded GitHub publication evidence]({release['evidence']}) and [all releases](https://github.com/{REPOSITORY}/releases).

| Platform | Download |
| --- | --- |
| Desktop and mobile | [Release files for Android, Fire TV, Linux, Windows, macOS, iOS and tvOS]({page}) |
| webOS TV | [Experimental ARMv7 IPK]({page}); model/firmware and media playback qualification remain separate from publication. See the [compatibility matrix and port status](docs/maintainers/webos-tv.md). |
| Samsung Tizen TV | [Experimental ARM tester handoff]({page}); TV qualification and Tizen 10 remain pending. See the [build guide and rollout plan](docs/maintainers/tizen-tv.md). |

"""
    outputs = {manifest_path: json.dumps(manifest, indent=2) + "\n",
               root / release["evidence"]: json.dumps(snapshot, indent=2) + "\n",
               readme_path: readme[:start] + download + readme[end:]}
    changed = []
    for path, text in outputs.items():
        if not path.exists() or path.read_text() != text:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            changed.append(path.relative_to(root).as_posix())
    return changed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Require this published tag to be the current public latest")
    args = parser.parse_args()
    metadata = github("releases/latest")
    tag = metadata.get("tag_name", "")
    if args.tag and tag != args.tag:
        raise ValueError(f"Public latest is {tag}, expected {args.tag}")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Unexpected stable release tag")
    changed = update(ROOT, metadata, tag_commit(tag), dt.datetime.now(dt.timezone.utc).date().isoformat())
    print(json.dumps({"tag": tag, "changed": changed}))


if __name__ == "__main__":
    main()
