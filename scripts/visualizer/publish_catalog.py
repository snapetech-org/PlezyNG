#!/usr/bin/env python3
"""Prepare, wrap and publish the application-owned keyless visualizer catalog."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
DOMAIN = b'MilkRust.catalog.v1\n'
CATALOG = 'content/visualizer-catalog.json'
REPOSITORY = 'snapetech-org/pleazyng'


def prepare(directory):
    source = json.loads((ROOT / 'content/visualizer-catalog-source.json').read_text())
    if source.get('schemaVersion') != 1 or not isinstance(source.get('entries'), list) or not isinstance(source.get('revoked'), list):
        raise ValueError('Invalid reviewed catalog source')
    sequence = int(os.environ['GITHUB_RUN_ID'])
    if not 1 <= sequence <= 9007199254740991:
        raise ValueError('Invalid release sequence')
    now = datetime.now(timezone.utc).replace(microsecond=0)
    source.update(sequence=sequence, issuedAt=now.isoformat().replace('+00:00', 'Z'),
                  expiresAt=(now + timedelta(days=14)).isoformat().replace('+00:00', 'Z'))
    payload = json.dumps(source, ensure_ascii=False, separators=(',', ':')).encode()
    if len(payload) > 1024 * 1024:
        raise ValueError('Catalog exceeds its payload limit')
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'payload.json').write_bytes(payload)
    (directory / 'message.bin').write_bytes(DOMAIN + payload)


def wrap(directory):
    payload = (directory / 'payload.json').read_bytes()
    if (directory / 'message.bin').read_bytes() != DOMAIN + payload:
        raise ValueError('Signing input changed')
    bundle = json.loads((directory / 'bundle.json').read_text())
    if bundle.get('mediaType') != 'application/vnd.dev.sigstore.bundle.v0.3+json':
        raise ValueError('Publisher requires a Sigstore v0.3 bundle')
    envelope = {'schemaVersion': 2, 'payload': base64.b64encode(payload).decode(), 'sigstoreBundle': bundle}
    (directory / 'visualizer-catalog.json').write_text(json.dumps(envelope, separators=(',', ':')) + '\n')


def publish(directory):
    if os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or os.environ.get('GITHUB_REF') != 'refs/heads/main':
        raise ValueError('Only the canonical main workflow can publish')
    content = (directory / 'visualizer-catalog.json').read_bytes()
    if len(content) > 2 * 1024 * 1024:
        raise ValueError('Catalog exceeds its envelope limit')
    incoming = json.loads(base64.b64decode(json.loads(content)['payload']))['sequence']
    endpoint = f'https://api.github.com/repos/{REPOSITORY}/contents/{CATALOG}'
    headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'Pleazyng-catalog-publisher'}
    def request(method, data=None):
        req = urllib.request.Request(endpoint, headers=headers, method=method,
                                     data=None if data is None else json.dumps(data).encode())
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
            if len(raw) > 4 * 1024 * 1024:
                raise ValueError('GitHub response exceeds its limit')
            return json.loads(raw)
    # Content-SHA compare-and-swap preserves concurrent main changes. Retry
    # only a concurrent edit to this one generated file; never force-push.
    for attempt in range(3):
        previous = None
        try:
            previous = request('GET')
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise RuntimeError(f'Catalog lookup failed: HTTP {error.code}') from None
        if previous:
            old = json.loads(base64.b64decode(previous['content']))
            old_sequence = json.loads(base64.b64decode(old['payload']))['sequence']
            if old_sequence >= incoming:
                print('A newer catalog is already published; preserving it')
                return
        update = {'message': 'Publish authenticated visualizer catalog', 'branch': 'main',
                  'content': base64.b64encode(content).decode()}
        if previous:
            update['sha'] = previous['sha']
        try:
            result = request('PUT', update)
            print('Published catalog commit ' + result['commit']['sha'])
            return
        except urllib.error.HTTPError as error:
            if error.code not in (409, 422) or attempt == 2:
                raise RuntimeError(f'Catalog publication failed: HTTP {error.code}') from None
    raise RuntimeError('Catalog compare-and-swap exhausted')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'wrap', 'publish'])
    parser.add_argument('--directory', type=Path, default=Path('build/visualizer-catalog'))
    args = parser.parse_args()
    {'prepare': prepare, 'wrap': wrap, 'publish': publish}[args.operation](args.directory)
