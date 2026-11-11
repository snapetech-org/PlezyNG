#!/usr/bin/env python3
"""Verify reusable CI from the same captured main build before freezing a release."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request

from pubspec_version import parse_pubspec_version
from verify_release_ci import API_BASE, GateError, _manifest_gate, _pages, _required_environment

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'snapetech-org/pleazyng'
REPOSITORY_ID = 1433487464
PREFIX = 'Release CI / '


class QualificationNotFound(GateError):
    """A narrowly retryable read-after-create GitHub response."""


def api(path, token, *, payload=None, missing=False):
    request = urllib.request.Request(f'{API_BASE}/repos/{REPOSITORY}/{path}',
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json', 'X-GitHub-Api-Version': '2022-11-28',
                 'User-Agent': 'Pleazyng-release-qualification'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read(16 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
        if missing and status == 404:
            return None
        failure = QualificationNotFound if status == 404 else GateError
        raise failure(f'Qualification API request {path} failed (HTTP {status}).') from None
    except (urllib.error.URLError, OSError, TimeoutError) as error:
        raise GateError(f'Qualification API request failed ({type(error).__name__}).') from None
    if len(data) > 16 * 1024 * 1024:
        raise GateError('Qualification API response exceeded its safety limit.')
    try:
        result = json.loads(data)
    except (ValueError, UnicodeError):
        raise GateError('Qualification API returned invalid JSON.') from None
    if not isinstance(result, dict):
        raise GateError('Qualification API returned an unexpected response.')
    return result


def resolve_ref(tag, token, *, missing=False):
    reference = api(f'git/ref/tags/{tag}', token, missing=missing)
    if reference is None:
        return None
    target = reference.get('object', {})
    if target.get('type') == 'tag':
        target = api(f"git/tags/{target.get('sha')}", token).get('object', {})
    if target.get('type') != 'commit' or re.fullmatch(r'[0-9a-f]{40}', str(target.get('sha'))) is None:
        raise GateError('Release reference must resolve directly to a commit.')
    return target['sha']


def verify_candidate(token, repository, sha, tag, candidate, *, root=ROOT):
    if repository != REPOSITORY or re.fullmatch(r'[0-9a-f]{40}', sha) is None:
        raise GateError('Qualification requires the canonical repository and exact source SHA.')
    version, _ = parse_pubspec_version((root / 'pubspec.yaml').read_text())
    if tag != 'v' + version.split('+')[0] or candidate != f'{tag}-candidate.{sha}':
        raise GateError('Candidate must bind the checked-out version and exact source SHA.')
    if resolve_ref(candidate, token) != sha:
        raise GateError('Candidate reference does not match the captured source.')
    ancestry = api(f'compare/{sha}...main', token)
    if ancestry.get('status') not in ('ahead', 'identical') or ancestry.get('base_commit', {}).get('sha') != sha:
        raise GateError('Captured source is not an ancestor of canonical main.')
    stable = resolve_ref(tag, token, missing=True)
    if stable is not None and stable != sha:
        raise GateError('Existing stable release tag is immutable and points to different source.')


def verify_jobs(run, jobs, sha, run_id, attempt, required):
    repository = run.get('repository') or {}
    head_repository = run.get('head_repository') or {}
    if (not isinstance(required, list) or not required
            or any(not isinstance(name, str) or not name for name in required)
            or len(required) != len(set(required))):
        raise GateError('Embedded CI requires a nonempty unique job contract.')
    if (run.get('id') != run_id or run.get('run_attempt') != attempt
            or run.get('event') != 'workflow_dispatch' or run.get('head_branch') != 'main'
            or run.get('head_sha') != sha or not isinstance(run.get('path'), str)
            or run['path'].split('@')[0] != '.github/workflows/build.yml'
            or not isinstance(repository, dict) or repository.get('id') != REPOSITORY_ID
            or not isinstance(head_repository, dict) or head_repository.get('id') != REPOSITORY_ID):
        raise GateError('Embedded CI is not from the captured canonical main build and current attempt.')
    records = []
    for name in required:
        matches = [job for job in jobs if job.get('name') == PREFIX + name]
        if (len(matches) != 1 or matches[0].get('status') != 'completed' or matches[0].get('conclusion') != 'success'
                or not isinstance(matches[0].get('id'), int)):
            raise GateError(f'Required embedded CI job did not pass uniquely: {name}')
        job = matches[0]
        records.append({'id': job['id'], 'name': job['name'], 'attempt': job.get('run_attempt'),
                        'status': job['status'], 'conclusion': job['conclusion']})
    for job in jobs:
        if str(job.get('name', '')).startswith(PREFIX) and (job.get('status') != 'completed'
                or job.get('conclusion') not in ('success', 'skipped')):
            raise GateError('A reusable CI job failed or remains unfinished.')
    return {'mode': 'embedded', 'source_sha': sha, 'run_id': run_id, 'attempt': attempt,
            'workflow': '.github/workflows/build.yml', 'ci_workflow': '.github/workflows/ci.yml', 'jobs': records}


def verify_created_tag(token, tag, sha):
    # GitHub may accept the ref before either its ref or annotated object is
    # visible to a subsequent read. Retry only those 404s, never the POSTs.
    for attempt in range(5):
        try:
            visible = resolve_ref(tag, token, missing=True)
        except QualificationNotFound:
            visible = None
        if visible is not None:
            if visible != sha:
                raise GateError('Stable tag did not resolve to the qualified source.')
            return
        if attempt < 4:
            time.sleep(2)
    raise GateError('New stable tag was not visible after bounded verification; preserve it and retry qualification.')


def create_stable_tag(token, tag, sha):
    existing = resolve_ref(tag, token, missing=True)
    if existing is not None:
        if existing != sha:
            raise GateError('Existing stable tag cannot be moved.')
        return
    annotated = api('git/tags', token, payload={'tag': tag, 'message': f'Pleazyng {tag} qualified source',
                                               'object': sha, 'type': 'commit'})
    try:
        api('git/refs', token, payload={'ref': f'refs/tags/{tag}', 'sha': annotated['sha']})
    except GateError as creation_error:
        try:
            verify_created_tag(token, tag, sha)
        except GateError as verification_error:
            raise GateError(f'{creation_error} Subsequent tag verification failed: {verification_error}') from None
        return
    verify_created_tag(token, tag, sha)


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--candidate-only', action='store_true')
    mode.add_argument('--create-tag', action='store_true')
    parser.add_argument('--proof', type=Path)
    args = parser.parse_args()
    token, repository, sha, _ = _required_environment()
    tag, candidate = os.environ.get('RELEASE_TAG', ''), os.environ.get('CANDIDATE_REF', '')
    if os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise GateError('Captured release qualification requires the authorized main workflow.')
    verify_candidate(token, repository, sha, tag, candidate)
    if args.candidate_only:
        return 0
    run_id, attempt = int(os.environ['GITHUB_RUN_ID']), int(os.environ['GITHUB_RUN_ATTEMPT'])
    run = api(f'actions/runs/{run_id}', token)
    jobs = _pages(f'{API_BASE}/repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs', token, 'jobs')
    proof = verify_jobs(run, jobs, sha, run_id, attempt, _manifest_gate()['requiredJobs'])
    if args.create_tag:
        create_stable_tag(token, tag, sha)
    elif resolve_ref(tag, token) != sha:
        raise GateError('Stable tag does not match the qualified source.')
    proof.update({'tag': tag, 'candidate_ref': candidate})
    if args.proof:
        args.proof.write_text(json.dumps(proof, indent=2) + '\n')
    print(f'Embedded CI verified {len(proof["jobs"])} required jobs for {sha}, run {run_id}, attempt {attempt}.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (GateError, ValueError, KeyError) as error:
        print(f'Embedded release qualification failed: {error}', file=sys.stderr)
        raise SystemExit(1)
