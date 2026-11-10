#!/usr/bin/env python3
"""Publish verified canonical locale outputs without overwriting newer inputs."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = 'snapetech-org/pleazyng'
GENERATED = re.compile(r'lib/i18n/strings(?:_[A-Za-z0-9-]+)?\.g\.dart\Z')


def api(path, body=None, method=None):
    command = ['gh', 'api', f'repos/{REPOSITORY}/{path}']
    if method:
        command += ['--method', method]
    if body is not None:
        command += ['--input', '-']
    return json.loads(subprocess.check_output(
        command, input=None if body is None else json.dumps(body).encode(), cwd=ROOT))


def main():
    if os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise RuntimeError('Canonical main workflow required')
    baseline = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    paths = subprocess.check_output(['git', 'diff', '--name-only', '-z'], cwd=ROOT).decode().split('\0')
    paths = [path for path in paths if path]
    if not paths:
        print('Canonical locale output is already current.')
        return
    if any(not GENERATED.fullmatch(path) and path != 'docs/localization/coverage.json' for path in paths):
        raise RuntimeError('Generation changed files outside the reviewed locale output set: ' + ', '.join(paths))
    entries = [{'path': path, 'mode': '100644', 'type': 'blob',
                'content': (ROOT / path).read_text()} for path in paths]
    for _ in range(4):
        current = api('commits/main')
        if current['sha'] != baseline:
            comparison = api(f'compare/{baseline}...{current["sha"]}')
            changed = comparison.get('files', [])
            protected = ('lib/i18n/', 'scripts/codegen', 'scripts/localization/',
                         'pubspec.', 'slang.', 'analysis_options.',
                         '.github/workflows/localization-reviewed.yml')
            if comparison.get('status') != 'ahead' or len(changed) >= 300 or any(
                    row['filename'].startswith(protected) for row in changed):
                raise RuntimeError('Locale generation inputs changed; regenerate from the newer main revision')
        tree = api('git/trees', {'base_tree': current['commit']['tree']['sha'], 'tree': entries})
        commit = api('git/commits', {'message': 'Regenerate verified locale outputs',
                                   'tree': tree['sha'], 'parents': [current['sha']]})
        try:
            # A concurrent update cannot be overwritten: the new commit has
            # exactly the inspected main head as parent and force is false.
            api('git/refs/heads/main', {'sha': commit['sha'], 'force': False}, method='PATCH')
            print('Published canonical locale output: ' + commit['sha'])
            return
        except subprocess.CalledProcessError:
            if api('commits/main')['sha'] == current['sha']:
                raise
    raise RuntimeError('Main kept advancing; verified output retained as a workflow artifact')


if __name__ == '__main__':
    main()
