#!/usr/bin/env python3
"""Isolated, compatible Apple Distribution identity for native release jobs."""
from __future__ import annotations

import base64
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
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


@contextmanager
def signing_identity(report: dict):
    if sys.platform != "darwin":
        raise RuntimeError("Apple signing requires native macOS")
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
        original_search_list = shlex.split(run(['security', 'list-keychains', '-d', 'user']).decode())
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
            # codesign also uses the user search list for chain/identity
            # resolution. This runner is ephemeral; restore its original
            # list in finally and never change the default keychain.
            run(['security', 'list-keychains', '-d', 'user', '-s', str(keychain), *original_search_list])
            valid_identities = run(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)]).decode()
            report['valid_codesigning_identity'] = fingerprint in valid_identities
            run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
                 '-s', '-k', password, str(keychain)])
            probe = stage / 'signing-probe'
            run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(probe)], data=b'int main(void) { return 0; }\n')
            run(['codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain),
                 '--timestamp=none', str(probe)])
            run(['codesign', '--verify', '--strict', str(probe)])
            report['signing_qualified'] = True
            yield stage, certificate, fingerprint, team, keychain
        finally:
            try:
                run(['security', 'list-keychains', '-d', 'user', '-s', *original_search_list])
            finally:
                run(['security', 'delete-keychain', str(keychain)])
