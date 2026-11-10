#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Stage an attested core Linux bundle for native QA without compiling it again."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from verify_release_attestation import REPOSITORY, REPOSITORY_ID, require_repository_identity

WORKFLOW = '.github/workflows/build.yml'
SIGNER = REPOSITORY + '/' + WORKFLOW


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def api(path):
    return json.loads(run(['gh', 'api', path], capture_output=True, text=True).stdout)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate_producer(metadata, jobs, artifacts, source_sha):
    if (metadata.get('repository', {}).get('id') != REPOSITORY_ID
            or metadata.get('head_sha') != source_sha or metadata.get('path') != WORKFLOW
            or metadata.get('event') not in ('workflow_dispatch', 'push', 'release')):
        raise ValueError('Core producer does not match the trusted repository, workflow and exact source')
    linux = [job for job in jobs if job.get('name', '').endswith('Build Linux (x64)')]
    if len(linux) != 1 or linux[0].get('status') != 'completed' or linux[0].get('conclusion') != 'success':
        raise ValueError('The core Linux x64 job has not completed successfully')
    bundles = [item for item in artifacts if item.get('name') == 'linux-x64' and not item.get('expired')]
    if len(bundles) != 1:
        raise ValueError('Expected exactly one retained core linux-x64 artifact')
    return bundles[0]


def verify_run_binding(results, source_sha, producer_run_id):
    # Use certificate claims, not workflow-controlled predicate metadata.
    expected = f'https://github.com/{REPOSITORY}/actions/runs/{producer_run_id}'
    for result in results:
        certificate = result.get('verificationResult', {}).get('signature', {}).get('certificate', {})
        invocation = certificate.get('runInvocationURI', '')
        if (certificate.get('sourceRepositoryIdentifier') == str(REPOSITORY_ID)
                and certificate.get('sourceRepositoryDigest') == source_sha
                and (invocation == expected or re.fullmatch(re.escape(expected) + r'/attempts/[1-9][0-9]*', invocation))):
            return
    raise ValueError('Verified certificate does not bind this artifact to the approved source and producer run')


def inspect_bundle(path):
    required = {'pleazyng', 'pleazyng.sh', 'pleazyng.png', 'lib/libflutter_linux_gtk.so',
                'lib/libapp.so', 'data/icudtl.dat'}
    with tarfile.open(path, 'r:gz') as archive:
        names = {}
        for member in archive.getmembers():
            name = member.name
            while name.startswith('./'):
                name = name[2:]
            if PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts:
                raise ValueError('Unsafe path in the attested Linux bundle')
            names[name] = member
        if not required.issubset(names):
            raise ValueError('Core artifact is not the ordinary complete flat application bundle')
        binary = names['pleazyng']
        if not binary.isfile() or not binary.mode & 0o111:
            raise ValueError('App executable must be a regular ELF file')
        with archive.extractfile(binary) as stream:
            header = stream.read(20)
        if len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[18:20], 'little') != 62:
            raise ValueError('Core artifact must contain the Linux x86_64 executable')


def stage(source, source_sha, producer_run_id, bundle, output):
    if not re.fullmatch('[0-9a-f]{40}', source_sha) or producer_run_id < 1:
        raise ValueError('Full immutable source SHA and core producer run ID are required')
    source, bundle, output = source.resolve(), bundle.resolve(), output.resolve()
    actual = run(['git', '-C', source, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    if actual != source_sha:
        raise ValueError('Checked-out source does not match the approved core source')
    require_repository_identity(REPOSITORY)
    comparison = api(f'repos/{REPOSITORY}/compare/{source_sha}...main')
    if comparison['status'] not in ('ahead', 'identical'):
        raise ValueError('Approved core source is not on canonical main')
    producer = api(f'repos/{REPOSITORY}/actions/runs/{producer_run_id}')
    jobs = api(f'repos/{REPOSITORY}/actions/runs/{producer_run_id}/jobs?per_page=100')['jobs']
    artifacts = api(f'repos/{REPOSITORY}/actions/runs/{producer_run_id}/artifacts?per_page=100')['artifacts']
    artifact = validate_producer(producer, jobs, artifacts, source_sha)
    inspect_bundle(bundle)
    verified = run(['gh', 'attestation', 'verify', bundle, '--repo', REPOSITORY,
                    '--signer-workflow', SIGNER, '--source-digest', source_sha, '--format', 'json'],
                   capture_output=True, text=True)
    verify_run_binding(json.loads(verified.stdout), source_sha, producer_run_id)
    pubspec = run(['git', '-C', source, 'show', source_sha + ':pubspec.yaml'], capture_output=True, text=True).stdout
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$', pubspec, re.M)
    if version is None:
        raise ValueError('Core source has no stable application version/build')
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(bundle, output / 'pleazyng-linux-x64.tar.gz')
    run(['git', '-C', source, 'archive', '--format=tar.gz', '--prefix=pleazyng-source/',
         '--output=' + str(output / 'pleazyng-source.tar.gz'), source_sha])
    verification = output / 'attestation-verification.json'
    verification.write_text(verified.stdout)
    assets = {name: digest(output / name) for name in ('pleazyng-linux-x64.tar.gz', 'pleazyng-source.tar.gz')}
    tooling = run(['git', '-C', HERE, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    build = {'source_sha': source_sha, 'version': version.group(1), 'tooling_sha': tooling, 'assets': assets,
             'provenance': {'kind': 'attested-core-linux-artifact', 'repository': REPOSITORY,
                            'producer_run_id': producer_run_id, 'producer_run_url': producer['html_url'],
                            'artifact_id': artifact['id'], 'artifact_name': artifact['name'],
                            'signer_workflow': SIGNER, 'verified_source_sha': source_sha,
                            'verification_sha256': digest(verification)}}
    (output / 'build.json').write_text(json.dumps(build, indent=2) + '\n')
    (output / 'SHA256SUMS.txt').write_text(''.join(f'{sha}  {name}\n' for name, sha in assets.items()))
    print('Staged verified core Linux bytes and matching source; no application build performed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--producer-run-id', type=int, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    stage(args.source, args.source_sha, args.producer_run_id, args.bundle, args.output)
