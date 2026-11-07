#!/usr/bin/env python3
"""Retain failed Mac packaging inputs without accumulating successful builds."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from recover_macos_app import api, tree_digest


def cache_root():
    root = Path.home() / 'Library/Caches/pleazyng-retained-builds'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.resolve() != root or root.stat().st_uid != os.geteuid():
        raise ValueError('Unexpected Mac compilation cache ownership or redirection')
    return root


def capture(app):
    if sys.platform != 'darwin':
        raise ValueError('APFS compilation retention requires native macOS')
    if app.is_symlink() or not app.is_dir() or app.suffix != '.app':
        raise ValueError('Expected a real compiled app bundle')
    app = app.resolve()
    if not app.is_relative_to(Path(os.environ['RUNNER_TEMP']).resolve()):
        raise ValueError('Only this job temporary build output may be retained')
    run = int(os.environ['GITHUB_RUN_ID'])
    attempt = int(os.environ['GITHUB_RUN_ATTEMPT'])
    source = os.environ['GITHUB_SHA']
    inventory = api(f'actions/runs/{run}/jobs?filter=latest&per_page=100')
    jobs = inventory.get('jobs', [])
    if inventory.get('total_count', len(jobs)) != len(jobs):
        raise ValueError('Incomplete job inventory')
    matches = [j for j in jobs if j.get('name') == 'build-macos' and j.get('status') == 'in_progress'
               and j.get('head_sha') == source and j.get('run_attempt') == attempt]
    if len(matches) != 1:
        raise ValueError('Current native Mac job is missing or ambiguous')
    job = matches[0]['id']
    target = cache_root() / f'{run}-{job}-attempt{attempt}'
    if target.exists() or target.is_symlink():
        raise ValueError('Preserve the existing retained compilation')
    fingerprint = tree_digest(app)
    target.mkdir(mode=0o700)
    subprocess.run(['/bin/cp', '-cR', str(app), str(target / 'Pleazyng.app')], check=True)
    if tree_digest(target / 'Pleazyng.app') != fingerprint:
        raise ValueError('Compiled app snapshot differs from its source')
    record = {'source': source, 'run': run, 'job': job, 'attempt': attempt,
              'app': str(target / 'Pleazyng.app'), 'copy_on_write': True,
              'compilation_completed': True, 'tree_sha256': fingerprint,
              'purpose': 'Recover signing/packaging only; not a publication artifact.'}
    (target / 'retention.json').write_text(json.dumps(record, indent=2) + '\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'path={target}\n')
    print(f'Retained verified compilation for job {job}; failed packaging preserves this snapshot.')


def discard(snapshot):
    root = cache_root()
    if snapshot.is_symlink() or snapshot.parent != root or snapshot.resolve() != snapshot:
        raise ValueError('Snapshot must be an owned cache child')
    if snapshot.stat().st_uid != os.geteuid():
        raise ValueError('Snapshot owner changed')
    record = json.loads((snapshot / 'retention.json').read_text())
    expected = f'{record["run"]}-{record["job"]}-attempt{record["attempt"]}'
    if (snapshot.name != expected or record['source'] != os.environ['GITHUB_SHA']
            or str(record['run']) != os.environ['GITHUB_RUN_ID']
            or str(record['attempt']) != os.environ['GITHUB_RUN_ATTEMPT']):
        raise ValueError('Snapshot does not belong to this completed job')
    shutil.rmtree(snapshot)
    print('Removed this successful job compilation snapshot after qualified DMG upload.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['capture', 'discard'])
    parser.add_argument('path', type=Path)
    args = parser.parse_args()
    (capture if args.operation == 'capture' else discard)(args.path)
