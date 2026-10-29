#!/usr/bin/env python3
"""Materialize a commit-pinned HF model and record hashes for offline hosts."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="Model owner/name")
    parser.add_argument("--revision", required=True, help="Exact 40-character model repository commit")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo) or not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        parser.error("Use a model repository and its exact commit, not a moving branch or tag")
    from huggingface_hub import snapshot_download
    root = args.output.resolve()
    if root.exists() and any(root.iterdir()):
        parser.error("Use an empty output directory so rollback keeps the previous model intact")
    root.mkdir(parents=True, exist_ok=True)
    snapshot_download(repo_id=args.repo, revision=args.revision, local_dir=root,
                      allow_patterns=["*.json", "*.bin", "*.safetensors", "*.txt", "*.model", "README*", "LICENSE*"],
                      ignore_patterns=["*.py", "*.pt", "*.pkl", "*.pickle"])
    files = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or ".cache" in path.relative_to(root).parts:
            continue
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        files.append({"path": str(path.relative_to(root)), "bytes": path.stat().st_size, "sha256": digest.hexdigest()})
    manifest = {"schema": 1, "repo": args.repo, "revision": args.revision, "files": files,
                "license": "See the pinned model card and license files; access does not establish redistribution rights."}
    (root / "plezy-model-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"Prepared {len(files)} files at {root}. Configure the host to use this directory.")


if __name__ == "__main__":
    main()
