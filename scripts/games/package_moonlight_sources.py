#!/usr/bin/env python3
"""Create the corresponding-source archive for Pleazyng's Android Moonlight build."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = ROOT / ".dart_tool/games/moonlight-android"
PREPARE_SCRIPT = ROOT / "scripts/games/prepare_moonlight.py"
ARCHIVE_ROOT = "pleazyng-moonlight-android-source"
GENERATED_PARTS = {".git", ".gradle", ".cxx", "build", "intermediates", "outputs", "target"}


def run(*args: str, cwd: Path) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def recipe_hash(lock: dict[str, object]) -> str:
    return hashlib.sha256(
        PREPARE_SCRIPT.read_bytes() + json.dumps(lock, sort_keys=True).encode()
    ).hexdigest()


def source_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        retained_directories = []
        for name in sorted(directories):
            path = current_path / name
            relative = path.relative_to(root)
            if name in GENERATED_PARTS:
                continue
            if path.is_symlink():
                target = (path.parent / os.readlink(path)).resolve()
                try:
                    target.relative_to(root.resolve())
                except ValueError as error:
                    raise ValueError(f"Moonlight source symlink escapes the source tree: {relative}") from error
                paths.append(path)
            else:
                paths.append(path)
                retained_directories.append(name)
        directories[:] = retained_directories
        for name in sorted(files):
            path = current_path / name
            relative = path.relative_to(root)
            if name in GENERATED_PARTS:
                continue
            if path.is_symlink():
                target = (path.parent / os.readlink(path)).resolve()
                try:
                    target.relative_to(root.resolve())
                except ValueError as error:
                    raise ValueError(f"Moonlight source symlink escapes the source tree: {relative}") from error
                paths.append(path)
            elif path.is_file():
                paths.append(path)
    return sorted(paths, key=lambda path: path.relative_to(root).as_posix())


def hash_source_tree(root: Path, files: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in files:
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            content_hash = hashlib.sha256(os.readlink(path).encode()).digest()
        elif path.is_file():
            content_hash = hashlib.sha256(path.read_bytes()).digest()
        else:
            continue
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(content_hash)
    return digest.hexdigest()


def add_path(archive: tarfile.TarFile, path: Path, name: str) -> None:
    if path.is_symlink():
        info = tarfile.TarInfo(name)
        info.type = tarfile.SYMTYPE
        info.linkname = os.readlink(path)
        info.mode = 0o777
        info.mtime = 0
        info.uid = 0
        info.gid = 0
        info.uname = ""
        info.gname = ""
        archive.addfile(info)
        return

    info = archive.gettarinfo(str(path), name)
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    if path.is_file():
        info.mode = stat.S_IMODE(path.stat().st_mode)
        with path.open("rb") as source:
            archive.addfile(info, source)
    else:
        info.mode = 0o755
        archive.addfile(info)


def prepare_archive(
    source: Path,
    output: Path,
    application_commit: str,
    release_tag: str,
) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", application_commit):
        raise ValueError("application commit must be a full lowercase Git SHA")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", release_tag):
        raise ValueError("release tag must be a versioned Pleazyng tag")
    if run("git", "rev-parse", "HEAD", cwd=ROOT) != application_commit:
        raise ValueError("application commit does not match the checked out source")

    lock = json.loads((ROOT / "games-native.lock.json").read_text())["moonlightAndroid"]
    if not source.is_dir():
        raise FileNotFoundError(f"Prepared Moonlight source is missing: {source}")
    marker = source / ".plezy-recipe"
    if not marker.is_file() or marker.read_text().strip() != recipe_hash(lock):
        raise ValueError("Prepared Moonlight source does not match the locked patch recipe")
    if run("git", "rev-parse", "HEAD", cwd=source) != lock["revision"]:
        raise ValueError("Prepared Moonlight source does not match the locked upstream revision")
    submodule = run(
        "git",
        "ls-tree",
        "HEAD",
        "app/src/main/jni/moonlight-core/moonlight-common-c",
        cwd=source,
    )
    if not submodule.endswith(lock["commonRevision"] + "\tapp/src/main/jni/moonlight-core/moonlight-common-c"):
        raise ValueError("Prepared Moonlight source does not match the locked common submodule revision")

    files = source_files(source)
    receipt = {
        "schema": 1,
        "applicationRepository": "https://github.com/snapetech-org/pleazyng",
        "applicationCommit": application_commit,
        "releaseTag": release_tag,
        "upstreamRepository": lock["repository"],
        "upstreamRevision": lock["revision"],
        "upstreamVersion": lock["version"],
        "commonSubmoduleRevision": lock["commonRevision"],
        "license": lock["license"],
        "preparedSourceSha256": hash_source_tree(source, files),
    }
    included = [
        ROOT / "docs/games/MOONLIGHT_SOURCE.md",
        ROOT / "games-native.lock.json",
        PREPARE_SCRIPT,
        ROOT / "UPSTREAM_ATTRIBUTION.md",
        ROOT / "assets/licenses/Moonlight_GPL_3.txt",
        ROOT / "assets/licenses/Moonlight_NOTICE.txt",
        ROOT / "android/settings.gradle.kts",
        ROOT / "android/app/build.gradle.kts",
        ROOT / "android/moonlight/build.gradle",
        ROOT / "android/moonlight/consumer-rules.pro",
        ROOT / "android/moonlight/src/main/java/org/snapetech/plezyng/games/EmbeddedGameStream.java",
        ROOT / "android/moonlight/src/main/java/org/snapetech/plezyng/games/MoonlightStreamView.java",
        ROOT / "android/app/src/main/kotlin/com/edde746/plezy/GameStreamPlatformViewFactory.kt",
        ROOT / "android/app/src/main/kotlin/com/edde746/plezy/GamesChannel.kt",
        ROOT / "android/app/src/main/kotlin/com/edde746/plezy/PlezyActivity.kt",
        ROOT / "lib/multiview/moonlight_game_workspace_surface.dart",
        ROOT / "lib/screens/games/games_screen.dart",
    ]
    missing = [path.relative_to(ROOT) for path in included if not path.is_file()]
    if missing:
        raise FileNotFoundError("Required Moonlight source inputs are missing: " + ", ".join(map(str, missing)))

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=output.name + ".", delete=False) as raw:
        temporary = Path(raw.name)
    try:
        with temporary.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for path in files:
                        name = PurePosixPath(ARCHIVE_ROOT, "upstream", path.relative_to(source).as_posix()).as_posix()
                        add_path(archive, path, name)
                    for path in included:
                        add_path(
                            archive,
                            path,
                            PurePosixPath(ARCHIVE_ROOT, "pleazyng", path.relative_to(ROOT).as_posix()).as_posix(),
                        )
                    receipt_bytes = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()
                    info = tarfile.TarInfo(PurePosixPath(ARCHIVE_ROOT, "SOURCE-RECEIPT.json").as_posix())
                    info.size = len(receipt_bytes)
                    info.mode = 0o644
                    info.mtime = 0
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    archive.addfile(info, io.BytesIO(receipt_bytes))
        os.replace(temporary, output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE_ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--application-commit", required=True)
    parser.add_argument("--release-tag", required=True)
    args = parser.parse_args()
    prepare_archive(
        args.source.resolve(),
        args.output.resolve(),
        args.application_commit,
        args.release_tag,
    )


if __name__ == "__main__":
    main()
