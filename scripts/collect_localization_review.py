#!/usr/bin/env python3
"""Expose bounded candidate data for review; never apply translations."""
import hashlib
import io
import json
import os
import urllib.request
import zipfile

REPO = 'snapetech-org/pleazyng'
RUN = 42715225087
REVISION = 'af2afd254438aa110d310194f61cba20e4c960c1'


class ArtifactRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('Insecure artifact redirect')
        redirected = super().redirect_request(request, fp, code, msg, headers, newurl)
        if redirected is not None:
            redirected.remove_header('Authorization')
        return redirected


def api(path):
    request = urllib.request.Request(f'https://api.github.com/repos/{REPO}/{path}',
        headers={'Authorization': f'Bearer {os.environ["GH_TOKEN"]}', 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.build_opener(ArtifactRedirects()).open(request, timeout=60) as response:
        return response.read(8 * 1024 * 1024 + 1)


def main():
    run = json.loads(api(f'actions/runs/{RUN}'))
    if run['head_sha'] != REVISION or run['head_branch'] != 'main' or run['head_repository']['full_name'] != REPO:
        raise ValueError('Unexpected candidate source')
    artifacts = json.loads(api(f'actions/runs/{RUN}/artifacts?per_page=100'))['artifacts']
    for artifact in sorted(artifacts, key=lambda value: value['name']):
        if not artifact['name'].startswith('localization-') or artifact['expired']:
            continue
        if artifact['size_in_bytes'] > 2 * 1024 * 1024:
            raise ValueError('Oversized candidate archive')
        body = api(f'actions/artifacts/{artifact["id"]}/zip')
        if 'sha256:' + hashlib.sha256(body).hexdigest() != artifact['digest']:
            raise ValueError('Candidate archive digest mismatch')
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            files = archive.infolist()
            if len(files) != 1 or files[0].file_size > 2 * 1024 * 1024:
                raise ValueError('Unexpected candidate archive')
            candidate = json.loads(archive.read(files[0]))
        if artifact['name'] != 'localization-' + candidate['locale'] or candidate['nativeSpeakerReviewed'] is not False:
            raise ValueError('Unexpected candidate provenance')
        print('LOCALIZATION_CANDIDATE ' + json.dumps(candidate, ensure_ascii=False), flush=True)
    print(f'Available candidate archives: {len(artifacts)}; generation: {run["status"]}')


if __name__ == '__main__':
    main()
