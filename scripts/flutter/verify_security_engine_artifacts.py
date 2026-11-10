#!/usr/bin/env python3
"""Validate pinned dual-architecture engine archives before release.

This checks archive integrity, Windows extraction paths and PE machine identity.
It does not replace provenance authentication or a native runtime smoke test.
PE machine definitions: https://learn.microsoft.com/windows/win32/debug/pe-format
"""
import hashlib
import json
from pathlib import Path
import stat
import struct
import sys
import zipfile

from build_security_engine import VERSION, FRAMEWORK, ENGINE, DART, SKIA, PATCHES, DEPOT

MAX_ARCHIVE = 4 * 1024**3
MAX_EXPANDED = 6 * 1024**3
MAX_MEMBER = 800_000_000
MAX_PROVENANCE = 32 * 1024
PE_PREFIX = 64 * 1024
MACHINES = {'x64': 0x8664, 'arm64': 0xAA64}
RESERVED = {'con', 'prn', 'aux', 'nul', 'conin$', 'conout$',
            *(f'com{i}' for i in '123456789¹²³'), *(f'lpt{i}' for i in '123456789¹²³')}


def _path(entry, arch):
    name = entry.filename
    if not name or '\\' in name or name.startswith('/') or len(name) > 4096:
        raise ValueError(f'{arch}: unsafe archive member')
    parts = name.removesuffix('/').split('/')
    for part in parts:
        if (not part or part in {'.', '..'} or part.endswith((' ', '.'))
                or len(part.encode('utf-16-le')) > 510
                or any(ord(c) < 32 or c in '<>:"|?*' for c in part)
                or part.split('.')[0].rstrip(' ').casefold() in RESERVED):
            raise ValueError(f'{arch}: unsafe Windows archive path')
    roots = {f'windows-{arch}', f'windows-{arch}-release'}
    if parts[0] not in roots and not (
            len(parts) == 1 and parts[0] in {'LICENSE.flutter-plezy', 'pleazyng-engine-provenance.json'}):
        raise ValueError(f'{arch}: unexpected archive destination')
    mode = stat.S_IFMT(entry.external_attr >> 16)
    if mode not in (0, stat.S_IFREG, stat.S_IFDIR) or (mode != 0 and (mode == stat.S_IFDIR) != entry.is_dir()):
        raise ValueError(f'{arch}: non-regular archive member')
    if entry.flag_bits & 1 or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        raise ValueError(f'{arch}: unsupported archive encoding')
    return '/'.join(parts).casefold()


def _pe(prefix, size, arch):
    # Inspect a bounded prefix while the complete member is streamed for CRC.
    if len(prefix) < 64 or prefix[:2] != b'MZ':
        raise ValueError(f'{arch}: engine is not a PE DLL')
    offset = struct.unpack_from('<I', prefix, 0x3C)[0]
    if offset < 64 or offset + 26 > len(prefix) or prefix[offset:offset + 4] != b'PE\0\0':
        raise ValueError(f'{arch}: invalid PE header')
    machine, sections = struct.unpack_from('<HH', prefix, offset + 4)
    optional_size, flags = struct.unpack_from('<HH', prefix, offset + 20)
    if machine != MACHINES[arch]:
        raise ValueError(f'{arch}: engine architecture mismatch')
    if (not 1 <= sections <= 96 or not 112 <= optional_size <= 4096
            or flags & 0x2002 != 0x2002
            or struct.unpack_from('<H', prefix, offset + 24)[0] != 0x20B
            or offset + 24 + optional_size + sections * 40 > size):
        raise ValueError(f'{arch}: invalid PE DLL characteristics')


