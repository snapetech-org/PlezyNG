#!/usr/bin/env python3
"""Check public Pleazyng identities; compatibility exceptions are documented below.

Retained: snapetech-org/PlezyNG URLs (owner deferred repo rename), internal
com.edde746.plezy / org.snapetech.plezyng JNI and method channels, credential
vault keys, persisted schemas, docs/plezyng paths, runner labels and existing
environment/secret names. Historical release receipts and GPL notices remain.
"""

import json
import plistlib
import re
from pathlib import Path

from check_brand_assets import check as check_art
from check_deep_link_schemes import check as check_links

ROOT = Path(__file__).resolve().parents[2]


def check():
    errors = check_art()
    check_links()
    expected = {
        'android/app/build.gradle.kts': 'applicationId = "org.snapetech.pleazyng"',
        'macos/Runner/Configs/AppInfo.xcconfig': 'PRODUCT_NAME = Pleazyng',
        'linux/CMakeLists.txt': 'set(APPLICATION_ID "org.snapetech.pleazyng")',
        'windows/CMakeLists.txt': 'set(BINARY_NAME "pleazyng")',
        'scripts/generate_winget_manifests.py': 'PACKAGE_ID = "SnapeTech.Pleazyng"',
        'Casks/snapetech-pleazyng.rb.template': 'app "Pleazyng.app"',
        'lib/services/deep_links/deep_link.dart': "scheme = 'pleazyng'",
        'lib/sources/source_oauth.dart': 'pleazyng-source://oauth/callback',
    }
    for relative, marker in expected.items():
        if marker not in (ROOT / relative).read_text():
            errors.append(f'{relative}: missing canonical identity {marker}')
    for platform in ('ios', 'macos', 'tvos'):
        info = plistlib.loads((ROOT / platform / 'Runner/Info.plist').read_bytes())
        if info.get('CFBundleDisplayName') != 'Pleazyng':
            errors.append(f'{platform}: wrong display name')
    info = json.loads((ROOT / 'webos/meta/appinfo.json').read_text())
    if (info['id'], info['main'], info['title']) != ('org.snapetech.pleazyng', 'pleazyng', 'Pleazyng'):
        errors.append('webOS identity differs')
    # Source translations, including non-English copy, must not expose old names.
    for path in (ROOT / 'lib/i18n').glob('*.i18n.json'):
        values = re.findall(r':\s*"((?:[^"\\]|\\.)*)"', path.read_text())
        if any(re.search(r'\b(?:PlezyNG|Plezy)\b', value) for value in values):
            errors.append(f'{path.name}: old product display name')
    for relative in ('lib/services/plezy_server.dart', 'lib/services/discord_service.dart', 'lib/services/trakt_service.dart'):
        path = ROOT / relative
        if path.exists() and re.search(r'ice\.plezy\.app|1453773470306402439', path.read_text()):
            errors.append(f'{relative}: upstream runtime registration')
    if (ROOT / 'assets/readme-showcase.webp').exists():
        errors.append('Inherited marketing screenshot must not be shipped')
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Pleazyng public identities, artwork and protocol ownership verified.')


if __name__ == '__main__':
    check()
