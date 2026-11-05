#!/usr/bin/env python3
"""Package the built opt-in extension; never install it or change Steam settings."""
import argparse
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent
files = ['plugin.json', 'main.py', 'bridge.py', 'windows_pipe.py', 'dist/index.js', 'dist/index.js.map', 'README.md',
         'src/cloud.mjs', 'src/index.tsx', 'package.json', 'package-lock.json', 'rollup.config.js', 'tsconfig.json']
for name in files:
    if not (root / name).is_file():
        parser.error(f'Missing build input: {name}; run npm ci and npm run build first')
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for name in files:
        archive.write(root / name, 'plezyng-steam-cloud/' + name)
    license_file = root.parents[1] / 'LICENSE'
    if not license_file.is_file():
        raise FileNotFoundError('Repository license missing')
    archive.write(license_file, 'plezyng-steam-cloud/LICENSE')
    for name in ('api', 'ui'):
        archive.write(root / 'node_modules' / '@decky' / name / 'LICENSE',
                      f'plezyng-steam-cloud/THIRD_PARTY/decky-{name}.LICENSE')
print(f'Packaged {args.output}; installation and live qualification remain explicit.')
