#!/usr/bin/env python3
"""Promote fixed SDK pins only after both native architecture probes passed."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess

from build_security_engine import VERSION, FRAMEWORK, ENGINE, DART, SKIA, PATCHES, DEPOT

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = 'snapetech-org/pleazyng'
OLD_VERSION = '3.47.1'
OLD_FRAMEWORK = '6655482ec06e547f90abf8ae7590466f4415978d'
OLD_ENGINE = '5d531788691ec3404cac0cee66ead4007b177363'
PATHS = ('.github/workflows/build.yml', '.github/workflows/ci.yml',
         '.github/actions/setup-flutter-git/action.yml', 'scripts/checks/check_build_workflow.py',
         'windows/tool/install-patched-engine.ps1', 'windows/tool/swap-engine.ps1')


def api(path, body=None, method=None):
    command = ['gh', 'api', f'repos/{REPOSITORY}/{path}']
    if method:
        command += ['--method', method]
    if body is not None:
        command += ['--input', '-']
    raw = subprocess.check_output(command, input=None if body is None else json.dumps(body).encode(), timeout=60)
    return json.loads(raw) if raw.strip() else None


def validate_receipts(root, run_id, producer_id, producer_sha):
    if type(run_id) is not int or run_id <= 0 or type(producer_id) is not int or producer_id <= 0:
        raise ValueError('Invalid qualification or producer run')
    if not isinstance(producer_sha, str) or not re.fullmatch(r'[0-9a-f]{40}', producer_sha):
        raise ValueError('Invalid producer commit')
    pins = {}
    for arch in ('x64', 'arm64'):
        path = Path(root) / f'security-engine-native-{arch}/native-{arch}.json'
        if not path.is_file() or path.stat().st_size > 32768:
            raise ValueError('Missing or oversized native qualification receipt')
        receipt = json.loads(path.read_text())
        expected = {'schemaVersion': 1, 'architecture': arch, 'qualificationRunId': run_id,
                    'producerRunId': producer_id, 'producerCommit': producer_sha,
                    'frameworkVersion': VERSION, 'frameworkRevision': FRAMEWORK, 'engineRevision': ENGINE,
                    'dartRevision': DART, 'skiaRevision': SKIA, 'patchRevision': PATCHES, 'depotRevision': DEPOT,
                    'nativeMultiviewProbe': 'passed', 'directCompositionEnabled': True,
                    'deviceImageQualityQualified': False}
        if not isinstance(receipt, dict) or any(type(receipt.get(k)) is not type(v) or receipt[k] != v for k, v in expected.items()):
            raise ValueError('Native architecture proof does not match this promotion')
        digest = receipt.get('archiveSha256')
        if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('Native proof lacks the verified archive digest')
        pins[arch] = digest
    return pins


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('The current SDK pin layout changed; review before promoting')
    return source.replace(old, new, 1)


def changes(sources, pins):
    # Never replace a later SDK or unrelated work with this fixed-version lane.
    version_line = f'FLUTTER_VERSION: "{OLD_VERSION}"'
    already = all(f'FLUTTER_VERSION: "{VERSION}"' in sources[p] for p in PATHS[:2])
    if already:
        installer = sources['windows/tool/install-patched-engine.ps1']
        if (ENGINE not in installer or any(digest not in installer for digest in pins.values())
                or FRAMEWORK not in sources['.github/actions/setup-flutter-git/action.yml']
                or f'FLUTTER_VERSION = \"{VERSION}\"' not in sources['scripts/checks/check_build_workflow.py']
                or ENGINE not in sources['windows/tool/swap-engine.ps1']):
            raise ValueError('Fixed SDK is already selected with different engine pins')
        return {}
    updated = {}
    for path in PATHS[:2]:
        updated[path] = replace_once(sources[path], version_line, f'FLUTTER_VERSION: "{VERSION}"')
    path = '.github/actions/setup-flutter-git/action.yml'
    value = replace_once(sources[path], f'$version = "{OLD_VERSION}"', f'$version = "{VERSION}"')
    value = replace_once(value, f'$expectedCommit = "{OLD_FRAMEWORK}"', f'$expectedCommit = "{FRAMEWORK}"')
    updated[path] = value.replace('(5d531788)', f'({ENGINE[:8]})')
    path = 'scripts/checks/check_build_workflow.py'
    value = replace_once(sources[path], f'FLUTTER_VERSION = "{OLD_VERSION}"', f'FLUTTER_VERSION = "{VERSION}"')
    updated[path] = replace_once(value, f'FLUTTER_COMMIT = "{OLD_FRAMEWORK}"', f'FLUTTER_COMMIT = "{FRAMEWORK}"')
    path = 'windows/tool/swap-engine.ps1'
    updated[path] = replace_once(sources[path], f"$ExpectedEngine = '{OLD_ENGINE}'", f"$ExpectedEngine = '{ENGINE}'")
    path = 'windows/tool/install-patched-engine.ps1'
    value = sources[path]
    if f"$ExpectedEngine = '{OLD_ENGINE}'" not in value:
        raise ValueError('The Windows installer engine pin changed')
    start, end = value.index('param('), value.index('\n)', value.index('param(')) + 2
    parameters = f'''param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant(),
    [string]$Url = '',
    [string]$Sha256 = '',
    [string]$ExpectedEngine = '{ENGINE}'
)

if ([string]::IsNullOrWhiteSpace($Url)) {{
    $Url = "https://github.com/{REPOSITORY}/releases/download/flutter-security-{VERSION}/flutter-pleazyng-windows-{VERSION}-$Architecture.zip"
    if ([string]::IsNullOrWhiteSpace($Sha256)) {{
        $Sha256 = @{{
            x64 = '{pins['x64']}'
            arm64 = '{pins['arm64']}'
        }}[$Architecture]
    }}
}} elseif ([string]::IsNullOrWhiteSpace($Sha256)) {{
    throw 'A custom engine URL requires an explicit SHA-256 digest'
}}'''
    value = value[:start] + parameters + value[end:]
    updated[path] = value.replace('Installed patched DComp engine (windows-x64, windows-x64-release).',
                                  'Installed patched DComp engine ($Architecture debug and release).')
    return updated


def dispatch_ci():
    # GITHUB_TOKEN pushes do not trigger push workflows. Explicitly dispatch
    # the repository's full hosted-first CI profile after adopting these pins.
    api('actions/workflows/ci.yml/dispatches', {'ref': 'main', 'inputs': {
        'action': 'ci', 'runner_pool': 'private', 'execution_profile': 'hybrid',
        'build_linux_packages': 'false'}}, method='POST')


def publish(root, run_id, producer_id, producer_sha):
    if os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('Only the canonical main workflow may promote SDK pins')
    pins = validate_receipts(root, run_id, producer_id, producer_sha)
    for _ in range(4):
        head = api('commits/main')
        sources = {}
        for path in PATHS:
            # Immutable commit reads preserve a coherent source snapshot.
            value = api(f'contents/{path}?ref={head["sha"]}')
            sources[path] = base64.b64decode(value['content'], validate=False).decode('utf-8')
        updated = changes(sources, pins)
        if not updated:
            print('The verified fixed SDK pins are already current.')
            dispatch_ci()
            return
        tree = api('git/trees', {'base_tree': head['commit']['tree']['sha'], 'tree': [
            {'path': path, 'mode': '100644',
             'type': 'blob', 'content': content} for path, content in updated.items()]})
        commit = api('git/commits', {'message': f'Promote qualified Windows engines and Flutter {VERSION}',
                                   'tree': tree['sha'], 'parents': [head['sha']]})
        try:
            api('git/refs/heads/main', {'sha': commit['sha'], 'force': False}, method='PATCH')
            print('PROMOTED_FIXED_SDK ' + commit['sha'])
            dispatch_ci()
            return
        except subprocess.CalledProcessError:
            if api('commits/main')['sha'] == head['sha']:
                raise
    raise RuntimeError('Main kept advancing; validated receipts remain available for retry')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipts', type=Path, required=True)
    parser.add_argument('--qualification-run-id', type=int, required=True)
    parser.add_argument('--producer-run-id', type=int, required=True)
    parser.add_argument('--producer-sha', required=True)
    args = parser.parse_args()
    publish(args.receipts, args.qualification_run_id, args.producer_run_id, args.producer_sha)
