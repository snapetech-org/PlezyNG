#!/usr/bin/env python3
"""Create a tracked Apple source workspace without copying caches or xattrs."""

import argparse
import re
import subprocess
from pathlib import Path


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def copy_sources(source, destination, revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("An exact GitHub source SHA is required.")
    if source.is_symlink() or not source.is_dir():
        raise ValueError("The source must be a real Git checkout.")
    if destination.is_symlink() or not destination.is_dir() or any(destination.iterdir()):
        raise ValueError("The task destination must be an existing empty directory.")
    source = source.resolve()
    destination = destination.resolve()
    if source == destination or source in destination.parents:
        raise ValueError("The source workspace cannot contain the task destination.")
    if Path(git(source, "rev-parse", "--show-toplevel")).resolve() != source:
        raise ValueError("The source must be the checkout root.")
    if git(source, "rev-parse", "HEAD") != revision:
        raise ValueError("The source checkout does not match the requested revision.")
    if git(source, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Refusing to omit modified tracked source files.")
    # The original job checkout remains present until all Apple consumers exit.
    # Borrow its local object database instead of copying packs over NFS. A real
    # checkout preserves Git queries, tracked symlinks and executable bits while
    # avoiding ignored caches, checkout credentials and APFS provenance xattrs.
    subprocess.run(["git", "clone", "--shared", "--no-checkout", "--no-tags",
                    "--", str(source), str(destination)], check=True)
    subprocess.run(["git", "-C", str(destination), "checkout", "--detach", revision], check=True)
    if git(destination, "rev-parse", "HEAD") != revision:
        raise RuntimeError("The Apple source workspace has an unexpected revision.")
    print(f"Prepared tracked Apple sources at {destination} from {revision}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("revision")
    args = parser.parse_args()
    copy_sources(args.source, args.destination, args.revision)


if __name__ == "__main__":
    main()
