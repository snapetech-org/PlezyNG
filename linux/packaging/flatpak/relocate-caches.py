#!/usr/bin/env python3
"""Relocate GTK module caches into an installed bundle's runtime prefix."""

import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("bundle", type=Path)
parser.add_argument("--runtime-prefix", type=Path,
                    help="installed path when bundle is inside a package staging root")
args = parser.parse_args()
bundle = args.bundle
runtime_prefix = args.runtime_prefix or bundle
for cache, modules in (
    (bundle / "lib/gdk-pixbuf-2.0/2.10.0/loaders.cache", "loaders"),
    (bundle / "lib/gtk-3.0/3.0.0/immodules.cache", "immodules"),
):
    if not cache.exists():
        continue

    def relocate(match):
        module = cache.parent / modules / Path(match.group(1)).name
        if not module.is_file():
            raise FileNotFoundError(f"Cached GTK module is missing: {module}")
        return f'"{runtime_prefix / module.relative_to(bundle)}"'

    cache.write_text(re.sub(r'^"([^"]+\.so)"', relocate, cache.read_text(), flags=re.MULTILINE))
