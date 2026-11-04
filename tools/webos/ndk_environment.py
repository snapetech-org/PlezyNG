#!/usr/bin/env python3
"""Verify and safely relocate LG's pinned webOS NDK environment script."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import struct
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / "tools" / "webos" / "compatibility.json"
TARGET_SYSROOT = "sysroots/ca9v1-webosmllib32-linux-gnueabi"
HOST_SYSROOT = "sysroots/x86_64-starfishsdk-linux"
NORMALIZED_NDK_ROOT = b"${WEBOS_NDK_ROOT}"
ELF_MAGIC = b"\x7fELF"
ELF_PATH_SECTIONS = (".interp", ".gccrelocprefix")
ELF_PATH_SLOT_SIZE = 0x1000


class EnvironmentError(ValueError):
    pass


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _read_regular_file(path: Path, root: Path | None = None) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise EnvironmentError(f"expected a regular NDK file: {path}")
    resolved = path.resolve(strict=True)
    if root is not None:
        try:
            resolved.relative_to(root)
        except ValueError as exc:
            raise EnvironmentError(f"NDK file escapes the NDK root: {path}") from exc
    try:
        return resolved.read_bytes()
    except OSError as exc:
        raise EnvironmentError(f"cannot read {path}: {exc}") from exc


def _elf_sections(contents: bytes) -> dict[str, tuple[int, int, int]]:
    if not contents.startswith(ELF_MAGIC) or len(contents) < 64:
        raise EnvironmentError("pinned NDK tool has an invalid ELF header")

    elf_class = contents[4]
    endian = {1: "<", 2: ">"}.get(contents[5])
    if endian is None:
        raise EnvironmentError("pinned NDK tool uses an unsupported ELF byte order")

    if elf_class == 2:
        header_format = endian + "HHIQQQIHHHHHH"
        section_format = endian + "IIQQQQIIQQ"
        section_header_size = 64
    elif elf_class == 1:
        header_format = endian + "HHIIIIIHHHHHH"
        section_format = endian + "IIIIIIIIII"
        section_header_size = 40
    else:
        raise EnvironmentError("pinned NDK tool uses an unsupported ELF class")

    try:
        header = struct.unpack_from(header_format, contents, 16)
    except struct.error as exc:
        raise EnvironmentError("pinned NDK tool has a truncated ELF header") from exc

    section_offset = header[5]
    entry_size = header[10]
    section_count = header[11]
    names_index = header[12]
    if section_offset == 0 or entry_size < section_header_size:
        raise EnvironmentError("pinned NDK tool has no usable ELF section table")

    def read_section(index: int) -> tuple[int, ...]:
        offset = section_offset + index * entry_size
        if offset + section_header_size > len(contents):
            raise EnvironmentError("pinned NDK tool has a truncated ELF section table")
        return struct.unpack_from(section_format, contents, offset)

    try:
        section_zero = read_section(0)
        if section_count == 0:
            section_count = section_zero[5]
        if names_index == 0xFFFF:
            names_index = section_zero[6]
        if section_count == 0 or names_index >= section_count:
            raise EnvironmentError("pinned NDK tool has invalid ELF section indexes")
        if section_offset + entry_size * section_count > len(contents):
            raise EnvironmentError("pinned NDK tool has a truncated ELF section table")
        sections = [read_section(index) for index in range(section_count)]
    except struct.error as exc:
        raise EnvironmentError("pinned NDK tool has a malformed ELF section table") from exc

    names_section = sections[names_index]
    names_offset, names_size = names_section[4], names_section[5]
    if names_section[1] != 3 or names_offset + names_size > len(contents):
        raise EnvironmentError("pinned NDK tool has an invalid ELF section-name table")
    names = contents[names_offset : names_offset + names_size]

    result: dict[str, tuple[int, int, int]] = {}
    for section in sections:
        name_offset, section_type, data_offset, data_size = (
            section[0],
            section[1],
            section[4],
            section[5],
        )
        if name_offset >= len(names):
            raise EnvironmentError("pinned NDK tool has an invalid ELF section name")
        name_end = names.find(b"\0", name_offset)
        if name_end < 0:
            raise EnvironmentError("pinned NDK tool has an unterminated ELF section name")
        try:
            name = names[name_offset:name_end].decode("ascii")
        except UnicodeDecodeError as exc:
            raise EnvironmentError("pinned NDK tool has a non-ASCII ELF section name") from exc

        if section_type != 8 and data_offset + data_size > len(contents):
            raise EnvironmentError("pinned NDK tool has an out-of-bounds ELF section")
        if name in ELF_PATH_SECTIONS:
            if name in result:
                raise EnvironmentError(f"pinned NDK tool has duplicate {name} sections")
            if section_type != 1:
                raise EnvironmentError(f"pinned NDK tool has a non-data {name} section")
            result[name] = (data_offset, data_size, section_type)
    return result


def _normalize_elf_root(contents: bytes, root_bytes: bytes) -> bytes:
    sections = _elf_sections(contents)
    normalized = bytearray(contents)
    normalized_occurrences = 0

    for name in ELF_PATH_SECTIONS:
        section = sections.get(name)
        if section is None:
            continue
        section_offset, section_size, _ = section
        if section_size == 0 or section_size % ELF_PATH_SLOT_SIZE != 0:
            raise EnvironmentError(f"pinned NDK {name} section is not fixed-slot aligned")

        section_end = section_offset + section_size
        for slot_offset in range(section_offset, section_end, ELF_PATH_SLOT_SIZE):
            slot = contents[slot_offset : slot_offset + ELF_PATH_SLOT_SIZE]
            if root_bytes not in slot:
                continue

            terminator = slot.find(b"\0")
            if terminator < 0 or any(slot[terminator + 1 :]):
                raise EnvironmentError(f"pinned NDK {name} path slot is not NUL padded")
            path = slot[:terminator]
            if path.count(root_bytes) != 1 or not path.startswith(root_bytes):
                raise EnvironmentError(f"pinned NDK {name} path does not start at its root")

            normalized_path = path.replace(root_bytes, NORMALIZED_NDK_ROOT, 1)
            if len(normalized_path) + 1 > ELF_PATH_SLOT_SIZE:
                raise EnvironmentError(f"normalized NDK {name} path exceeds its fixed slot")
            normalized[slot_offset : slot_offset + ELF_PATH_SLOT_SIZE] = (
                normalized_path
                + b"\0"
                + b"\0" * (ELF_PATH_SLOT_SIZE - len(normalized_path) - 1)
            )
            normalized_occurrences += 1

    if normalized_occurrences == 0:
        raise EnvironmentError("pinned NDK ELF does not reference its installation root")
    if contents.count(root_bytes) != normalized_occurrences:
        raise EnvironmentError(
            "pinned NDK ELF references its root outside fixed-size path sections"
        )
    return bytes(normalized)


def _hash_file(root: Path, relative: str, *, normalize_root: bool = False) -> str:
    path = root / relative
    if not path.exists():
        raise EnvironmentError(f"pinned NDK file is missing: {path}")
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise EnvironmentError(f"pinned NDK file escapes the NDK root: {path}") from exc
    if not resolved.is_file():
        raise EnvironmentError(f"pinned NDK file is not regular: {path}")
    contents = resolved.read_bytes()
    if normalize_root:
        root_bytes = str(root).encode("utf-8")
        if root_bytes not in contents:
            raise EnvironmentError(
                f"pinned NDK file does not reference its installation root: {path}"
            )
        # LG's installer writes root paths into fixed-size, zero-padded ELF
        # path slots. Normalize each complete slot so different root lengths
        # cannot change its padding or the resulting hash. Text fragments use
        # literal substitution because they have no fixed-width ELF layout.
        if contents.startswith(ELF_MAGIC):
            contents = _normalize_elf_root(contents, root_bytes)
        else:
            contents = contents.replace(root_bytes, NORMALIZED_NDK_ROOT)
    return _sha256(contents)


def _lock() -> dict[str, object]:
    try:
        return json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EnvironmentError(f"cannot read compatibility lock: {exc}") from exc


def verified_environment(root_arg: Path) -> tuple[Path, str]:
    if root_arg.is_symlink():
        raise EnvironmentError("NDK root must not be a symbolic link")
    try:
        root = root_arg.resolve(strict=True)
    except OSError as exc:
        raise EnvironmentError(f"NDK root does not exist: {exc}") from exc
    if not root.is_dir():
        raise EnvironmentError("NDK root is not a directory")
    if re.fullmatch(r"/[A-Za-z0-9_./-]+", str(root)) is None:
        raise EnvironmentError(
            "NDK root contains characters unsupported by LG's environment script"
        )

    lock = _lock()
    build = lock["engineBuild"]
    revision_file = _read_regular_file(root / "version-ca9v1-webosmllib32-linux-gnueabi", root)
    if _sha256(revision_file) != build["ndkVersionFileSha256"]:
        raise EnvironmentError("NDK version metadata does not match the pinned webOS SDK")
    if f"Metadata Revision: {build['ndkMetadataRevision']}".encode() not in revision_file:
        raise EnvironmentError("NDK metadata revision does not match the pinned webOS SDK")

    for relative in (TARGET_SYSROOT, HOST_SYSROOT):
        path = root / relative
        if path.is_symlink() or not path.is_dir():
            raise EnvironmentError(f"required NDK sysroot is missing or linked: {path}")

    tools = build["ndkTools"]
    for name, record in tools.items():
        actual = _hash_file(
            root,
            record["path"],
            normalize_root=record.get("normalizeRoot", False),
        )
        if actual != record["sha256"]:
            raise EnvironmentError(f"pinned NDK {name} tool hash changed")

    for name, path_key, hash_key in (
        ("GCC", "gccPath", "gccSha256"),
        ("GCC driver", "gccDriverPath", "gccDriverSha256"),
    ):
        actual = _hash_file(root, build[path_key], normalize_root=True)
        if actual != build[hash_key]:
            raise EnvironmentError(f"pinned NDK {name} tool hash changed")

    target_triple = "arm-webosmllib32-linux-gnueabi"
    alias_directory = root / HOST_SYSROOT / "usr/bin" / target_triple
    for name in ("ar", "readelf", "nm", "strip"):
        alias = alias_directory / f"{target_triple}-{name}"
        expected_target = (root / tools[name]["path"]).resolve(strict=True)
        if not alias.is_symlink() or alias.resolve(strict=True) != expected_target:
            raise EnvironmentError(f"NDK {name} target-triple alias differs from the pinned tool")

    gcc = root / build["gccPath"]
    try:
        gcc_version = subprocess.run(
            [str(gcc), "-dumpfullversion"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise EnvironmentError(f"cannot query pinned NDK GCC: {exc}") from exc
    if gcc_version != build["gccVersion"]:
        raise EnvironmentError("NDK GCC version does not match the compatibility lock")

    script_name = build["ndkEnvironmentSetupScript"]
    script_path = root / script_name
    script = _read_regular_file(script_path, root).decode("utf-8", errors="strict")
    sysroot_assignment = re.search(
        r"^export SDKTARGETSYSROOT=(/[^\n]+)/sysroots/ca9v1-webosmllib32-linux-gnueabi$",
        script,
        flags=re.MULTILINE,
    )
    if sysroot_assignment is None:
        raise EnvironmentError("NDK environment script has no recognized target sysroot prefix")
    source_prefix = sysroot_assignment.group(1)
    if "\n" in source_prefix or not source_prefix.startswith("/"):
        raise EnvironmentError("NDK environment script has an unsafe source prefix")
    normalized_script = script.replace(source_prefix, "${WEBOS_NDK_ROOT}")
    if _sha256(normalized_script.encode("utf-8")) != build["ndkEnvironmentSetupNormalizedSha256"]:
        raise EnvironmentError("NDK environment setup script differs from the reviewed SDK script")

    expected_files = build["ndkEnvironmentSetupFiles"]
    expected_by_directory: dict[str, set[str]] = {}
    for record in expected_files:
        relative = record["path"]
        actual = _hash_file(
            root,
            relative,
            normalize_root=record.get("normalizeRoot", False),
        )
        if actual != record["sha256"]:
            raise EnvironmentError(f"pinned NDK environment fragment changed: {relative}")
        parent, _, name = relative.rpartition("/")
        expected_by_directory.setdefault(parent, set()).add(name)

    for directory in (
        "sysroots/ca9v1-webosmllib32-linux-gnueabi/environment-setup.d",
        "sysroots/x86_64-starfishsdk-linux/environment-setup.d",
    ):
        path = root / directory
        if not path.exists():
            continue
        if path.is_symlink() or not path.is_dir():
            raise EnvironmentError(f"NDK environment fragment directory is unsafe: {path}")
        actual_names = {child.name for child in path.iterdir()}
        expected_names = expected_by_directory.get(directory, set())
        if actual_names != expected_names:
            raise EnvironmentError(f"unexpected NDK environment fragments in {directory}")

    return root, normalized_script


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--verify", action="store_true")
    mode.add_argument("--emit-shell", action="store_true")
    args = parser.parse_args()
    try:
        root, script = verified_environment(args.root)
    except (OSError, UnicodeDecodeError, KeyError, TypeError, EnvironmentError) as exc:
        print(f"webOS NDK verification failed: {exc}", file=sys.stderr)
        return 1
    if args.emit_shell:
        # The only emitted code is the vendor script whose normalized bytes
        # were checked against the repository lock immediately above.
        sys.stdout.write(f"export WEBOS_NDK_ROOT={shlex.quote(str(root))}\n")
        sys.stdout.write(script)
    else:
        print("Verified pinned LG webOS NDK metadata, tools, and environment scripts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