def verify(root):
    root = Path(root)
    assets, verified = [], []
    for arch in ('x64', 'arm64'):
        directory = root / f'flutter-security-engine-{arch}'
        archive = directory / f'flutter-pleazyng-windows-{VERSION}-{arch}.zip'
        sidecar = archive.with_name(archive.name + '.sha256')
        if not archive.is_file() or not sidecar.is_file():
            raise ValueError(f'Missing {arch} engine archive or digest')
        if archive.is_symlink() or sidecar.is_symlink() or sidecar.stat().st_size > 256:
            raise ValueError(f'{arch}: unsafe archive or digest file')
        if archive.stat().st_size > MAX_ARCHIVE:
            raise ValueError(f'{arch}: archive exceeds 4 GiB')
        hash_state = hashlib.sha256()
        with archive.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                hash_state.update(chunk)
        digest = hash_state.hexdigest()
        if sidecar.read_text(encoding='ascii').strip() != f'{digest}  {archive.name}':
            raise ValueError(f'{arch}: digest mismatch')
        with zipfile.ZipFile(archive) as built:
            entries = built.infolist()
            if len(entries) > 20000:
                raise ValueError(f'{arch}: invalid member list')
            names = set()
            for entry in entries:
                canonical = _path(entry, arch)
                if canonical in names:
                    raise ValueError(f'{arch}: colliding Windows archive paths')
                names.add(canonical)
                if entry.file_size > MAX_MEMBER:
                    raise ValueError(f'{arch}: oversized archive member')
            if sum(entry.file_size for entry in entries) > MAX_EXPANDED:
                raise ValueError(f'{arch}: expanded archive exceeds limit')
            dlls = {f'windows-{arch}{suffix}/flutter_windows.dll' for suffix in ('', '-release')}
            required = dlls | {'LICENSE.flutter-plezy', 'pleazyng-engine-provenance.json'}
            exact = {entry.filename: entry for entry in entries if not entry.is_dir()}
            if not required <= exact.keys():
                raise ValueError(f'{arch}: engine binary, provenance or license missing')
            if not 0 < exact['pleazyng-engine-provenance.json'].file_size <= MAX_PROVENANCE:
                raise ValueError(f'{arch}: oversized or empty provenance')
            if not 0 < exact['LICENSE.flutter-plezy'].file_size <= 2 * 1024**2:
                raise ValueError(f'{arch}: oversized or empty license')
            provenance = None
            for entry in entries:
                if entry.is_dir():
                    continue
                prefix, consumed = bytearray(), 0
                # Opening and consuming every file verifies its CRC as well as
                # the envelope digest, without allocating entire DLLs/PDBs.
                with built.open(entry) as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        consumed += len(chunk)
                        if consumed > entry.file_size or consumed > MAX_MEMBER:
                            raise ValueError(f'{arch}: member exceeded declared size')
                        if entry.filename in dlls and len(prefix) < PE_PREFIX:
                            prefix.extend(chunk[:PE_PREFIX - len(prefix)])
                        elif entry.filename == 'pleazyng-engine-provenance.json':
                            prefix.extend(chunk)
                if consumed != entry.file_size:
                    raise ValueError(f'{arch}: member length mismatch')
                if entry.filename in dlls:
                    _pe(prefix, consumed, arch)
                elif entry.filename == 'pleazyng-engine-provenance.json':
                    provenance = json.loads(prefix.decode('utf-8'))
            expected = {'frameworkVersion': VERSION, 'frameworkRevision': FRAMEWORK,
                        'engineRevision': ENGINE, 'dartRevision': DART, 'skiaRevision': SKIA,
                        'patchRevision': PATCHES, 'depotRevision': DEPOT,
                        'patchSource': 'https://github.com/edde746/flutter-plezy',
                        'architecture': arch, 'advisory': 'GHSA-frr6-h895-5pxp'}
            if not isinstance(provenance, dict) or any(provenance.get(key) != value for key, value in expected.items()):
                raise ValueError(f'{arch}: provenance mismatch')
        verified.append((arch, digest))
        assets.extend((archive, sidecar))
    for arch, digest in verified:
        print(f'VERIFIED_ENGINE {arch} {digest}')
    return assets


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, RuntimeError) as error:
        raise SystemExit(str(error))
