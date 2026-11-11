#!/usr/bin/env python3
"""Archive/export a trial/IAP Apple app with validated per-target Store profiles."""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from apple_signing_material import decode_secret, run, signing_identity
from apple.configure_ios_music_widget import (
    BUNDLE as WIDGET_BUNDLE, PROFILE_KEY as WIDGET_PROFILE_KEY, TARGET as WIDGET_TARGET,
    add_music_widget_target, verify_music_widget,
)

BUNDLE = 'org.snapetech.pleazyng'
GROUP = 'group.org.snapetech.pleazyng'
PROFILE_KEYS = {
    'ios': [('Runner', BUNDLE, 'IOS_PROVISIONING_PROFILE_BASE64'),
            ('RommWorker', BUNDLE + '.RommWorker', 'IOS_ROMMWORKER_PROVISIONING_PROFILE_BASE64')],
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
    # The enhanced-security worker does not use the host's shared app group.
    worker = platform == 'ios' and bundle == BUNDLE + '.RommWorker'
    if not worker and GROUP not in entitlements.get('com.apple.security.application-groups', []):
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
                'IOS_PROVISIONING_PROFILE_BASE64', 'IOS_ROMMWORKER_PROVISIONING_PROFILE_BASE64',
                'TVOS_PROVISIONING_PROFILE_BASE64',
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
            # Both Store platforms and their embedded native workers ship the
            # arm64 device ABI. Do not let an SDK add an unsupported arm64e slice.
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


def _jose_signature(der: bytes) -> bytes:
    """Convert OpenSSL's P-256 ASN.1 pair to JWT's fixed-width signature."""
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError('Invalid ES256 signature encoding')
    offset, values = 2, []
    for _ in range(2):
        if offset + 2 > len(der) or der[offset] != 0x02:
            raise ValueError('Invalid ES256 signature integer')
        size = der[offset + 1]
        raw = der[offset + 2:offset + 2 + size]
        if not 1 <= size <= 33 or len(raw) != size or raw[0] & 0x80:
            raise ValueError('Invalid ES256 signature size')
        value = int.from_bytes(raw, 'big')
        if value >= 1 << 256:
            raise ValueError('Invalid ES256 signature scalar')
        values.append(value.to_bytes(32, 'big'))
        offset += 2 + size
    if offset != len(der):
        raise ValueError('Unexpected ES256 signature bytes')
    return b''.join(values)


def _apple_api_token(stage: Path) -> str:
    key_id, issuer = (os.environ.get(name, '') for name in ('APPLE_API_KEY_ID', 'APPLE_API_ISSUER_ID'))
    if not re.fullmatch(r'[A-Z0-9]{10}', key_id) or not re.fullmatch(r'[0-9a-fA-F-]{36}', issuer):
        raise ValueError('Apple API key ID or issuer is missing or invalid')
    private_key = os.environ.get('APPLE_API_PRIVATE_KEY', '')
    if not private_key.startswith('-----BEGIN PRIVATE KEY-----'):
        raise ValueError('APPLE_API_PRIVATE_KEY must contain its original PEM')
    key = stage / 'api-key.p8'
    key.write_text(private_key)
    key.chmod(0o600)
    encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b'=')
    now = int(time.time())
    header = encode(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}, separators=(',', ':')).encode())
    payload = encode(json.dumps({'iss': issuer, 'iat': now - 5, 'exp': now + 1100,
                                 'aud': 'appstoreconnect-v1'}, separators=(',', ':')).encode())
    message = header + b'.' + payload
    try:
        signature = run(['openssl', 'dgst', '-sha256', '-sign', str(key)], data=message)
    finally:
        key.unlink(missing_ok=True)
    token = (message + b'.' + encode(_jose_signature(signature))).decode()
    print(f'::add-mask::{token}', flush=True)
    return token


class _NoAppleRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('Apple API redirect refused')


class AppleProfileAPI:
    """Bounded Apple-only API requests; credentials/response bodies never logged."""
    origin = 'https://api.appstoreconnect.apple.com'

    def __init__(self, token: str):
        self.token = token
        self.opener = urllib.request.build_opener(_NoAppleRedirect())

    def request(self, path: str, body: dict | None = None) -> dict:
        url = path if path.startswith('https://') else self.origin + path
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme, parsed.netloc) != ('https', 'api.appstoreconnect.apple.com') or not parsed.path.startswith('/v1/'):
            raise ValueError('Refusing a non-Apple provisioning API destination')
        request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + self.token,
            'Content-Type': 'application/json'}, data=json.dumps(body).encode() if body is not None else None)
        try:
            with self.opener.open(request, timeout=60) as response:
                data = response.read(4 * 1024 * 1024 + 1)
        except urllib.error.HTTPError as error:
            # Even API error bodies can contain profile/credential material.
            raise RuntimeError(f'Apple provisioning API returned HTTP {error.code}') from None
        except urllib.error.URLError:
            raise RuntimeError('Apple provisioning API connection failed') from None
        if len(data) > 4 * 1024 * 1024:
            raise ValueError('Apple provisioning API response exceeds limit')
        try:
            result = json.loads(data)
        except (ValueError, UnicodeError):
            raise ValueError('Apple provisioning API returned invalid JSON') from None
        if not isinstance(result, dict) or 'errors' in result:
            raise ValueError('Apple provisioning API returned an unsuccessful response')
        return result

    def items(self, path: str) -> list[dict]:
        values, seen = [], set()
        while path:
            if path in seen or len(seen) >= 20:
                raise ValueError('Apple provisioning API pagination exceeds limit')
            seen.add(path)
            page = self.request(path)
            if not isinstance(page.get('data'), list):
                raise ValueError('Apple provisioning API list is malformed')
            values.extend(page['data'])
            path = page.get('links', {}).get('next')
        return values


