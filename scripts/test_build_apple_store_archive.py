#!/usr/bin/env python3
"""Prevent old-bundle, wrong-store and shared-target signing profile reuse."""
import contextlib
import tempfile
from unittest.mock import Mock, patch
from copy import deepcopy
from datetime import datetime, timedelta
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_apple_store_archive as archive_helper
from build_apple_store_archive import BUNDLE, GROUP, configure_project, validate_profile

TEAM = 'DM9A59DC85'
CERT = b'fixture-distribution-certificate'
UUID = '4fce21b1-451d-4b19-805c-530c11be00e9'


class AppleStoreSigningTests(unittest.TestCase):
    def profile(self):
        return {'UUID': UUID, 'TeamIdentifier': [TEAM], 'DeveloperCertificates': [CERT],
                'Platform': ['iOS'], 'ExpirationDate': datetime.now() + timedelta(days=365),
                'Entitlements': {'application-identifier': f'{TEAM}.{BUNDLE}',
                                 'com.apple.security.application-groups': [GROUP]}}

    def test_matching_profile_and_wrong_bundle_certificate_platform(self):
        def check(profile, **kwargs):
            return validate_profile(profile, bundle=BUNDLE, platform='ios', team=TEAM, certificate=CERT, **kwargs)
        self.assertEqual(check(self.profile()), UUID)
        changes = [('Entitlements', {'application-identifier': f'{TEAM}.org.snapetech.plezyng'}),
                   ('TeamIdentifier', ['OTHERTEAM1']), ('DeveloperCertificates', [b'other certificate']),
                   ('Platform', ['tvOS']), ('ExpirationDate', datetime.now() - timedelta(days=1))]
        for key, value in changes:
            with self.subTest(field=key):
                profile = self.profile(); profile[key] = value
                with self.assertRaises(ValueError): check(profile)

    def test_development_adhoc_enterprise_and_missing_group_are_rejected(self):
        for change in ('development', 'adhoc', 'enterprise', 'group'):
            with self.subTest(kind=change):
                profile = self.profile()
                if change == 'development': profile['Entitlements']['get-task-allow'] = True
                if change == 'adhoc': profile['ProvisionedDevices'] = ['fixture-device']
                if change == 'enterprise': profile['ProvisionsAllDevices'] = True
                if change == 'group': profile['Entitlements']['com.apple.security.application-groups'] = []
                with self.assertRaises(ValueError):
                    validate_profile(profile, bundle=BUNDLE, platform='ios', team=TEAM, certificate=CERT)

    def test_app_and_extension_get_distinct_profiles_without_changing_debug_or_other_targets(self):
        project = {'rootObject': 'root', 'objects': {'root': {'targets': ['app', 'extension', 'other']}}}
        objects = project['objects']
        for target, name in [('app', 'Runner'), ('extension', 'TopShelfExtension'), ('other', 'Other')]:
            objects[target] = {'isa': 'PBXNativeTarget', 'name': name, 'buildConfigurationList': target+'list'}
            objects[target+'list'] = {'buildConfigurations': [target+'release', target+'debug']}
            objects[target+'release'] = {'name': 'Release', 'buildSettings': {'KEEP': 'value'}}
            objects[target+'debug'] = {'name': 'Debug', 'buildSettings': {'KEEP': 'debug'}}
        original = deepcopy(project)
        bindings = {'Runner': {'bundle': BUNDLE, 'uuid': UUID},
                    'TopShelfExtension': {'bundle': BUNDLE+'.TopShelfExtension', 'uuid': 'different-extension-profile'}}
        configure_project(project, bindings, TEAM, 'fixture-fingerprint', Path('/tmp/task-signing.keychain-db'))
        for target, name in [('app', 'Runner'), ('extension', 'TopShelfExtension')]:
            settings = objects[target+'release']['buildSettings']
            self.assertEqual(settings['PROVISIONING_PROFILE_SPECIFIER'], bindings[name]['uuid'])
            self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], bindings[name]['bundle'])
            self.assertEqual(settings['KEEP'], 'value')
            self.assertEqual(objects[target+'debug'], original['objects'][target+'debug'])
        self.assertEqual(objects['otherrelease'], original['objects']['otherrelease'])
        with self.assertRaises(ValueError):
            configure_project(project, {'Absent': bindings['Runner']}, TEAM, 'fingerprint', Path('/tmp/keychain'))


