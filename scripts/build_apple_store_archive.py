#!/usr/bin/env python3
"""Archive/export a trial/IAP Apple app with validated per-target Store profiles."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from apple_signing_material import decode_secret, run, signing_identity
from apple.configure_ios_music_widget import (
    BUNDLE as WIDGET_BUNDLE, PROFILE_KEY as WIDGET_PROFILE_KEY, TARGET as WIDGET_TARGET,
    add_music_widget_target, verify_music_widget,
)

BUNDLE = 'org.snapetech.pleazyng'
GROUP = 'group.org.snapetech.pleazyng'
PROFILE_KEYS = {
    'ios': [('Runner', BUNDLE, 'IOS_PROVISIONING_PROFILE_BASE64')],
    'tvos': [('Runner', BUNDLE, 'TVOS_PROVISIONING_PROFILE_BASE64'),
             ('TopShelfExtension', BUNDLE + '.TopShelfExtension', 'TVOS_TOPSHELF_PROVISIONING_PROFILE_BASE64')],
}
MUSIC_NFC_ENTITLEMENT = 'com.apple.developer.nfc.readersession.formats'
MUSIC_NFC_FILE = 'Runner/MusicNFC.entitlements'


def music_nfc_allowed(profile: dict, platform: str) -> bool:
    formats = profile.get('Entitlements', {}).get(MUSIC_NFC_ENTITLEMENT)
    return platform == 'ios' and isinstance(formats, list) and 'TAG' in formats


def validate_profile(profile: dict, *, bundle: str, platform: str, team: str, certificate: bytes) -> str:
    entitlements = profile.get('Entitlements', {})
    expected = f'{team}.{bundle}'
    if entitlements.get('application-identifier') != expected or profile.get('TeamIdentifier') != [team]:
        raise ValueError(f'Profile does not match {expected}')
    if certificate not in profile.get('DeveloperCertificates', []):
        raise ValueError('Profile does not include the imported distribution certificate')
    if ('iOS' if platform == 'ios' else 'tvOS') not in profile.get('Platform', []):
        raise ValueError('Profile platform does not match the archive target')
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime) or expires.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError('Profile is expired or missing its expiration')
    if (entitlements.get('get-task-allow', False) or profile.get('ProvisionedDevices')
            or profile.get('ProvisionsAllDevices', False)):
        raise ValueError('Archive requires an App Store distribution profile')
    if GROUP not in entitlements.get('com.apple.security.application-groups', []):
        raise ValueError('Profile does not include the Pleazyng app group')
    uuid = profile.get('UUID', '')
    if not re.fullmatch(r'[0-9a-fA-F-]{36}', uuid):
        raise ValueError('Profile UUID is missing or invalid')
    return uuid


def configure_project(project: dict, bindings: dict[str, dict], team: str, fingerprint: str, keychain: Path,
                      widget_host_entitlements: Path | None = None) -> None:
    objects = project['objects']
    targets = [objects[key] for key in objects[project['rootObject']]['targets']]
    for name, binding in bindings.items():
        matching = [target for target in targets if target.get('name') == name and target.get('isa') == 'PBXNativeTarget']
        if len(matching) != 1:
            raise ValueError(f'Expected exactly one signing target: {name}')
        configs = objects[matching[0]['buildConfigurationList']]['buildConfigurations']
        releases = [objects[key] for key in configs if objects[key].get('name') == 'Release']
        if len(releases) != 1:
            raise ValueError(f'Expected exactly one Release configuration for {name}')
        settings = releases[0].setdefault('buildSettings', {})
        settings.update(CODE_SIGN_STYLE='Manual', DEVELOPMENT_TEAM=team,
                        CODE_SIGN_IDENTITY=fingerprint, PROVISIONING_PROFILE_SPECIFIER=binding['uuid'],
                        PRODUCT_BUNDLE_IDENTIFIER=binding['bundle'])
        if binding.get('music_nfc') and settings.get('CODE_SIGN_ENTITLEMENTS') in (None, '', MUSIC_NFC_FILE):
            settings['CODE_SIGN_ENTITLEMENTS'] = MUSIC_NFC_FILE
            settings['PLEAZYNG_MUSIC_NFC_ENABLED'] = 'YES'
        if name == 'Runner' and widget_host_entitlements is not None:
            source = settings.get('CODE_SIGN_ENTITLEMENTS')
            entitlements = plistlib.loads((Path('ios') / source).read_bytes()) if source else {}
            group_key = 'com.apple.security.application-groups'
            entitlements[group_key] = sorted(set([*entitlements.get(group_key, []), GROUP]))
            widget_host_entitlements.write_bytes(plistlib.dumps(entitlements))
            settings['CODE_SIGN_ENTITLEMENTS'] = str(widget_host_entitlements)
            for setting, additions in (
                ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ['PLEAZYNG_MUSIC_WIDGET_HOST']),
                ('OTHER_LDFLAGS', ['-weak_framework', 'AppIntents']),
            ):
                previous = settings.get(setting, '$(inherited)')
                settings[setting] = [*previous, *additions] if isinstance(previous, list) else ' '.join([previous, *additions])
        # Only the known job-owned path is added. Preserve other target flags.
        previous = settings.get('OTHER_CODE_SIGN_FLAGS', '$(inherited)')
        if isinstance(previous, list):
            previous = ' '.join(previous)
        settings['OTHER_CODE_SIGN_FLAGS'] = f'{previous} --keychain "{keychain}"'


def archive(platform: str, archive_path: Path, export_path: Path, derived_data: Path, source_packages: Path | None) -> None:
    report = {'app_build_qualified': False, 'archive_export_verified': False, 'store_purchase_verified': False}
    project_path = Path(platform) / 'Runner.xcodeproj/project.pbxproj'
    original_project = project_path.read_bytes()
    created_profiles: list[Path] = []
    try:
        with signing_identity(report) as (stage, certificate, fingerprint, team, keychain):
            bindings = {}
            profile_keys = list(PROFILE_KEYS[platform])
            widget_enabled = platform == 'ios' and bool(os.environ.get(WIDGET_PROFILE_KEY, '').strip())
            if widget_enabled:
                profile_keys.append((WIDGET_TARGET, WIDGET_BUNDLE, WIDGET_PROFILE_KEY))
            for target, bundle, secret in profile_keys:
                data = decode_secret(secret)
                profile_path = stage / f'{target}.mobileprovision'
                profile_path.write_bytes(data)
                profile_path.chmod(0o600)
                profile = plistlib.loads(run(['security', 'cms', '-D', '-i', str(profile_path)]))
                uuid = validate_profile(profile, bundle=bundle, platform=platform, team=team, certificate=certificate)
                bindings[target] = {'bundle': bundle, 'uuid': uuid,
                                    'music_nfc': target == 'Runner' and music_nfc_allowed(profile, platform)}
                installed = Path.home() / 'Library/MobileDevice/Provisioning Profiles' / f'{uuid}.mobileprovision'
                installed.parent.mkdir(parents=True, exist_ok=True)
                if installed.exists():
                    if installed.read_bytes() != data:
                        raise ValueError('Refusing to overwrite a different installed provisioning profile')
                else:
                    installed.write_bytes(data)
                    installed.chmod(0o600)
                    created_profiles.append(installed)
            project = plistlib.loads(run(['plutil', '-convert', 'xml1', '-o', '-', str(project_path)]))
            if widget_enabled:
                add_music_widget_target(project)
            configure_project(project, bindings, team, fingerprint, keychain,
                              widget_host_entitlements=stage / 'RunnerWidget.entitlements' if widget_enabled else None)
            # Xcode accepts XML project plists. Restore the original bytes after
            # this job's archive/export, including on failure.
            project_path.write_bytes(plistlib.dumps(project, sort_keys=False))
            run(['plutil', '-lint', str(project_path)])
            options = stage / 'export-options.plist'
            options.write_bytes(plistlib.dumps({
                'method': 'app-store-connect', 'signingStyle': 'manual', 'teamID': team,
                'signingCertificate': fingerprint, 'uploadSymbols': True,
                'provisioningProfiles': {binding['bundle']: binding['uuid'] for binding in bindings.values()},
            }))
            env = {key: value for key, value in os.environ.items() if key not in (
                'APPLE_DISTRIBUTION_CERTIFICATE_BASE64', 'APPLE_CERTIFICATE_PASSWORD',
                'APPLE_API_PRIVATE_KEY', 'APPLE_API_KEY_ID', 'APPLE_API_ISSUER_ID',
                'IOS_PROVISIONING_PROFILE_BASE64', 'TVOS_PROVISIONING_PROFILE_BASE64',
                'TVOS_TOPSHELF_PROVISIONING_PROFILE_BASE64',
                WIDGET_PROFILE_KEY,
            )}
            command = ['xcodebuild', 'archive', '-workspace', f'{platform}/Runner.xcworkspace',
                       '-scheme', 'Runner', '-configuration', 'Release', '-sdk',
                       'iphoneos' if platform == 'ios' else 'appletvos', '-destination',
                       'generic/platform=iOS' if platform == 'ios' else 'generic/platform=tvOS',
                       '-archivePath', str(archive_path), '-derivedDataPath', str(derived_data),
                       'COMPILER_INDEX_STORE_ENABLE=NO']
            if source_packages:
                command += ['-clonedSourcePackagesDirPath', str(source_packages)]
            if platform == 'tvos':
                command += ['ARCHS=arm64']
            subprocess.run(command, env=env, check=True)
            subprocess.run(['xcodebuild', '-exportArchive', '-archivePath', str(archive_path),
                            '-exportPath', str(export_path), '-exportOptionsPlist', str(options)], env=env, check=True)
            ipas = list(export_path.glob('*.ipa'))
            if len(ipas) != 1:
                raise ValueError('Xcode must export exactly one App Store IPA')
            if widget_enabled:
                verify_music_widget(ipas[0])
            destination = Path(f'pleazyng-{platform}-appstore.ipa')
            shutil.copy2(ipas[0], destination)
            with destination.open('rb') as stream:
                checksum = hashlib.sha256()
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    checksum.update(chunk)
            report.update(archive_export_verified=True, platform=platform, profiles=bindings,
                          ipa_sha256=checksum.hexdigest(), music_widget_embedded=widget_enabled)
    finally:
        project_path.write_bytes(original_project)
        for profile in created_profiles:
            profile.unlink(missing_ok=True)
        Path(f'pleazyng-{platform}-signing-report.json').write_text(json.dumps(report, indent=2) + '\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=PROFILE_KEYS)
    parser.add_argument('--archive-path', required=True, type=Path)
    parser.add_argument('--export-path', required=True, type=Path)
    parser.add_argument('--derived-data', required=True, type=Path)
    parser.add_argument('--source-packages', type=Path)
    args = parser.parse_args()
    archive(args.platform, args.archive_path, args.export_path, args.derived_data, args.source_packages)


if __name__ == '__main__':
    main()
