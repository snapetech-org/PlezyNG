#!/usr/bin/env python3
"""Render the Homebrew Cask from a release version and SHA256SUMS.txt."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SHA_PATTERN = re.compile(r"^([0-9a-fA-F]{64})\s+pleazyng-macos\.dmg$")
TEMPLATE_PATH = Path(__file__).resolve().parents[1] / "Casks" / "snapetech-pleazyng.rb.template"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="stable MAJOR.MINOR.PATCH release version")
    parser.add_argument("--checksums", required=True, type=Path, help="release SHA256SUMS.txt")
    parser.add_argument("--output", required=True, type=Path, help="path for the rendered Cask file")
    parser.add_argument("--publisher-repository-file", type=Path,
                        help="publisher identity produced by verify_release_attestation.py")
    args = parser.parse_args()

    if not VERSION_PATTERN.fullmatch(args.version):
        parser.error("version must be a stable MAJOR.MINOR.PATCH release")
    if not args.checksums.is_file():
        parser.error(f"checksum manifest does not exist: {args.checksums}")

    matches = [
        match.group(1).lower()
        for line in args.checksums.read_text(encoding="utf-8").splitlines()
        if (match := SHA_PATTERN.fullmatch(line.strip()))
    ]
    if len(matches) != 1:
        parser.error("checksum manifest must contain exactly one SHA-256 entry for pleazyng-macos.dmg")

    if not TEMPLATE_PATH.is_file():
        parser.error(f"Cask template does not exist: {TEMPLATE_PATH}")
    template = TEMPLATE_PATH.read_text(encoding="utf-8")
    if args.publisher_repository_file:
        publisher = args.publisher_repository_file.read_text(encoding="utf-8").strip()
        if publisher not in {"snapetech-org/pleazyng", "snapetech-org/PlezyNG"}:
            parser.error("unrecognized Cask publisher repository")
        template = template.replace("snapetech-org/pleazyng", publisher)
    if template.count("@@VERSION@@") != 1 or template.count("@@SHA256@@") != 1:
        parser.error("Cask template must contain one version placeholder and one SHA-256 placeholder")

    rendered = template.replace("@@VERSION@@", args.version).replace("@@SHA256@@", matches[0])
    if "@@" in rendered:
        parser.error("rendered Cask contains an unresolved placeholder")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")
    print(f"Wrote {args.output} for Pleazyng {args.version}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
