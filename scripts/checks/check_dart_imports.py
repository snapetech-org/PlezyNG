#!/usr/bin/env python3
"""Check relative Dart directives without downloading Flutter dependencies."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import posixpath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def trivia(source: str, at: int) -> int:
    while at < len(source):
        if source[at].isspace():
            at += 1
        elif source.startswith("//", at):
            end = source.find("\n", at)
            at = len(source) if end < 0 else end + 1
        elif source.startswith("/*", at):
            at += 2
            depth = 1
            while at < len(source) and depth:
                if source.startswith("/*", at):
                    depth += 1; at += 2
                elif source.startswith("*/", at):
                    depth -= 1; at += 2
                else:
                    at += 1
        else:
            break
    return at


def directive_uris(source: str) -> list[str]:
    """Only read the directive header; examples in executable strings are inert."""
    paths, at = [], 0
    while at < len(source):
        at = trivia(source, at)
        match = re.match(r"(import|export|part|library)\b", source[at:])
        if not match:
            break
        directive = match[1]
        at += match.end()
        while at < len(source):
            at = trivia(source, at)
            if at == len(source) or source[at] == ";":
                at += 1
                break
            raw = source[at:at + 1] == "r" and source[at + 1:at + 2] in ("'", '"')
            if raw:
                at += 1
            if source[at] not in ("'", '"'):
                at += 1
                continue
            quote, text = source[at], []
            at += 1
            while at < len(source) and source[at] != quote:
                if not raw and source[at] == "\\" and at + 1 < len(source):
                    at += 1
                text.append(source[at]); at += 1
            at += 1
            value = "".join(text)
            if directive != "library":
                paths.append(value)
    return paths


def relative_directives(source: str) -> list[str]:
    return [uri for uri in directive_uris(source) if ":" not in uri]


def missing_targets(path: str, source: str, tracked: set[str]) -> list[dict[str, str]]:
    result = []
    for uri in relative_directives(source):
        target = posixpath.normpath(posixpath.join(posixpath.dirname(path), uri))
        if target not in tracked:
            result.append({"file": path, "uri": uri, "target": target})
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tracked-paths", type=Path, help="Read an exact tracked-path inventory, one path per line")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.tracked_paths:
        tracked = set(args.tracked_paths.read_text().splitlines())
    else:
        tracked = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0"))
    failures, checked = [], 0
    for path in sorted(tracked):
        if not path.startswith("lib/") or not path.endswith(".dart") or not (ROOT / path).is_file():
            continue
        failures.extend(missing_targets(path, (ROOT / path).read_text(), tracked))
        checked += 1
    if args.json:
        print(json.dumps({"checked": checked, "failures": failures}))
    else:
        for row in failures:
            print(f"{row['file']}: {row['uri']} resolves to missing {row['target']}")
        print(f"Dart relative imports: {checked} files, {len(failures)} missing targets")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