def _worker_profile(api, stage: Path, certificate: bytes, team: str) -> tuple[bytes, str]:
    worker_bundle = BUNDLE + '.RommWorker'
    bundles = api.items('/v1/bundleIds?' + urllib.parse.urlencode({'filter[identifier]': worker_bundle, 'limit': 200}))
    bundles = [item for item in bundles if item.get('attributes', {}).get('identifier') == worker_bundle
               and item.get('attributes', {}).get('platform') == 'IOS']
    # Match the already imported certificate; never create or rotate identities.
    certificates = []
    for item in api.items('/v1/certificates?limit=200'):
        attributes = item.get('attributes', {})
        if attributes.get('certificateType') not in ('DISTRIBUTION', 'IOS_DISTRIBUTION'):
            continue
        try:
            content = base64.b64decode(attributes.get('certificateContent', ''), validate=True)
        except ValueError:
            continue
        if content == certificate:
            certificates.append(item)
    if len(certificates) != 1:
        raise ValueError('Expected one Apple API certificate matching the existing distribution identity')

    if not bundles:
        bundles = [api.request('/v1/bundleIds', {'data': {'type': 'bundleIds', 'attributes': {
            'identifier': worker_bundle, 'name': 'Pleazyng RommWorker', 'platform': 'IOS'}}}).get('data', {})]
    if len(bundles) != 1 or bundles[0].get('attributes', {}).get('identifier') != worker_bundle or bundles[0].get('attributes', {}).get('platform') != 'IOS':
        raise ValueError('Expected one exact iOS RommWorker bundle ID')
    bundle_id = bundles[0]['id']

    def decode(item):
        attributes = item.get('attributes', {})
        if attributes.get('profileType') != 'IOS_APP_STORE' or attributes.get('profileState') != 'ACTIVE':
            raise ValueError('Worker requires an active iOS App Store profile')
        data = base64.b64decode(attributes.get('profileContent', ''), validate=True)
        profile_path = stage / 'RommWorker.mobileprovision'
        profile_path.write_bytes(data)
        profile_path.chmod(0o600)
        profile = plistlib.loads(run(['security', 'cms', '-D', '-i', str(profile_path)]))
        uuid = validate_profile(profile, bundle=worker_bundle, platform='ios', team=team, certificate=certificate)
        return data, uuid

    profiles = api.items(f'/v1/bundleIds/{urllib.parse.quote(bundle_id, safe="")}/profiles?limit=200')
    for item in sorted(profiles, key=lambda value: value.get('attributes', {}).get('expirationDate', ''), reverse=True):
        try:
            return decode(item)
        except ValueError:
            continue
    created = api.request('/v1/profiles', {'data': {'type': 'profiles', 'attributes': {
        'name': 'Pleazyng RommWorker App Store ' + hashlib.sha256(certificate).hexdigest()[:12] + ' ' + str(time.time_ns()),
        'profileType': 'IOS_APP_STORE'}, 'relationships': {
        'bundleId': {'data': {'type': 'bundleIds', 'id': bundle_id}},
        'certificates': {'data': [{'type': 'certificates', 'id': certificates[0]['id']}]}}}})
    return decode(created.get('data', {}))


def prepare_ios_worker_profile() -> None:
    """Create/reuse the worker profile, validate both targets, export only masked data."""
    output = os.environ.get('GITHUB_ENV')
    if not output:
        raise ValueError('Worker profile preparation requires the current GitHub job environment')
    report = {}
    with signing_identity(report) as (stage, certificate, _fingerprint, team, _keychain):
        host_path = stage / 'Runner.mobileprovision'
        host_path.write_bytes(decode_secret('IOS_PROVISIONING_PROFILE_BASE64'))
        host_path.chmod(0o600)
        host = plistlib.loads(run(['security', 'cms', '-D', '-i', str(host_path)]))
        validate_profile(host, bundle=BUNDLE, platform='ios', team=team, certificate=certificate)
        data, _uuid = _worker_profile(AppleProfileAPI(_apple_api_token(stage)), stage, certificate, team)
        encoded = base64.b64encode(data).decode()
        print(f'::add-mask::{encoded}', flush=True)
        with Path(output).open('a') as stream:
            stream.write('IOS_ROMMWORKER_PROVISIONING_PROFILE_BASE64=' + encoded + '\n')
        print('Validated separate iOS Runner and RommWorker App Store profiles against the existing distribution identity.')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-ios-worker-profile', action='store_true')
    parser.add_argument('--platform', choices=PROFILE_KEYS)
    parser.add_argument('--archive-path', type=Path)
    parser.add_argument('--export-path', type=Path)
    parser.add_argument('--derived-data', type=Path)
    parser.add_argument('--source-packages', type=Path)
    args = parser.parse_args()
    if args.prepare_ios_worker_profile:
        prepare_ios_worker_profile()
        return
    if not all((args.platform, args.archive_path, args.export_path, args.derived_data)):
        parser.error('Archive mode requires platform, archive-path, export-path and derived-data')
    archive(args.platform, args.archive_path, args.export_path, args.derived_data, args.source_packages)


if __name__ == '__main__':
    main()
