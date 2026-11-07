#!/usr/bin/env python3
"""Make only an app-owned bundle writable before replacing code signatures."""
import os
from pathlib import Path
import stat
import sys


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
    changed = 0
    for path in entries:
        if not path.is_symlink():
            mode = stat.S_IMODE(path.stat().st_mode)
            if not mode & stat.S_IWUSR:
                path.chmod(mode | stat.S_IWUSR)
                changed += 1
    return changed


if __name__ == '__main__':
    print(f'Prepared {prepare(Path(sys.argv[1]))} read-only app entries for signing.')
