#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Generate a checked cache from the bundle's native GTK input-method modules."""

import argparse
import ast
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def rebuild(bundle, query_tool=None, runtime_prefix=None):
    bundle = bundle.resolve()
    parent = bundle / 'lib/gtk-3.0/3.0.0'
    modules = sorted(path for path in (parent / 'immodules').glob('*.so') if path.is_file())
    if not modules:
        raise ValueError('Bundle has no GTK input-method modules')
    if query_tool is None:
        query_tool = shutil.which('gtk-query-immodules-3.0')
    if not query_tool and shutil.which('pkg-config'):
        result = subprocess.run(['pkg-config', '--variable=libdir', 'gtk+-3.0'],
                                check=True, capture_output=True, text=True)
        libdir = Path(result.stdout.strip())
        for directory in ('libgtk-3-0t64', 'libgtk-3-0', 'gtk-3.0'):
            candidate = libdir / directory / 'gtk-query-immodules-3.0'
            if candidate.is_file() and os.access(candidate, os.X_OK):
                query_tool = candidate
                break
    if not query_tool:
        raise ValueError('Native gtk-query-immodules-3.0 is required')
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = str(bundle / 'lib') + (
        ':' + env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')
    result = subprocess.run([str(query_tool), *(str(path) for path in modules)],
                            env=env, check=True, capture_output=True, text=True)
    if result.stderr.strip():
        raise ValueError('GTK query reported module errors: ' + result.stderr.strip())
    entries = re.findall(r'^("(?:[^"\\]|\\.)+\.so")[ \t]*$', result.stdout, flags=re.MULTILINE)
    found = [ast.literal_eval(entry) for entry in entries]
    if sorted(found) != sorted(str(path) for path in modules):
        raise ValueError('Generated cache does not describe every bundled input module exactly once')
    prefix = runtime_prefix or bundle
    cache = result.stdout
    for module in modules:
        cache = cache.replace('"' + str(module) + '"',
                              '"' + str(prefix / module.relative_to(bundle)) + '"')
    cache_path = parent / 'immodules.cache'
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(cache)
        temporary.chmod(cache_path.stat().st_mode & 0o777 if cache_path.exists() else 0o644)
        temporary.replace(cache_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--query-tool', type=Path)
    parser.add_argument('--runtime-prefix', type=Path)
    args = parser.parse_args()
    rebuild(args.bundle, args.query_tool, args.runtime_prefix)
