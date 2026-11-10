#!/usr/bin/env python3
"""Enable EL10 packaging capacity; never submit a build or claim qualification."""
import json
import os
from pathlib import Path


REQUIRED = {'epel-10-x86_64', 'epel-10-aarch64'}


def enable_targets(client, available):
    if not REQUIRED.issubset(available):
        raise ValueError('COPR does not offer both required EPEL10 targets')
    before = client.project_proxy.get('slskdn', 'pleazyng')
    existing = set(before['chroot_repos'])
    if not existing:
        raise ValueError('Existing project has no targets; refusing an ambiguous bootstrap')
    desired = sorted(existing | REQUIRED)
    if set(desired) != existing:
        client.project_proxy.edit('slskdn', 'pleazyng', chroots=desired)
    after = client.project_proxy.get('slskdn', 'pleazyng')
    enabled = set(after['chroot_repos'])
    if not set(desired).issubset(enabled):
        raise ValueError('COPR target verification failed after bootstrap')
    return {'project': 'slskdn/pleazyng', 'before': sorted(existing),
            'after': sorted(enabled), 'added': sorted(enabled - existing),
            'build_submitted': False, 'native_qualified': False}


def main():
    if os.environ.get('COPR_PROJECT') != 'slskdn/pleazyng':
        raise SystemExit('This bootstrap is scoped to slskdn/pleazyng')
    if any(not os.environ.get(key) for key in ('COPR_LOGIN', 'COPR_USERNAME', 'COPR_TOKEN')):
        raise SystemExit('COPR API credentials are not configured')
    # Credentials stay in process memory. Never read a browser/vault or write
    # an authentication file, and never print client exceptions containing auth.
    from copr.v3 import Client
    from urllib.request import urlopen
    try:
        with urlopen('https://copr.fedorainfracloud.org/api_3/mock-chroots/list', timeout=30) as response:
            available = json.load(response)
        client = Client({'copr_url': 'https://copr.fedorainfracloud.org',
                         'login': os.environ['COPR_LOGIN'], 'username': os.environ['COPR_USERNAME'],
                         'token': os.environ['COPR_TOKEN'], 'connection_attempts': 1})
        result = enable_targets(client, available)
    except Exception as error:
        raise SystemExit(f'COPR bootstrap stopped ({type(error).__name__}); verify account/API status') from None
    Path(os.environ['COPR_BOOTSTRAP_RECEIPT']).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
