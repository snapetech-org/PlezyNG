#!/usr/bin/env python3
"""Validate configured Apple signing material without exporting any private key."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import sys
import tempfile
import urllib.request


def run(command: list[str], *, data: bytes | None = None) -> bytes:
    result = subprocess.run(command, input=data, capture_output=True, check=False)
    if result.returncode:
        # Commands can include passwords. Never include argv or untrusted
        # diagnostics in logs, exception messages, reports or artifacts.
        operation = command[1] if len(command) > 1 else ''
        safe_diagnostics = [message for message in (
            'errSecInternalComponent', 'unable to build chain', 'User interaction is not allowed',
            'no identity found', 'The specified item could not be found',
        ) if message.lower() in result.stderr.decode(errors='replace').lower()]
        raise RuntimeError(f'{Path(command[0]).name} {operation} signing check failed (exit {result.returncode}); '
                           + '; '.join(safe_diagnostics))
    return result.stdout


def decode_secret(name: str) -> bytes:
    value = os.environ.get(name, '')
    if not value:
        raise ValueError(f'{name} is missing')
    try:
        return base64.b64decode(''.join(value.split()), validate=True)
    except ValueError:
        raise ValueError(f'{name} is not valid base64') from None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    report: dict = {'signing_qualified': False, 'app_build_qualified': False}
    keychain: Path | None = None
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('This check requires native macOS security/codesign tools')
        team = os.environ.get('APPLE_TEAM_ID', '')
        if not re.fullmatch(r'[A-Z0-9]{10}', team):
            raise ValueError('APPLE_TEAM_ID is missing or invalid')
        with tempfile.TemporaryDirectory(prefix='pleazyng-apple-signing-') as temporary:
            stage = Path(temporary)
            stage.chmod(0o700)
            p12 = stage / 'identity.p12'
            p12.write_bytes(decode_secret('APPLE_DISTRIBUTION_CERTIFICATE_BASE64'))
            p12.chmod(0o600)
            if not os.environ.get('APPLE_CERTIFICATE_PASSWORD'):
                raise ValueError('APPLE_CERTIFICATE_PASSWORD is missing')
            pem = run(['openssl', 'pkcs12', '-in', str(p12), '-passin',
                       'env:APPLE_CERTIFICATE_PASSWORD', '-clcerts', '-nokeys'])
            certificate = run(['openssl', 'x509', '-outform', 'DER'], data=pem)
            subject = run(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'], data=pem).decode()
            if f'OU={team}' not in subject or 'CN=Apple Distribution:' not in subject:
                raise ValueError('PKCS12 does not contain the expected team Apple Distribution identity')
            run(['openssl', 'x509', '-noout', '-checkend', '86400'], data=pem)
            fingerprint = hashlib.sha1(certificate).hexdigest().upper()  # Apple's identity selector
            report.update(team=team, certificate_sha256=hashlib.sha256(certificate).hexdigest(),
                          certificate_sha1=fingerprint)
            password = secrets.token_urlsafe(32)
            keychain = stage / 'signing.keychain-db'
            run(['security', 'create-keychain', '-p', password, str(keychain)])
            try:
                run(['security', 'unlock-keychain', '-p', password, str(keychain)])
                # OpenSSL 3's default PBES2 PKCS12 encoding is not accepted by
                # every macOS Security.framework version. Re-encode the same
                # existing identity with Apple's compatible SHA1/3DES format.
                # The transient PEM is mode0600 inside the mode0700 temporary
                # directory and is removed immediately after conversion.
                identity_pem = run(['openssl', 'pkcs12', '-in', str(p12), '-passin',
                                    'env:APPLE_CERTIFICATE_PASSWORD', '-nodes'])
                report['private_key_present_in_pkcs12'] = bool(re.search(
                    rb'-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----', identity_pem))
                if not report['private_key_present_in_pkcs12']:
                    raise ValueError('Configured PKCS12 contains the certificate but no private key; recover the original signing identity')
                private_public = run(['openssl', 'pkey', '-pubout', '-outform', 'DER'], data=identity_pem)
                certificate_public = run(['openssl', 'x509', '-pubkey', '-noout'], data=pem)
                certificate_public = run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], data=certificate_public)
                report['private_key_matches_certificate'] = private_public == certificate_public
                if not report['private_key_matches_certificate']:
                    raise ValueError('Configured PKCS12 private key does not match its Apple Distribution certificate')
                identity_file = stage / 'identity.pem'
                identity_file.write_bytes(identity_pem)
                identity_file.chmod(0o600)
                os.environ['PLEAZYNG_PREFLIGHT_P12_PASSWORD'] = secrets.token_urlsafe(32)
                try:
                    compatible = run(['openssl', 'pkcs12', '-export', '-in', str(identity_file),
                                      '-inkey', str(identity_file), '-keypbe', 'PBE-SHA1-3DES',
                                      '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1',
                                      '-passout', 'env:PLEAZYNG_PREFLIGHT_P12_PASSWORD'], data=identity_pem)
                    identity_pem = b''
                    p12.write_bytes(compatible)
                    run(['security', 'import', str(p12), '-k', str(keychain), '-P',
                         os.environ['PLEAZYNG_PREFLIGHT_P12_PASSWORD'], '-T', '/usr/bin/codesign'])
                    report['compatible_pkcs12_encoding'] = True
                finally:
                    identity_file.unlink(missing_ok=True)
                    os.environ.pop('PLEAZYNG_PREFLIGHT_P12_PASSWORD', None)
                identities = run(['security', 'find-identity', '-p', 'codesigning', str(keychain)]).decode()
                if fingerprint not in identities:
                    raise ValueError('Imported certificate has no matching code-signing private key')
                report['matching_private_key'] = True
                # Import the pinned public intermediate into this isolated
                # keychain only. Do not modify system trust or other keychains.
                chain_url = 'https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer'
                with urllib.request.urlopen(chain_url, timeout=30) as response:
                    chain = response.read(16384)
                chain_hash = 'dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f'
                if hashlib.sha256(chain).hexdigest() != chain_hash:
                    raise ValueError('Apple WWDR G3 intermediate checksum mismatch')
                chain_path = stage / 'AppleWWDRCAG3.cer'
                chain_path.write_bytes(chain)
                run(['security', 'import', str(chain_path), '-k', str(keychain)])
                report['wwdr_g3_sha256'] = chain_hash
                run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
                     '-s', '-k', password, str(keychain)])
                probe = stage / 'signing-probe'
                run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(probe)], data=b'int main(void) { return 0; }\n')
                run(['codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain),
                     '--timestamp=none', str(probe)])
                run(['codesign', '--verify', '--strict', str(probe)])
                report['signing_qualified'] = True
            finally:
                run(['security', 'delete-keychain', str(keychain)])
                keychain = None
            # Decode in memory only: profile payloads can contain private device
            # identifiers. Publish only the bounded fields needed for this app.
            profiles = {}
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
    except (RuntimeError, ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        report['error'] = str(error)
        return_code = 1
    else:
        return_code = 0
    finally:
        if keychain is not None:
            # Do not allow cleanup failures to print the private command args.
            subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True, check=False)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('Apple signing check passed.' if return_code == 0 else 'Apple signing check failed; see bounded public report.')
    return return_code


if __name__ == '__main__':
    raise SystemExit(main())
