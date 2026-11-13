#!/usr/bin/env python3
"""Check public Pleazyng identities; compatibility exceptions are documented below.

Canonical repository: snapetech-org/pleazyng. Retained: historical redirect
aliases, internal
com.edde746.plezy / org.snapetech.plezyng JNI and method channels, credential
vault keys, persisted schemas, docs/plezyng paths, runner labels and existing
environment/secret names. Historical release receipts and GPL notices remain.
Legacy import onboarding may identify upstream Plezy as a possible database
source; those names are provenance, not current product branding.
"""

import json
import plistlib
import re
from pathlib import Path

from check_brand_assets import check as check_art
from check_deep_link_schemes import check as check_links

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM_IMPORT_COPY_KEYS = {
    'startup.legacyImportBody',
    'startup.legacyImportIdentityWarning',
}


def translation_values(node, prefix=''):
    """Yield translation strings with their dotted key paths."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key.startswith('@'):
                continue
            child = f'{prefix}.{key}' if prefix else key
            yield from translation_values(value, child)
    elif isinstance(node, str):
        yield prefix, node


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
    # Source translations must not expose old product branding. The two legacy
    # import messages may name Plezy solely to identify a possible DB source.
    for path in (ROOT / 'lib/i18n').glob('*.i18n.json'):
        data = json.loads(path.read_text())
        invalid_name = any(
            re.search(r'\bPlezyNG\b', value)
            or (
                key not in UPSTREAM_IMPORT_COPY_KEYS
                and re.search(r'\bPlezy\b', value)
            )
            for key, value in translation_values(data)
        )
        if invalid_name:
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
