#!/usr/bin/env python3
"""Stage the exact corresponding source and receipts for bundled libretro cores."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PINS = json.loads((ROOT / "native/games/romm/core-sources.json").read_text())
DEFAULT_CORES = {name for name, pin in PINS.items() if not pin["restricted"]}


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def validate_source(core, root):
    if core not in DEFAULT_CORES:
        raise ValueError(f"Core {core} is not in the default distribution set")
    revision = git(root, "rev-parse", "HEAD").decode().strip()
    if revision != PINS[core]["commit"]:
        raise ValueError(f"Unexpected {core} source revision: {revision}")
    if git(root, "diff", "HEAD", "--") or git(root, "ls-files", "--others", "--exclude-standard"):
        raise ValueError(f"Modified {core} sources cannot use the pinned-source receipt")
    return revision


def append_source(archive, source, revision, prefix):
    # git archive omits submodule content. Include each exact gitlink recursively.
    raw = git(source, "archive", "--format=tar", revision)
    with tarfile.open(fileobj=io.BytesIO(raw)) as tree:
        for member in tree:
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Unsafe source archive path")
            content = tree.extractfile(member) if member.isfile() else None
            member.name = prefix + "/" + member.name
            archive.addfile(member, content)
    for entry in git(source, "ls-tree", "-rz", revision).split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, _, sha = metadata.split()
        if mode != b"160000":
            continue
        name = raw_path.decode()
        child = source / name
        expected = sha.decode()
        if (git(child, "rev-parse", "HEAD").decode().strip() != expected
                or git(child, "diff", "HEAD", "--")
                or git(child, "ls-files", "--others", "--exclude-standard")):
            raise ValueError(f"Unpinned or modified core submodule: {name}")
        append_source(archive, child, expected, prefix + "/" + name)


def parse_inputs(values):
    result = {}
    for value in values:
        name, separator, path = value.partition("=")
        if not separator or name not in DEFAULT_CORES or name in result:
            raise ValueError("Core paths require one unique default-core=path entry")
        result[name] = Path(path).resolve(strict=True)
    if result.keys() != DEFAULT_CORES:
        raise ValueError("Every default core must have source and a built library")
    return result


def stage_host_sources(values, output):
    """Include the actual header implementations, their notices and build recipe."""
    roots = {}
    for value in values:
        name, separator, path = value.partition('=')
        if not separator or name not in {'libretro_common', 'miniaudio'} or name in roots:
            raise ValueError('Invalid host source input')
        roots[name] = Path(path).resolve(strict=True)
    if roots.keys() != {'libretro_common', 'miniaudio'}:
        raise ValueError('Both pinned host dependencies are required')
    recipe = ROOT / 'native/games/romm'
    cmake = (recipe / 'CMakeLists.txt').read_text()
    for name, source in roots.items():
        pin = re.search(r'FetchContent_Declare\(romm_' + name + r'\s+[^\n]*GIT_TAG ([a-f0-9]{40})\b', cmake)
        # An immutable Git object may be an annotated tag. Compare its peeled
        # commit with HEAD while retaining the tag object as the source pin.
        expected = git(source, 'rev-parse', pin[1] + '^{commit}').decode().strip() if pin else None
        if expected is None or git(source, 'rev-parse', 'HEAD').decode().strip() != expected or git(source, 'diff', 'HEAD', '--'):
            raise ValueError('Host dependency differs from its immutable source pin')
    copies = {ROOT / path: 'build-recipe/' + path for path in (
        'native/games/romm/CMakeLists.txt', 'native/games/romm/cores/CMakeLists.txt',
        'native/games/romm/core-sources.json', 'native/games/romm/retro_host.cpp',
        'native/games/romm/NOTICE.md', 'scripts/games/package_romm_cores.py')}
    copies.update({roots['libretro_common'] / 'include/libretro.h': 'host/include/libretro.h',
                   roots['miniaudio'] / 'miniaudio.h': 'host/include/miniaudio.h',
                   roots['miniaudio'] / 'LICENSE': 'host/miniaudio-LICENSE'})
    for source, relative in copies.items():
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)


def package(sources, libraries, output, platform, architecture):
    if sources.keys() != DEFAULT_CORES or libraries.keys() != DEFAULT_CORES:
        raise ValueError("The default core set is incomplete")
    if not platform or not architecture:
        raise ValueError("Core receipts require platform and architecture identities")
    revisions = {name: validate_source(name, root) for name, root in sources.items()}
    for library in libraries.values():
        if not library.is_file() or library.stat().st_size == 0:
            raise ValueError(f"Core library is missing or empty: {library}")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    records = []
    for core in sorted(DEFAULT_CORES):
        revision = revisions[core]
        archive_name = f"{core}-{revision}.tar.gz"
        archive_path = output / archive_name
        # Only reuse an archive with its matching, digest-verified receipt.
        receipt = output / f"{core}-source.json"
        previous = json.loads(receipt.read_text()) if receipt.is_file() else {}
        recipe = digest(Path(__file__))
        reusable = (archive_path.is_file() and previous.get("recipeSha256") == recipe
                    and previous.get("sha256") == digest(archive_path)
                    and previous.get("commit") == revision)
        if not reusable:
            with tempfile.TemporaryDirectory(prefix=core + "-", dir=output) as temporary:
                prepared = Path(temporary) / archive_name
                with prepared.open("wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as compressed:
                    with tarfile.open(fileobj=compressed, mode="w|") as archive:
                        append_source(archive, sources[core], revision, f"{core}-{revision}")
                prepared.replace(archive_path)
                data = {"commit": revision, "sha256": digest(archive_path), "recipeSha256": recipe}
                candidate = Path(temporary) / receipt.name
                candidate.write_text(json.dumps(data, indent=2) + "\n")
                candidate.replace(receipt)
        licenses = []
        for raw_path in git(sources[core], "ls-files", "-z").split(b"\0"):
            if not raw_path:
                continue
            relative = Path(raw_path.decode())
            name = relative.name.lower()
            if not any(name == stem or name.startswith(stem + ".")
                       for stem in ("license", "copying", "copyright")):
                continue
            source = sources[core] / relative
            if not source.is_file() or source.is_symlink():
                continue
            target = output / "licenses" / core / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            licenses.append(target.relative_to(output).as_posix())
        if not licenses:
            raise ValueError(f"No license files supplied by {core}")
        records.append({"core": core, "commit": revision,
                        "repository": f"https://github.com/libretro/{PINS[core]['repository']}",
                        "library": libraries[core].name, "sha256": digest(libraries[core]),
                        "sourceArchive": archive_name, "sourceSha256": digest(archive_path),
                        "licenses": sorted(licenses)})
    manifest = {"schemaVersion": 1, "platform": platform, "architecture": architecture,
                "hashStage": "before-app-signing", "qualified": False, "cores": records}
    with tempfile.NamedTemporaryFile(mode="w", dir=output, delete=False, suffix=".json") as temporary:
        json.dump(manifest, temporary, indent=2)
        temporary.write("\n")
    Path(temporary.name).replace(output / "romm-cores.json")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="append", required=True)
    parser.add_argument("--verify-sources", action="store_true")
    parser.add_argument("--host-source", action="append")
    parser.add_argument("--library", action="append")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--platform")
    parser.add_argument("--architecture")
    args = parser.parse_args()
    sources = parse_inputs(args.source)
    if args.verify_sources:
        for core, source in sources.items():
            validate_source(core, source)
    else:
        if not args.library or not args.output or not args.platform or not args.architecture:
            parser.error("Packaging requires libraries, output, platform and architecture")
        package(sources, parse_inputs(args.library), args.output, args.platform, args.architecture)
        if args.host_source:
            stage_host_sources(args.host_source, args.output)
