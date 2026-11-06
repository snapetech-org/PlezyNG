#!/usr/bin/env python3
"""Smoke-test real workerd and SQLite with test credentials; no provider login."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import urllib.error
import urllib.request
import urllib.parse
import time


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[2]
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    command = ['npx', '--yes', 'wrangler@4.158.0', 'dev', '--local', '--ip', '127.0.0.1',
               '--config', 'server/cloudflare-oauth/wrangler.toml', '--port', str(port),
               '--persist-to', str(output / 'state'), '--var', f'PUBLIC_ORIGIN:{base}',
               '--var', 'MAL_CLIENT_ID:local-test',
               '--var', 'SESSION_SIGNING_KEY:local-only-test-signing-material-32-bytes']
    opener = urllib.request.build_opener(NoRedirect)

    def request(path, body=None):
        req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body else None,
                                     headers={'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.10'})
        try:
            return opener.open(req, timeout=10)
        except urllib.error.HTTPError as exc:
            return exc

    with (output / 'workerd.log').open('w') as log:
        process = subprocess.Popen(command, cwd=root, stdout=log, stderr=log,
                                   env=dict(os.environ, CLOUDFLARE_SEND_METRICS='false'), start_new_session=True)
        try:
            for _ in range(80):
                try:
                    if request('/auth/edge-health').status == 200:
                        break
                except urllib.error.URLError:
                    pass
                if process.poll() is not None:
                    raise RuntimeError('workerd stopped; inspect workerd.log')
                time.sleep(0.25)
            else:
                raise RuntimeError('workerd startup timed out')
            response = request('/auth/start', {'service': 'mal'})
            assert response.status == 200, ('start', response.status)
            session = json.load(response)
            state = urllib.parse.parse_qs(urllib.parse.urlparse(session['url']).query)['state'][0]
            response = request('/auth/mal?state=' + state)
            assert response.status == 302, ('authorize', response.status)
            assert response.headers['Location'].startswith('https://myanimelist.net/v1/oauth2/authorize?')
            assert request('/auth/mal/callback?state=' + state + '&error=access_denied').status == 200
            response = request('/auth/result?session=' + session['session'])
            assert response.status == 200
            assert json.load(response) == {'error': 'access_denied'}
            assert request('/auth/result?session=' + session['session']).status == 410
            print('workerd + SQLite + rate limiter: redirect, callback, single-use delivery passed')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
