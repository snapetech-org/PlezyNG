#!/usr/bin/env python3
"""Verify release signatures across the repository rename without changing trust."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

REPOSITORY = "snapetech-org/pleazyng"
LEGACY_REPOSITORY = "snapetech-org/PlezyNG"
REPOSITORY_ID = 1433487464


def require_repository_identity(repository: str) -> None:
    metadata = json.loads(subprocess.check_output(
        ["gh", "api", f"repos/{repository}"], text=True,
    ))
    if (metadata.get("id") != REPOSITORY_ID
            or metadata.get("full_name", "").lower() != REPOSITORY):
        raise ValueError("Repository URL does not resolve to the original Pleazyng repository ID")


def verify(asset: Path, repository: str = REPOSITORY) -> str:
    if repository.lower() not in {REPOSITORY, LEGACY_REPOSITORY.lower()}:
        raise ValueError("Release verification is restricted to the Pleazyng repository")
    if not asset.is_file():
        raise ValueError("Release artifact must be an existing file")
    require_repository_identity(REPOSITORY)
    for signer in (REPOSITORY, LEGACY_REPOSITORY):
        if signer == LEGACY_REPOSITORY:
            # A recreated old repository must never inherit this trust.
            require_repository_identity(LEGACY_REPOSITORY)
        result = subprocess.run(
            ["gh", "attestation", "verify", str(asset), "--repo", signer],
            stdout=sys.stderr,
        )
        if result.returncode == 0:
            return signer
    raise ValueError("Artifact attestation did not verify under either original repository identity")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asset", type=Path)
    parser.add_argument("--repo", default=REPOSITORY)
    parser.add_argument("--repository-output", type=Path,
                        help="record the verified publisher identity for immutable metadata comparisons")
    args = parser.parse_args()
    try:
        publisher = verify(args.asset, args.repo)
        if args.repository_output:
            with args.repository_output.open("x") as output:
                output.write(publisher + "\n")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release attestation verification failed: {error}\n")
    print(f"Verified release attestation from {publisher} (repository ID {REPOSITORY_ID}).")


if __name__ == "__main__":
    main()
