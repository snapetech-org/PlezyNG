#!/usr/bin/env python3
"""Update the authoritative Flutter version and webOS package metadata together."""

import argparse
import json
from pathlib import Path
import re

from pubspec_version import parse_pubspec_version


ROOT = Path(__file__).resolve().parents[1]


def set_release_version(root: Path, version: str) -> None:
    full_version, _ = parse_pubspec_version(f"version: {version}\n")
    pubspec = root / "pubspec.yaml"
    appinfo = root / "webos/meta/appinfo.json"
    for path in (pubspec, appinfo):
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected a regular source file: {path}")
    source = pubspec.read_text(encoding="utf-8")
    parse_pubspec_version(source)
    metadata = json.loads(appinfo.read_text(encoding="utf-8"))
    if not isinstance(metadata, dict) or metadata.get("id") != "org.snapetech.pleazyng" or metadata.get("type") != "native":
        raise ValueError("Unexpected webOS package identity; no versions were changed")
    metadata["version"] = full_version.split("+", 1)[0]
    # Validate both inputs before changing either tracked file. Git retains the
    # reviewable milestone if the operator is interrupted between these writes.
    updated = re.sub(r"(?m)^version:[^\n]*", f"version: {full_version}", source, count=1)
    rendered = json.dumps(metadata, indent=4, ensure_ascii=False) + "\n"
    pubspec.write_text(updated, encoding="utf-8")
    appinfo.write_text(rendered, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="MAJOR.MINOR.PATCH+BUILD, for example 3.0.7+166")
    args = parser.parse_args()
    set_release_version(ROOT, args.version)
    print(f"Updated pubspec.yaml and webos/meta/appinfo.json to {args.version}")


if __name__ == "__main__":
    main()
