#!/usr/bin/env python3
"""Collect exact-version Debian runtime notices without changing compiled code."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def collect(bundle: Path, packages: str) -> dict:
    versions = dict(line.split('\t', 1) for line in packages.splitlines() if '\t' in line)
    entries = {}
    destination = bundle / 'notices/system'
    destination.mkdir(parents=True, exist_ok=True)
    libraries = subprocess.check_output(['ldconfig', '-p'], text=True)
    for library in sorted((bundle / 'lib/runtime').iterdir()):
        matches = [line.split(' => ', 1)[1] for line in libraries.splitlines()
                   if line.strip().startswith(library.name + ' ') and ' => ' in line]
        if not matches:
            raise ValueError('cannot identify runtime notice owner: ' + library.name)
        source = Path(matches[0]).resolve()
        candidates = [str(source), str(source).replace('/usr/lib/', '/lib/', 1)]
        owner = ''
        for candidate in candidates:
            result = subprocess.run(['dpkg-query', '-S', candidate], capture_output=True, text=True)
            if result.returncode == 0:
                owner = result.stdout.split(': ', 1)[0].split(', ', 1)[0]
                break
        package = owner.split(':', 1)[0]
        if not package:
            raise ValueError('missing runtime package owner: ' + library.name)
        version = subprocess.check_output(['dpkg-query', '-W', '-f=${Version}', owner], text=True)
        if versions.get(package) != version:
            raise ValueError('notice SDK version differs from compiled runtime: ' + package)
        notice = Path('/usr/share/doc') / package / 'copyright'
        if not notice.is_file():
            raise ValueError('missing runtime copyright: ' + package)
        target = destination / (package + '-copyright')
        target.unlink(missing_ok=True)
        shutil.copyfile(notice, target)
        entries[library.name] = {'package': package, 'version': version,
                                 'copyright_sha256': digest(target)}
    return {'copyright_sdk_architecture': platform.machine(), 'libraries': entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    args = parser.parse_args()
    report_path = args.bundle / 'provenance.json'
    report = json.loads(report_path.read_text())
    for name, checksum in report['files'].items():
        if digest(args.bundle / name) != checksum:
            raise ValueError('input runtime file hash mismatch: ' + name)
    notices = collect(args.bundle, report['system_packages'])
    report['runtime_notices'] = notices
    report['notice_assembler_sha256'] = digest(Path(__file__))
    report['files'] = {str(path.relative_to(args.bundle)): digest(path)
                       for path in sorted(args.bundle.rglob('*'))
                       if path.is_file() and path != report_path}
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(notices, indent=2))


if __name__ == '__main__':
    main()
