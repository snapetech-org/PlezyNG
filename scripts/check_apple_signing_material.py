#!/usr/bin/env python3
"""Validate Apple signing identity and report only public profile bindings."""
import argparse
import json
import os
from pathlib import Path
import plistlib

from apple_signing_material import decode_secret, run, signing_identity
from build_apple_store_archive import PROFILE_KEYS, configure_project, validate_profile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--require-profiles', action='store_true')
    args = parser.parse_args()
    report = {'signing_qualified': False, 'app_build_qualified': False}
    try:
        with signing_identity(report) as (stage, certificate, fingerprint, team, keychain):
            # Decode in memory only: profile payloads can contain private device
            # identifiers. Publish only the bounded fields needed for this app.
            profiles = {}
            decoded_profiles = {}
            report['profiles'] = profiles
            for name, expected in (
                ('IOS_PROVISIONING_PROFILE_BASE64', f'{team}.org.snapetech.pleazyng'),
                ('TVOS_PROVISIONING_PROFILE_BASE64', f'{team}.org.snapetech.pleazyng'),
                ('TVOS_TOPSHELF_PROVISIONING_PROFILE_BASE64', f'{team}.org.snapetech.pleazyng.TopShelfExtension'),
            ):
                if not os.environ.get(name):
                    profiles[name] = {'configured': False}
                    continue
                profile_path = stage / 'profile.mobileprovision'
                profile_path.write_bytes(decode_secret(name))
                profile_path.chmod(0o600)
                profile = plistlib.loads(run(['security', 'cms', '-D', '-i', str(profile_path)]))
                decoded_profiles[name] = profile
                entitlements = profile.get('Entitlements', {})
                app_id = entitlements.get('application-identifier', '')
                matches_certificate = certificate in profile.get('DeveloperCertificates', [])
                profiles[name] = {
                    'configured': True, 'uuid': profile.get('UUID'),
                    'application_identifier': app_id, 'expected_identifier': expected,
                    'matches_identifier': app_id == expected,
                    'matches_certificate': matches_certificate,
                    'distribution': not entitlements.get('get-task-allow', False)
                                    and not profile.get('ProvisionedDevices')
                                    and not profile.get('ProvisionsAllDevices', False),
                    'expires': profile['ExpirationDate'].isoformat(),
                    'platforms': profile.get('Platform', []),
                }
            report['all_profiles_match'] = all(
                p.get('configured') and p.get('matches_identifier') and p.get('matches_certificate')
                and p.get('distribution') for p in profiles.values())
            if args.require_profiles and not report['all_profiles_match']:
                raise ValueError('All three new-bundle App Store profiles must be configured and match the signing identity')
            if args.require_profiles:
                for platform, targets in PROFILE_KEYS.items():
                    bindings = {}
                    for target, bundle, secret in targets:
                        uuid = validate_profile(decoded_profiles[secret], bundle=bundle, platform=platform,
                                                team=team, certificate=certificate)
                        bindings[target] = {'bundle': bundle, 'uuid': uuid}
                    project = Path(platform) / 'Runner.xcodeproj/project.pbxproj'
                    configured = plistlib.loads(run(['plutil', '-convert', 'xml1', '-o', '-', str(project)]))
                    configure_project(configured, bindings, team, fingerprint, keychain)
                    temporary_project = stage / f'{platform}-project.pbxproj'
                    temporary_project.write_bytes(plistlib.dumps(configured, sort_keys=False))
                    run(['plutil', '-lint', str(temporary_project)])
                report['both_project_signing_bindings_validated'] = True
    except (RuntimeError, ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        report['error'] = str(error)
        return_code = 1
    else:
        return_code = 0
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Apple signing check passed.' if return_code == 0 else 'Apple signing check failed; see public report.')
    return return_code


if __name__ == '__main__':
    raise SystemExit(main())
