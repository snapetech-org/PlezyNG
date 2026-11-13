#!/usr/bin/env python3
"""Update an AUR PKGBUILD version and reset pkgrel only for a new version."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")
PKGVER = re.compile(r"(?m)^pkgver=([^\r\n]+)$")
PKGREL = re.compile(r"(?m)^pkgrel=([1-9][0-9]*)$")


class PkgbuildError(ValueError):
    """The package recipe does not have the expected version fields."""


def update_pkgbuild_version(path: Path, version: str) -> bool:
    """Set ``pkgver``; reset ``pkgrel`` to 1 only when ``pkgver`` changes.

    Keeping the existing release number for a same-version publication lets a
    maintainer retry a corrected package without silently undoing a manual
    ``pkgrel`` increment.
    """
    if not VERSION.fullmatch(version):
        raise PkgbuildError(f"Expected a stable semantic version, got: {version!r}")

    text = path.read_text(encoding="utf-8")
    version_matches = list(PKGVER.finditer(text))
    release_matches = list(PKGREL.finditer(text))
    if len(version_matches) != 1:
        raise PkgbuildError(f"Expected exactly one pkgver assignment, found {len(version_matches)}")
    if len(release_matches) != 1:
        raise PkgbuildError(f"Expected exactly one positive integer pkgrel assignment, found {len(release_matches)}")

    current_version = version_matches[0].group(1)
    version_changed = current_version != version
    text = PKGVER.sub(f"pkgver={version}", text, count=1)
    if version_changed:
        text = PKGREL.sub("pkgrel=1", text, count=1)

    path.write_text(text, encoding="utf-8")
    return version_changed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pkgbuild", type=Path)
    parser.add_argument("version")
    args = parser.parse_args(argv)

    try:
        changed = update_pkgbuild_version(args.pkgbuild, args.version)
    except (OSError, PkgbuildError) as error:
        print(f"update AUR PKGBUILD: {error}", file=sys.stderr)
        return 1

    if changed:
        print(f"Updated pkgver to {args.version} and reset pkgrel to 1.")
    else:
        print(f"pkgver is already {args.version}; preserving pkgrel.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
