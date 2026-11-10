#!/usr/bin/env python3
"""Qualify artifacts from the exact trusted main-branch engine producer.

This read-only lane does not publish binaries or change release pins. It accepts
only successful canonical runs whose producer sources still match this checkout.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import zipfile

from verify_security_engine_artifacts import verify, VERSION

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = 'snapetech-org/pleazyng'
REPOSITORY_ID = 1433487464
OWNER_ID = 342151964
WORKFLOW = '.github/workflows/flutter-security-engine.yml'
PRODUCER_FILES = (WORKFLOW, 'scripts/flutter/build_security_engine.py')
NAMES = {f'flutter-security-engine-{arch}' for arch in ('x64', 'arm64')}


def api(path):
    raw = subprocess.check_output(['gh', 'api', f'repos/{REPOSITORY}/{path}'], timeout=60)
    if len(raw) > 4 * 1024**2:
        raise ValueError('Oversized GitHub metadata')
    return json.loads(raw)


def validate_run(run, run_id):
    repository = run.get('head_repository') or {}
    if (run.get('id') != run_id or run.get('status') != 'completed' or run.get('conclusion') != 'success'
            or run.get('event') not in {'push', 'workflow_dispatch'} or run.get('head_branch') != 'main'
            or run.get('path') != WORKFLOW or repository.get('id') != REPOSITORY_ID
            or repository.get('full_name') != REPOSITORY
            or (repository.get('owner') or {}).get('id') != OWNER_ID
            or not isinstance(run.get('head_sha'), str)
            or not re.fullmatch(r'[0-9a-f]{40}', run['head_sha'])):
        raise ValueError('A successful canonical main engine producer is required')
    return run['head_sha']


def validate_jobs(data, run_id):
    jobs = data.get('jobs')
    if not isinstance(jobs, list) or data.get('total_count') != 2 or len(jobs) != 2:
        raise ValueError('Expected exactly two producer architecture jobs')
    if {job.get('name') for job in jobs} != {'windows (x64)', 'windows (arm64)'} or any(
            job.get('run_id') != run_id or job.get('status') != 'completed' or job.get('conclusion') != 'success'
            for job in jobs):
        raise ValueError('Both producer architecture jobs must pass')


def select_artifacts(data, run_id, sha):
    artifacts = data.get('artifacts')
    if not isinstance(artifacts, list) or data.get('total_count') != len(artifacts) or len(artifacts) > 100:
        raise ValueError('Incomplete producer artifact inventory')
    selected = []
    for name in sorted(NAMES):
        matches = [item for item in artifacts if item.get('name') == name]
        if len(matches) != 1:
            raise ValueError('Each architecture needs one unambiguous artifact')
        item = matches[0]
        producer = item.get('workflow_run') or {}
        if (item.get('expired') is not False or type(item.get('id')) is not int or item['id'] <= 0
                or type(item.get('size_in_bytes')) is not int or not 0 < item['size_in_bytes'] <= 4 * 1024**3
                or producer.get('id') != run_id or producer.get('head_sha') != sha
                or not isinstance(item.get('digest'), str)
                or not re.fullmatch(r'sha256:[0-9a-f]{64}', item['digest'])):
            raise ValueError('Artifact identity, size, lifetime or producer mismatch')
        selected.append(item)
    if selected[0]['id'] == selected[1]['id']:
        raise ValueError('Architecture artifact identities must be distinct')
    return selected


def source_blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()


def download_artifact(artifact, output):
    name = artifact['name']
    if name not in NAMES or type(artifact.get('id')) is not int or artifact['id'] <= 0:
        raise ValueError('Invalid artifact identity')
    outer = output / (name + '.artifact.zip')
    with outer.open('xb') as destination:
        subprocess.run(['gh', 'api', f'repos/{REPOSITORY}/actions/artifacts/{artifact["id"]}/zip'],
                       stdout=destination, check=True, timeout=1200)
    if not 0 < outer.stat().st_size <= 4 * 1024**3:
        raise ValueError('Downloaded artifact exceeds limit')
    digest = hashlib.sha256()
    with outer.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if 'sha256:' + digest.hexdigest() != artifact['digest']:
        raise ValueError('Downloaded artifact digest mismatch')
    arch = name.removeprefix('flutter-security-engine-')
    archive_name = f'flutter-pleazyng-windows-{VERSION}-{arch}.zip'
    expected = {archive_name, archive_name + '.sha256'}
    with zipfile.ZipFile(outer) as package:
        entries = package.infolist()
        if len(entries) != 2 or {item.filename for item in entries} != expected:
            raise ValueError('Unexpected artifact envelope paths')
        for item in entries:
            limit = 256 if item.filename.endswith('.sha256') else 4 * 1024**3
            if (item.is_dir() or not 0 < item.file_size <= limit
                    or stat.S_IFMT(item.external_attr >> 16) not in (0, stat.S_IFREG)
                    or item.flag_bits & 1
                    or item.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
                raise ValueError('Unsafe artifact envelope member')
        directory = output / name
        directory.mkdir()
        for item in entries:
            count = 0
            with package.open(item) as source, (directory / item.filename).open('xb') as destination:
                for chunk in iter(lambda: source.read(1024 * 1024), b''):
                    count += len(chunk)
                    if count > item.file_size:
                        raise ValueError('Artifact envelope exceeded its declared size')
                    destination.write(chunk)
            if count != item.file_size:
                raise ValueError('Truncated artifact envelope')
    outer.unlink()


def qualify(run_id, output):
    if type(run_id) is not int or run_id <= 0:
        raise ValueError('Invalid producer run ID')
    sha = validate_run(api(f'actions/runs/{run_id}'), run_id)
    validate_jobs(api(f'actions/runs/{run_id}/jobs?filter=latest&per_page=100'), run_id)
    sources = {}
    for path in PRODUCER_FILES:
        observed = api(f'contents/{path}?ref={sha}')
        expected = source_blob((ROOT / path).read_bytes())
        if observed.get('type') != 'file' or observed.get('sha') != expected:
            raise ValueError('Producer sources changed; rebuild or review the source pins')
        sources[path] = expected
    artifacts = select_artifacts(api(f'actions/runs/{run_id}/artifacts?per_page=100'), run_id, sha)
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    for artifact in artifacts:
        # Download the inspected immutable ID and verify GitHub's envelope
        # digest. Name-based lookup could race a producer rerun/replacement.
        download_artifact(artifact, output)
    assets = verify(output)
    receipt = {
        'schemaVersion': 1, 'producerRunId': run_id, 'producerCommit': sha,
        'producerRepositoryId': REPOSITORY_ID, 'producerOwnerId': OWNER_ID,
        'producerSources': sources,
        'producerArtifacts': [{'id': item['id'], 'name': item['name'], 'digest': item['digest']} for item in artifacts],
        'archives': [{'file': str(path.relative_to(output)),
                      'sha256': path.with_name(path.name + '.sha256').read_text().split()[0]}
                     for path in assets if path.suffix == '.zip'],
        'staticQualification': 'passed: pair, pinned sources, SHA-256, CRC, Windows paths, size bounds and PE architecture',
        'nativeRuntimeQualification': 'required separately', 'releasePinsChanged': False,
    }
    receipt_path = output / 'qualification.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print('ENGINE_QUALIFICATION_RECEIPT ' + str(receipt_path))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    qualify(args.run_id, args.output)


if __name__ == '__main__':
    main()
