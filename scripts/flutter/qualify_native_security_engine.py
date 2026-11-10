#!/usr/bin/env python3
"""Exercise a verified patched engine in a fresh, pinned Windows Flutter SDK."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile

from build_security_engine import VERSION, FRAMEWORK, ENGINE, DART, SKIA, PATCHES, DEPOT
from qualify_security_engine_run import qualify

ROOT = Path(__file__).resolve().parents[2]


def run(*args, cwd=None, env=None):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd, env=env, text=True, encoding='utf-8', errors='replace')


def native_qualify(run_id, arch, workspace, output):
    if sys.platform != 'win32':
        raise ValueError('Native Windows qualification requires Windows')
    host = os.environ.get('PROCESSOR_ARCHITEW6432', os.environ.get('PROCESSOR_ARCHITECTURE', '')).lower()
    if {'amd64': 'x64', 'arm64': 'arm64'}.get(host) != arch:
        raise ValueError('The qualification runner must match the engine architecture')
    workspace = Path(workspace).resolve()
    workspace.mkdir(parents=True, exist_ok=False)
    static = qualify(run_id, workspace / 'artifacts')
    archive = next(item for item in static['archives'] if item['file'].endswith(f'-{arch}.zip'))
    sdk = workspace / 'flutter'
    run('git', 'init', sdk)
    run('git', '-C', sdk, 'config', 'core.longpaths', 'true')
    run('git', '-C', sdk, 'remote', 'add', 'origin', 'https://github.com/flutter/flutter.git')
    run('git', '-C', sdk, 'fetch', '--depth=1', 'origin', f'refs/tags/{VERSION}:refs/tags/{VERSION}')
    run('git', '-C', sdk, 'checkout', '--detach', f'refs/tags/{VERSION}')
    if run('git', '-C', sdk, 'rev-parse', 'HEAD').strip() != FRAMEWORK:
        raise ValueError('The fixed SDK tag no longer matches its immutable source pin')
    flutter = sdk / 'bin/flutter.bat'
    run(flutter, 'precache', '--windows')
    version = json.loads(run(flutter, '--version', '--machine'))
    if (version.get('frameworkRevision') != FRAMEWORK or version.get('frameworkVersion') != VERSION
            or (sdk / 'bin/cache/engine.stamp').read_text().strip() != ENGINE):
        raise ValueError('The candidate SDK does not match its framework/engine ABI')
    # Both archives have already passed the canonical Windows-path, CRC,
    # provenance, size and PE-machine checks. No candidate executable has run yet.
    with zipfile.ZipFile(workspace / 'artifacts' / archive['file']) as package:
        package.extractall(sdk / 'bin/cache/artifacts/engine')
    environment = dict(os.environ)
    environment['PATH'] = str(sdk / 'bin') + os.pathsep + environment['PATH']
    environment['FLUTTER_WINDOWS_DCOMP'] = '1'
    probe = run(sys.executable, ROOT / 'scripts/checks/qualify_workspace_views.py',
                'windows', '--arch', arch, cwd=ROOT, env=environment)
    # Hosted Windows consoles may use CP1252 even though Flutter prints UTF-8.
    # Escape only diagnostic non-ASCII so a successful native probe can report.
    print(probe.encode('ascii', 'backslashreplace').decode('ascii'))
    if 'WORKSPACE_NATIVE_VIEWS_OK' not in probe:
        raise ValueError('The patched engine did not finish its native multiview lifecycle probe')
    receipt = {
        'schemaVersion': 1, 'architecture': arch, 'producerRunId': run_id,
        'producerCommit': static['producerCommit'], 'qualificationRunId': int(os.environ['GITHUB_RUN_ID']),
        'frameworkVersion': VERSION, 'frameworkRevision': FRAMEWORK, 'engineRevision': ENGINE,
        'dartRevision': DART, 'skiaRevision': SKIA, 'patchRevision': PATCHES, 'depotRevision': DEPOT,
        'archiveSha256': archive['sha256'], 'nativeMultiviewProbe': 'passed', 'directCompositionEnabled': True,
        'deviceImageQualityQualified': False,
    }
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--arch', choices=['x64', 'arm64'], required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    native_qualify(args.run_id, args.arch, args.workspace, args.output)