class AppleProfileBootstrapTests(unittest.TestCase):
    def api(self, *, existing=True, wrong_certificate=False):
        import base64
        worker = {'type': 'bundleIds', 'id': 'worker-id', 'attributes': {
            'identifier': BUNDLE + '.RommWorker', 'platform': 'IOS'}}
        profile = {'id': 'profile-id', 'attributes': {'profileType': 'IOS_APP_STORE',
            'profileState': 'ACTIVE', 'profileContent': base64.b64encode(b'fixture-profile').decode(),
            'expirationDate': '2030-01-01'}}
        cert = {'id': 'cert-id', 'attributes': {'certificateType': 'DISTRIBUTION',
            'certificateContent': base64.b64encode(b'wrong' if wrong_certificate else CERT).decode()}}
        api = Mock()
        def items(path):
            if path.startswith('/v1/bundleIds?'): return [worker] if existing else []
            if path.startswith('/v1/certificates?'): return [cert]
            if path.startswith('/v1/bundleIds/worker-id/profiles?'): return [profile] if existing else []
            raise AssertionError(path)
        def request(path, body):
            if path == '/v1/bundleIds': return {'data': worker}
            if path == '/v1/profiles': return {'data': profile}
            raise AssertionError(path)
        api.items.side_effect, api.request.side_effect = items, request
        return api

    def test_existing_worker_profile_reused_without_mutations(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(archive_helper, 'run', return_value=b'cms'), \
                patch.object(archive_helper.plistlib, 'loads', return_value={'fixture': True}), \
                patch.object(archive_helper, 'validate_profile', return_value=UUID) as validate:
            api = self.api()
            self.assertEqual(archive_helper._worker_profile(api, Path(temporary), CERT, TEAM), (b'fixture-profile', UUID))
            api.request.assert_not_called()
            self.assertEqual(validate.call_args.kwargs, dict(bundle=BUNDLE+'.RommWorker', platform='ios', team=TEAM, certificate=CERT))

    def test_create_only_exact_bundle_and_profile_with_existing_certificate(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(archive_helper, 'run', return_value=b'cms'), \
                patch.object(archive_helper.plistlib, 'loads', return_value={'fixture': True}), \
                patch.object(archive_helper, 'validate_profile', return_value=UUID):
            api = self.api(existing=False)
            archive_helper._worker_profile(api, Path(temporary), CERT, TEAM)
            calls = api.request.call_args_list
            self.assertEqual([call.args[0] for call in calls], ['/v1/bundleIds', '/v1/profiles'])
            self.assertEqual(calls[0].args[1]['data']['attributes']['identifier'], BUNDLE+'.RommWorker')
            data = calls[1].args[1]['data']
            self.assertEqual(data['attributes']['profileType'], 'IOS_APP_STORE')
            self.assertEqual(data['relationships']['certificates']['data'], [{'type':'certificates','id':'cert-id'}])
            self.assertNotIn('devices', data['relationships'])

    def test_wrong_certificate_fails_before_creating_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            api = self.api(existing=False, wrong_certificate=True)
            with self.assertRaisesRegex(ValueError, 'matching the existing'):
                archive_helper._worker_profile(api, Path(temporary), CERT, TEAM)
            api.request.assert_not_called()

    def test_api_rejects_foreign_pagination_and_redacts_errors(self):
        import urllib.error
        api = archive_helper.AppleProfileAPI('fixture-secret-token')
        api.opener = Mock()
        for url in ('https://evil.invalid/v1/profiles', 'http://api.appstoreconnect.apple.com/v1/profiles',
                    'https://api.appstoreconnect.apple.com@evil.invalid/v1/profiles'):
            with self.assertRaises(ValueError): api.request(url)
        api.opener.open.assert_not_called()
        api.opener.open.side_effect = urllib.error.HTTPError('secret-url', 403, 'SECRET BODY', {}, None)
        with self.assertRaisesRegex(RuntimeError, '^Apple provisioning API returned HTTP 403$'):
            api.request('/v1/profiles')
        with patch.object(api, 'request', return_value={'data': [], 'links': {'next': '/v1/profiles'}}):
            with self.assertRaisesRegex(ValueError, 'pagination'):
                api.items('/v1/profiles')

    def test_unsigned_checkpoint_is_attested_and_uploaded_before_store_archive(self):
        workflow = (Path(__file__).resolve().parents[1]/'.github/workflows/build.yml').read_text()
        begin = workflow.index('      - name: Create unsigned developer IPA')
        archive = workflow.index('      - name: Build signed iOS App Store IPA', begin)
        checkpoint = workflow[begin:archive]
        self.assertIn('Attest unsigned developer IPA',checkpoint)
        self.assertIn('name: ios-unsigned-checkpoint',checkpoint)
        self.assertIn('if-no-files-found: error',checkpoint)
        self.assertIn('cp -f pleazyng-ios-unsigned.ipa "$GITHUB_WORKSPACE/"',checkpoint)

    def test_es256_token_signature_verified_with_openssl_and_key_removed(self):
        import base64, io, json, os, subprocess
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            key = subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256'],
                                 check=True, capture_output=True).stdout
            with patch.dict(os.environ, {'APPLE_API_KEY_ID':'FIXTURE123',
                    'APPLE_API_ISSUER_ID':'12345678-1234-1234-1234-123456789012',
                    'APPLE_API_PRIVATE_KEY':key.decode()}), contextlib.redirect_stdout(io.StringIO()) as output:
                token = archive_helper._apple_api_token(stage)
            self.assertFalse((stage/'api-key.p8').exists())
            self.assertIn('::add-mask::'+token, output.getvalue())
            header, payload, raw = token.split('.')
            decode = lambda data: base64.urlsafe_b64decode(data + '='*(-len(data)%4))
            self.assertEqual(json.loads(decode(header))['alg'], 'ES256')
            claims = json.loads(decode(payload))
            self.assertEqual(claims['aud'], 'appstoreconnect-v1')
            self.assertLessEqual(claims['exp']-claims['iat'],1200)
            signature = decode(raw)
            self.assertEqual(len(signature),64)
            def integer(value):
                value = value.lstrip(b'\0') or b'\0'
                if value[0]&0x80: value=b'\0'+value
                return b'\x02'+bytes([len(value)])+value
            pair = integer(signature[:32])+integer(signature[32:])
            (stage/'signature.der').write_bytes(b'\x30'+bytes([len(pair)])+pair)
            (stage/'message').write_text(header+'.'+payload)
            public = subprocess.run(['openssl','pkey','-pubout'], input=key, capture_output=True, check=True).stdout
            (stage/'public.pem').write_bytes(public)
            result = subprocess.run(['openssl','dgst','-sha256','-verify',str(stage/'public.pem'),
                '-signature',str(stage/'signature.der'),str(stage/'message')], capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)

    def test_prepare_does_not_export_invalid_profile_or_host(self):
        import os, plistlib
        from contextlib import contextmanager
        @contextmanager
        def identity(report):
            with tempfile.TemporaryDirectory() as temporary:
                yield Path(temporary), CERT, 'fingerprint', TEAM, Path('/tmp/fixture-keychain')
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'GITHUB_ENV': str(Path(temporary)/'env')}), \
                patch.object(archive_helper, 'signing_identity', identity), \
                patch.object(archive_helper, 'decode_secret', return_value=b'host-profile'), \
                patch.object(archive_helper, 'run', return_value=plistlib.dumps({'fixture':True})), \
                patch.object(archive_helper, 'validate_profile', side_effect=ValueError('Wrong host')):
            with self.assertRaisesRegex(ValueError,'Wrong host'): archive_helper.prepare_ios_worker_profile()
            self.assertFalse((Path(temporary)/'env').exists())


if __name__ == '__main__':
    unittest.main()
