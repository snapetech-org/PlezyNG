#!/usr/bin/env python3
"""Retain diagnostics and remove only this completed JIT job's Xcode output."""

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import time
from pathlib import Path, PurePosixPath


def owned_workspace(workspace, runner_root, run_id, attempt):
    if not isinstance(workspace, str):
        return False
    workspace = PurePosixPath(workspace)
    if ".." in workspace.parts:
        return False
    for repository in ("pleazyng", "PlezyNG", "plezyng"):
        try:
            local = workspace.relative_to(
                PurePosixPath(runner_root) / "_work" / repository / repository
            )
            if local.parts and local.parts[0] in {"ios", "tvos", "macos"}:
                return True
        except ValueError:
            pass
    for mount in ("/Volumes/p", "/Volumes/plezyng-native-build-kspld0"):
        try:
            relative = workspace.relative_to(PurePosixPath(mount) / "runs")
        except ValueError:
            continue
        if (
            len(relative.parts) >= 3
            and re.fullmatch(rf"p{run_id}-{attempt}-[A-Za-z0-9_-]+", relative.parts[0])
            and relative.parts[1] in {"ios", "tvos", "macos"}
        ):
            return True
    return False


def clean(derived_root, runner_root, run_id, attempt, conclusion):
    retained = runner_root / "_diag/derived-data"
    if derived_root.is_symlink() or retained.is_symlink():
        raise RuntimeError("Refusing cleanup through a symlink.")
    cleaned = []
    for candidate in sorted(derived_root.glob("Runner-*")):
        info = candidate / "info.plist"
        if candidate.is_symlink() or not candidate.is_dir() or info.is_symlink() or not info.is_file():
            continue
        if candidate.stat().st_uid != os.geteuid():
            continue
        try:
            with info.open("rb") as stream:
                metadata = plistlib.load(stream)
                workspace = metadata.get("WorkspacePath") if isinstance(metadata, dict) else None
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if not owned_workspace(workspace, runner_root, run_id, attempt):
            continue
        # Shared caches and unfamiliar contents require separate inspection.
        if any(child.name not in {"Build", "Logs", "info.plist"} or child.is_symlink()
               for child in candidate.iterdir()):
            print(f"Retained unfamiliar DerivedData contents: {candidate}")
            continue
        target = retained / candidate.name
        if target.exists() or target.is_symlink():
            raise RuntimeError(f"Refusing to overwrite retained diagnostics: {target}")
        retained.mkdir(mode=0o700, parents=True, exist_ok=True)
        if conclusion != "success":
            # Preserve failed build products as well as logs in the job archive.
            shutil.move(str(candidate), target)
        else:
            target.mkdir(mode=0o700)
            shutil.copy2(info, target / "info.plist")
            if (candidate / "Logs").is_dir():
                shutil.copytree(candidate / "Logs", target / "Logs", symlinks=True)
            shutil.rmtree(candidate)
        cleaned.append(str(candidate))
        print(f"Preserved diagnostics and cleared completed-job DerivedData: {candidate}")
    return cleaned


def wait_for_idle(timeout=30):
    """Wait briefly for exiting consumers; never clean without an idle sample."""
    deadline = time.monotonic() + timeout
    active = []
    announced = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            consumers = ", ".join(active) or "idle state not confirmed"
            raise SystemExit(
                f"Apple build consumers did not become idle within {timeout:g}s "
                f"({consumers}); keeping DerivedData."
            )
        # A stalled process query must not make the bounded wait unbounded.
        # Query failures propagate, preserving all output for diagnosis.
        processes = subprocess.check_output(
            ["/bin/ps", "-U", "gha-jit-macos", "-o", "comm="],
            text=True, timeout=min(5, remaining),
        )
        active = sorted({
            Path(line.strip()).name for line in processes.splitlines()
            if Path(line.strip()).name in {"Runner.Listener", "xcodebuild"}
        })
        if not active:
            return
        if not announced:
            print(f"Waiting up to {timeout:g}s for Apple build consumers: {', '.join(active)}",
                  flush=True)
            announced = True
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(1, remaining))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id")
    parser.add_argument("attempt")
    parser.add_argument("runner_root", type=Path)
    parser.add_argument("conclusion")
    args = parser.parse_args()
    prefix = Path("/Users/gha-jit-macos/Library/Caches/gha-jit-macos/runs")
    if (not args.run_id.isdigit() or not args.attempt.isdigit()
        or args.runner_root.parent.parent != prefix
        or not re.fullmatch(rf"{args.run_id}-[0-9]+-attempt{args.attempt}", args.runner_root.parent.name)
        or args.runner_root.name != "runner" or args.runner_root.is_symlink()
        or (args.runner_root / "_diag").is_symlink()
        or not (args.runner_root / "_diag").is_dir()):
        raise SystemExit("Refusing cleanup outside the exact completed JIT runner root.")
    wait_for_idle()
    clean(Path.home() / "Library/Developer/Xcode/DerivedData", args.runner_root,
          args.run_id, args.attempt, args.conclusion)


if __name__ == "__main__":
    main()
