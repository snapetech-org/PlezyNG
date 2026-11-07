#!/usr/bin/env python3
"""Make only an app-owned bundle writable before replacing code signatures."""
import argparse
import os
from pathlib import Path
import plistlib
import stat


MACHO_MAGIC = {
    bytes.fromhex(value) for value in
    ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')
}


def is_macho(path: Path) -> bool:
    with path.open('rb') as stream:
        return stream.read(4) in MACHO_MAGIC


def prepare_entitlements(source: Path, output: Path) -> None:
    class UniqueValues(dict):
        def __setitem__(self, key, value):
            if key in self and (type(self[key]) is not type(value) or self[key] != value):
                raise ValueError(f'Conflicting duplicate entitlement: {key}')
            super().__setitem__(key, value)

    values = plistlib.loads(source.read_bytes(), dict_type=UniqueValues)
    if not isinstance(values, dict):
        raise ValueError('Expected an entitlement dictionary')
    # AMFI rejects duplicate XML dictionary keys even when their values agree.
    # Canonical serialization preserves every effective entitlement unchanged.
    with output.open('xb') as stream:
        plistlib.dump(values, stream)


def prepare(app: Path) -> int:
    if app.is_symlink() or not app.is_dir() or app.suffix != '.app':
        raise ValueError('Expected a real app bundle directory')
    app = app.resolve()
    entries = [app, *app.rglob('*')]
    # Check the complete boundary before changing any permissions. Framework
    # version symlinks are normal; links outside the app are not signing inputs.
    for path in entries:
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(app):
                raise ValueError('App bundle contains an external symlink')
        elif path.stat().st_uid != os.geteuid():
            raise ValueError('App bundle contains files owned by another user')
    temporary = []
    for path in entries:
        if path.name.startswith('._'):
            # Xcode can strip framework headers while leaving their NFS
            # sidecars, so a valid AppleDouble header need not have a peer.
            if path.is_symlink() or not path.is_file():
                raise ValueError('Unrecognized AppleDouble file; preserve it for inspection')
            with path.open('rb') as stream:
                if stream.read(4) != bytes.fromhex('00051607'):
                    raise ValueError('Unrecognized AppleDouble file; preserve it for inspection')
            temporary.append(path)
        if path.name.endswith('.cstemp'):
            peer = path.with_name(path.name.removesuffix('.cstemp'))
            relative = path.relative_to(app)
            if (relative.parts[:2] not in {('Contents', 'Frameworks'), ('Contents', 'MacOS')}
                    or path.is_symlink() or not path.is_file()
                    or peer.is_symlink() or not peer.is_file()
                    or not is_macho(path) or not is_macho(peer)):
                raise ValueError('Unrecognized signing temporary file; preserve it for inspection')
            temporary.append(path)
    changed = 0
    for path in entries:
        if not path.is_symlink():
            mode = stat.S_IMODE(path.stat().st_mode)
            if not mode & stat.S_IWUSR:
                path.chmod(mode | stat.S_IWUSR)
                changed += 1
    # Interrupted codesign and NFS copies leave temporary signatures and
    # AppleDouble sidecars. Neither is application code or a bundle resource.
    # Remove only validated peers in this owned signing copy.
    for path in temporary:
        path.unlink()
    if temporary:
        print(f'Removed {len(temporary)} signing temporary files and AppleDouble sidecars.')
    return changed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--entitlements-source', type=Path)
    parser.add_argument('--entitlements-output', type=Path)
    args = parser.parse_args()
    if bool(args.entitlements_source) != bool(args.entitlements_output):
        parser.error('Provide both entitlement paths')
    if args.entitlements_source:
        prepare_entitlements(args.entitlements_source, args.entitlements_output)
    print(f'Prepared {prepare(args.app)} read-only app entries for signing.')
