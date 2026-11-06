#!/usr/bin/env python3
"""Deploy reviewed, committed OAuth source; never print credential values.

Run on a deployment host with protected account credentials and a provider file.
Routes are deliberately separate, so upload/validation cannot take traffic early.
"""
import argparse
import json
from pathlib import Path
import subprocess
import urllib.request
import urllib.error
import uuid


def environment(path):
    values = {}
    if path:
        source = Path(path)
        if source.stat().st_mode & 0o077:
            raise RuntimeError('credential file must be private (0600)')
        for line in source.read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                key, value = line.split('=', 1)
                values[key.strip()] = value.strip().strip('\"\'')
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--account-env', required=True)
    parser.add_argument('--provider-env', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--initial', action='store_true', help='First upload only: create SQLite object classes')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    if actual != args.source_sha:
        raise RuntimeError('source SHA does not match checkout')
    source_path = 'server/cloudflare-oauth/worker.mjs'
    source = subprocess.check_output(['git', 'show', f'{actual}:{source_path}'], cwd=root)
    credentials = environment(args.account_env)
    providers = environment(args.provider_env)
    account = credentials.get('CLOUDFLARE_ACCOUNT_ID')
    token = credentials.get('CLOUDFLARE_API_TOKEN')
    if not account or not token:
        raise RuntimeError('account credentials unavailable')
    if len(providers.get('SESSION_SIGNING_KEY', '')) < 32:
        raise RuntimeError('session signing key unavailable')
    bindings = [
        {'type': 'plain_text', 'name': 'PUBLIC_ORIGIN', 'text': 'https://pleazyng-api.snape.tech'},
        {'type': 'durable_object_namespace', 'name': 'SESSIONS', 'class_name': 'OAuthSession'},
        {'type': 'durable_object_namespace', 'name': 'ADMISSION', 'class_name': 'OAuthAdmission'},
        {'type': 'ratelimit', 'name': 'START_LIMIT', 'namespace_id': '182791', 'simple': {'limit': 3, 'period': 60}},
    ]
    for name in ['SESSION_SIGNING_KEY', 'MAL_CLIENT_ID', 'ANILIST_CLIENT_ID', 'ANILIST_CLIENT_SECRET']:
        if providers.get(name):
            bindings.append({'type': 'secret_text', 'name': name, 'text': providers[name]})
    metadata = {
        'main_module': 'worker.mjs', 'compatibility_date': '2026-11-06', 'bindings': bindings,
        'observability': {'enabled': False, 'redact_query_string': True, 'logs': {'enabled': False, 'invocation_logs': False, 'persist': False}, 'traces': {'enabled': False, 'persist': False}},
        'annotations': {'workers/message': f'Pleazyng OAuth source {actual}', 'workers/tag': actual[:12]},
    }
    if args.initial:
        metadata['migrations'] = {'new_tag': 'v1', 'new_sqlite_classes': ['OAuthSession', 'OAuthAdmission']}
    boundary = uuid.uuid4().hex
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n'.encode()
            + json.dumps(metadata).encode()
            + f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="worker.mjs"; filename="worker.mjs"\r\nContent-Type: application/javascript+module\r\n\r\n'.encode()
            + source + f'\r\n--{boundary}--\r\n'.encode())
    request = urllib.request.Request(f'https://api.cloudflare.com/client/v4/accounts/{account}/workers/scripts/pleazyng-oauth', data=body, method='PUT', headers={
        'Authorization': f'Bearer {token}', 'Content-Type': f'multipart/form-data; boundary={boundary}',
    })
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        # API diagnostic bodies can echo binding values. Do not dump them.
        raise RuntimeError(f'Cloudflare rejected upload: HTTP {exc.code}') from None
    if not result.get('success'):
        raise RuntimeError('Cloudflare did not confirm upload')
    print(json.dumps({'worker': 'pleazyng-oauth', 'source_sha': actual, 'deployment_id': result.get('result', {}).get('deployment_id'), 'routes_changed': False}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc)) from None
