#!/usr/bin/env python3
"""Retry generated Nix metadata on fresh main without overwriting concurrent work."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

from nix_release_metadata import METADATA_PATH


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], check=check, capture_output=True, text=True)


def reconcile(repo: Path, scratch: Path, tag: str | None = None) -> str:
    scratch.mkdir(parents=True, exist_ok=False)
    for number in range(1, 4):
        git(repo, "fetch", "origin", "main")
        parent = git(repo, "rev-parse", "origin/main").stdout.strip()
        checkout = scratch / f"attempt-{number}"
        receipt = scratch / f"attempt-{number}.json"
        git(repo, "worktree", "add", "--detach", str(checkout), parent)
        try:
            command = ["python3", str(checkout / "scripts/refresh_release_facts.py"),
                       "--nix-only", "--receipt", str(receipt)]
            if tag:
                command.extend(["--tag", tag])
            subprocess.run(command, cwd=checkout, check=True)
            status = git(checkout, "status", "--porcelain").stdout.splitlines()
            if not status:
                return "unchanged"
            if status != [f" M {METADATA_PATH}"]:
                raise ValueError("Metadata refresh changed paths outside its ownership")
            git(checkout, "diff", "--check")
            (scratch / f"attempt-{number}.patch").write_text(git(checkout, "diff", "--", METADATA_PATH).stdout)
            git(checkout, "add", "--", METADATA_PATH)
            git(checkout, "-c", "core.hooksPath=/dev/null", "-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "commit", "-m", "Update authenticated Nix release metadata")
            result = git(checkout, "push", "origin", "HEAD:refs/heads/main", check=False)
            if result.returncode == 0:
                return "updated"
            # Retry only an actual main race, never a permission/transport error.
            remote = git(repo, "ls-remote", "origin", "refs/heads/main").stdout.split()[0]
            if remote == parent:
                raise RuntimeError("Nix metadata push failed without concurrent main movement")
        finally:
            # Clean committed attempts are disposable; a failed dirty attempt is
            # retained with its receipt/patch for inspection, never force-removed.
            git(repo, "worktree", "remove", str(checkout), check=False)
    raise RuntimeError("Main advanced during all three Nix metadata attempts")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", required=True, type=Path)
    parser.add_argument("--tag")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    print(json.dumps({"state": reconcile(repo, args.scratch.resolve(), args.tag)}))


if __name__ == "__main__":
    main()
