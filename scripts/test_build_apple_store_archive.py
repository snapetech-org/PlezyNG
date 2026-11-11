#!/usr/bin/env python3
"""Prevent old-bundle, wrong-store and shared-target signing profile reuse."""
import contextlib
from unittest.mock import Mock, patch
from copy import deepcopy
from datetime import datetime, timedelta
import io
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_apple_store_archive as archive_helper
from build_apple_store_archive import (
    BUNDLE, GROUP, MUSIC_NFC_ENTITLEMENT, MUSIC_NFC_FILE, configure_project, music_nfc_allowed, validate_profile,
)
from apple.configure_ios_music_widget import BUNDLE as WIDGET_BUNDLE, TARGET as WIDGET_TARGET, add_music_widget_target, verify_music_widget

TEAM = 'DM9A59DC85'
CERT = b'fixture-distribution-certificate'
UUID = '4fce21b1-451d-4b19-805c-530c11be00e9'


def worker_profile_fixture():
    security = plistlib.loads(archive_helper.WORKER_ENTITLEMENTS.read_bytes())
    return {'UUID': UUID, 'TeamIdentifier': [TEAM], 'DeveloperCertificates': [CERT],
            'Platform': ['iOS'], 'ExpirationDate': datetime.now() + timedelta(days=365),
            'Entitlements': {'application-identifier': f'{TEAM}.{BUNDLE}.RommWorker', **security}}


class WorkerSecurityProfileTests(unittest.TestCase):
    def validate(self, profile):
        return validate_profile(profile, bundle=BUNDLE + '.RommWorker', platform='ios', team=TEAM, certificate=CERT)

    def test_worker_authorizes_every_checked_in_security_requirement_without_host_group(self):
        profile = worker_profile_fixture()
        required, source_hash = archive_helper.worker_security_requirements()
        self.assertEqual(len(required), 7)
        self.assertRegex(source_hash, r'^[0-9a-f]{64}$')
        self.assertNotIn('com.apple.security.application-groups', profile['Entitlements'])
        self.assertEqual(self.validate(profile), UUID)

    def test_every_missing_security_grant_is_rejected(self):
        for key in archive_helper.worker_security_requirements()[0]:
            with self.subTest(entitlement=key):
                profile = worker_profile_fixture()
                del profile['Entitlements'][key]
                with self.assertRaisesRegex(ValueError, 'required Enhanced Security entitlement'):
                    self.validate(profile)

    def test_boolean_security_grants_require_true_without_coercion(self):
        for key, requested in archive_helper.worker_security_requirements()[0].items():
            if requested is not True:
                continue
            for grant in (False, 1, 'true', '*'):
                with self.subTest(entitlement=key, grant=grant):
                    profile = worker_profile_fixture()
                    profile['Entitlements'][key] = grant
                    with self.assertRaises(ValueError):
                        self.validate(profile)

    def test_string_security_grants_accept_exact_or_full_profile_wildcard(self):
        for key, requested in archive_helper.worker_security_requirements()[0].items():
            if not isinstance(requested, str):
                continue
            profile = worker_profile_fixture()
            profile['Entitlements'][key] = '*'
            self.assertEqual(self.validate(profile), UUID)
            for grant in ('unexpected', '', int(requested), True, requested + '*'):
                with self.subTest(entitlement=key, grant=grant):
                    profile = worker_profile_fixture()
                    profile['Entitlements'][key] = grant
                    with self.assertRaises(ValueError):
                        self.validate(profile)


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

    def test_bundle_case_is_insensitive_but_team_namespace_and_full_bundle_remain_exact(self):
        profile = self.profile()
        profile['Entitlements']['application-identifier'] = TEAM + '.' + BUNDLE.upper()
        self.assertEqual(validate_profile(profile, bundle=BUNDLE, platform='ios', team=TEAM, certificate=CERT), UUID)
        for identifier in (TEAM.lower() + '.' + BUNDLE, TEAM + '.' + BUNDLE + '.extra',
                           TEAM + '.org.snapetech.*', TEAM + '.' + BUNDLE.replace('s', '\u017f')):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                profile['Entitlements']['application-identifier'] = identifier
                validate_profile(profile, bundle=BUNDLE, platform='ios', team=TEAM, certificate=CERT)

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

    def test_nfc_requires_explicit_tag_capability_without_replacing_other_entitlements(self):
        profile = self.profile()
        self.assertFalse(music_nfc_allowed(profile, 'ios'))
        profile['Entitlements'][MUSIC_NFC_ENTITLEMENT] = ['NDEF']
        self.assertFalse(music_nfc_allowed(profile, 'ios'))
        profile['Entitlements'][MUSIC_NFC_ENTITLEMENT] = ['TAG']
        self.assertTrue(music_nfc_allowed(profile, 'ios'))
        self.assertFalse(music_nfc_allowed(profile, 'tvos'))
        settings = {}
        project = {'rootObject': 'root', 'objects': {
            'root': {'targets': ['app']},
            'app': {'isa': 'PBXNativeTarget', 'name': 'Runner', 'buildConfigurationList': 'configs'},
            'configs': {'buildConfigurations': ['release']},
            'release': {'name': 'Release', 'buildSettings': settings},
        }}
        binding = {'Runner': {'bundle': BUNDLE, 'uuid': UUID, 'music_nfc': False}}
        configure_project(project, binding, TEAM, 'fixture', Path('/tmp/keychain'))
        self.assertNotIn('CODE_SIGN_ENTITLEMENTS', settings)
        self.assertNotIn('PLEAZYNG_MUSIC_NFC_ENABLED', settings)
        binding['Runner']['music_nfc'] = True
        configure_project(project, binding, TEAM, 'fixture', Path('/tmp/keychain'))
        self.assertEqual(settings['CODE_SIGN_ENTITLEMENTS'], MUSIC_NFC_FILE)
        self.assertEqual(settings.pop('PLEAZYNG_MUSIC_NFC_ENABLED'), 'YES')
        settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Custom.entitlements'
        configure_project(project, binding, TEAM, 'fixture', Path('/tmp/keychain'))
        self.assertEqual(settings['CODE_SIGN_ENTITLEMENTS'], 'Runner/Custom.entitlements')
        self.assertNotIn('PLEAZYNG_MUSIC_NFC_ENABLED', settings)

    def test_widget_build_embeds_a_distinct_profile_without_changing_debug_or_dropping_nfc(self):
        project = {'rootObject': 'root', 'objects': {
            'root': {'targets': ['app'], 'mainGroup': 'sources', 'productRefGroup': 'products'},
            'sources': {'children': []}, 'products': {'children': []},
            'app': {'isa': 'PBXNativeTarget', 'name': 'Runner', 'buildConfigurationList': 'configs',
                    'buildPhases': ['compile', 'thin', 'pods'], 'dependencies': []},
            'configs': {'buildConfigurations': ['release', 'debug']},
            'release': {'name': 'Release', 'buildSettings': {'OTHER_LDFLAGS': ['$(inherited)', '-lc++']}},
            'debug': {'name': 'Debug', 'buildSettings': {'KEEP': 'debug'}},
            'compile': {'isa': 'PBXSourcesBuildPhase'}, 'thin': {'name': 'Thin Binary'},
            'pods': {'name': '[CP] Embed Pods Frameworks'},
            'snapshot': {'isa': 'PBXFileReference', 'path': 'MusicWidget/MusicWidgetSnapshot.swift'},
            'intent': {'isa': 'PBXFileReference', 'path': 'MusicWidget/MusicWidgetTransportIntent.swift'},
        }}
        objects = project['objects']
        add_music_widget_target(project)
        widget_id = objects['root']['targets'][-1]
        widget = objects[widget_id]
        self.assertEqual(widget['name'], WIDGET_TARGET)
        self.assertEqual(widget['productType'], 'com.apple.product-type.app-extension')
        self.assertEqual(objects[objects['app']['dependencies'][0]]['target'], widget_id)
        phases = objects['app']['buildPhases']
        self.assertEqual(phases[2:], ['thin', 'pods'])
        embed = objects[phases[1]]
        self.assertEqual(embed['dstSubfolderSpec'], '13')
        self.assertEqual(objects[embed['files'][0]]['fileRef'], widget['productReference'])
        self.assertEqual(len(objects[widget['buildPhases'][0]]['files']), 3)
        with self.assertRaises(ValueError):
            add_music_widget_target(project)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'entitlements.plist'
            configure_project(project, {
                'Runner': {'bundle': BUNDLE, 'uuid': UUID, 'music_nfc': True},
                WIDGET_TARGET: {'bundle': WIDGET_BUNDLE, 'uuid': 'widget-profile'},
            }, TEAM, 'fixture', Path(temporary) / 'keychain', widget_host_entitlements=path)
            entitlements = plistlib.loads(path.read_bytes())
            self.assertEqual(entitlements['com.apple.security.application-groups'], [GROUP])
            self.assertEqual(entitlements[MUSIC_NFC_ENTITLEMENT], ['TAG'])
        release = objects['release']['buildSettings']
        self.assertEqual(release['OTHER_LDFLAGS'], ['$(inherited)', '-lc++', '-weak_framework', 'AppIntents'])
        self.assertIn('PLEAZYNG_MUSIC_WIDGET_HOST', release['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
        self.assertEqual(objects['debug']['buildSettings'], {'KEEP': 'debug'})
        config = next(objects[key] for key in objects[widget['buildConfigurationList']]['buildConfigurations']
                      if objects[key]['name'] == 'Release')['buildSettings']
        self.assertEqual(config['PROVISIONING_PROFILE_SPECIFIER'], 'widget-profile')
        self.assertEqual(config['CODE_SIGN_ENTITLEMENTS'], 'MusicWidget/MusicWidget.entitlements')
        self.assertEqual(config['PRODUCT_BUNDLE_IDENTIFIER'], WIDGET_BUNDLE)

    def test_widget_export_requires_the_expected_extension_bundle(self):
        for bundle, valid in ((WIDGET_BUNDLE, True), (BUNDLE, False), (None, False)):
            with self.subTest(bundle=bundle):
                package = io.BytesIO()
                with zipfile.ZipFile(package, 'w') as output:
                    output.writestr('Payload/Pleazyng.app/Info.plist', plistlib.dumps({'CFBundleIdentifier': BUNDLE}))
                    if bundle:
                        output.writestr(f'Payload/Pleazyng.app/PlugIns/{WIDGET_TARGET}.appex/Info.plist',
                                        plistlib.dumps({'CFBundleIdentifier': bundle}))
                if valid:
                    verify_music_widget(package)
                else:
                    with self.assertRaises(ValueError):
                        verify_music_widget(package)


class AppleProfileBootstrapTests(unittest.TestCase):
    def api(self, *, existing=True, wrong_certificate=False, platform='IOS', identifier=None):
        import base64
        worker = {'type': 'bundleIds', 'id': 'worker-id', 'attributes': {
            'identifier': identifier or BUNDLE + '.RommWorker', 'platform': platform}}
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

    def test_profile_missing_security_is_skipped_and_fresh_authorized_profile_selected(self):
        old = worker_profile_fixture()
        del old['Entitlements']['com.apple.security.hardened-process']
        good = worker_profile_fixture()
        with tempfile.TemporaryDirectory() as temporary, patch.object(archive_helper, 'run',
                side_effect=[plistlib.dumps(old), plistlib.dumps(good)]):
            api = self.api()
            self.assertEqual(archive_helper._worker_profile(api, Path(temporary), CERT, TEAM), (b'fixture-profile', UUID))
            self.assertEqual([call.args[0] for call in api.request.call_args_list], ['/v1/profiles'])
            body = api.request.call_args.args[1]['data']['relationships']
            self.assertEqual(body['bundleId']['data']['id'], 'worker-id')
            self.assertEqual(body['certificates']['data'], [{'type': 'certificates', 'id': 'cert-id'}])

    def test_fresh_profile_still_missing_security_is_rejected_without_repeated_creation(self):
        bad = worker_profile_fixture()
        del bad['Entitlements']['com.apple.security.hardened-process']
        with tempfile.TemporaryDirectory() as temporary, patch.object(archive_helper, 'run', return_value=plistlib.dumps(bad)):
            api = self.api()
            with self.assertRaisesRegex(ValueError, 'required Enhanced Security entitlement'):
                archive_helper._worker_profile(api, Path(temporary), CERT, TEAM)
            self.assertEqual([call.args[0] for call in api.request.call_args_list], ['/v1/profiles'])

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

    def test_universal_and_case_normalized_worker_reused_without_new_registration(self):
        for platform in ('IOS', 'UNIVERSAL'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary, \
                    patch.object(archive_helper, 'run', return_value=b'cms'), \
                    patch.object(archive_helper.plistlib, 'loads', return_value={'fixture': True}), \
                    patch.object(archive_helper, 'validate_profile', return_value=UUID):
                api = self.api(platform=platform, identifier=(BUNDLE + '.RommWorker').lower())
                report = {}
                self.assertEqual(archive_helper._worker_profile(api, Path(temporary), CERT, TEAM, report), (b'fixture-profile', UUID))
                api.request.assert_not_called()
                self.assertEqual(report['worker_registration']['resource_platform'], platform)
                self.assertFalse(report['worker_registration']['identifier_case_matches'])
                self.assertNotIn('fixture-profile', str(report))

    def test_new_ios_registration_can_return_universal_resource(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(archive_helper, 'run', return_value=b'cms'), \
                patch.object(archive_helper.plistlib, 'loads', return_value={'fixture': True}), \
                patch.object(archive_helper, 'validate_profile', return_value=UUID):
            api = self.api(existing=False, platform='UNIVERSAL')
            archive_helper._worker_profile(api, Path(temporary), CERT, TEAM)
            self.assertEqual(api.request.call_args_list[0].args[1]['data']['attributes']['platform'], 'IOS')
            self.assertEqual(api.request.call_args_list[1].args[1]['data']['attributes']['profileType'], 'IOS_APP_STORE')

    def test_case_preserving_api_filter_does_not_create_duplicate_registration(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(archive_helper, 'run', return_value=b'cms'), \
                patch.object(archive_helper.plistlib, 'loads', return_value={'fixture': True}), \
                patch.object(archive_helper, 'validate_profile', return_value=UUID):
            api = self.api(identifier=(BUNDLE + '.RommWorker').lower())
            original = api.items.side_effect
            def items(path):
                if path.startswith('/v1/bundleIds?'):
                    query = archive_helper.urllib.parse.parse_qs(path.split('?', 1)[1])
                    if query['filter[identifier]'] == [BUNDLE + '.RommWorker']:
                        return []
                return original(path)
            api.items.side_effect = items
            archive_helper._worker_profile(api, Path(temporary), CERT, TEAM)
            api.request.assert_not_called()

    def test_public_bootstrap_report_excludes_profiles_and_does_not_claim_app_build(self):
        for failure in (False, True):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                stage = Path(temporary)
                environment, report = stage / 'job-env', stage / 'public.json'
                identity = contextlib.nullcontext((stage, CERT, 'fingerprint', TEAM, stage / 'keychain'))
                with patch.dict(archive_helper.os.environ, {'GITHUB_ENV': str(environment)}), \
                        patch.object(archive_helper, 'signing_identity', return_value=identity), \
                        patch.object(archive_helper, 'decode_secret', return_value=b'runner-private-profile'), \
                        patch.object(archive_helper, 'run', return_value=b'cms'), \
                        patch.object(archive_helper.plistlib, 'loads', return_value={}), \
                        patch.object(archive_helper, 'worker_security_requirements',
                                     return_value=({'com.apple.security.hardened-process': True}, 'f' * 64)), \
                        patch.object(archive_helper, 'validate_profile', return_value=UUID), \
                        patch.object(archive_helper, '_apple_api_token', return_value='fixture-private-token'), \
                        patch.object(archive_helper, '_worker_profile', side_effect=ValueError('fixture-private-error') if failure else None,
                                     return_value=(b'worker-private-profile', UUID)), \
                        contextlib.redirect_stdout(io.StringIO()):
                    if failure:
                        with self.assertRaises(ValueError):
                            archive_helper.prepare_ios_worker_profile(report)
                    else:
                        archive_helper.prepare_ios_worker_profile(report)
                content = report.read_text()
                data = archive_helper.json.loads(content)
                self.assertEqual(data['profile_bootstrap_qualified'], not failure)
                self.assertEqual(data['worker_security_qualified'], not failure)
                self.assertFalse(data['app_build_qualified'])
                for secret in ('runner-private-profile', 'worker-private-profile',
                               'fixture-private-token', 'fixture-private-error'):
                    self.assertNotIn(secret, content)
                self.assertEqual(environment.exists(), not failure)

    def test_mac_only_or_ambiguous_worker_registration_never_creates_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            api = self.api(platform='MAC_OS')
            with self.assertRaisesRegex(ValueError, 'iOS-capable'):
                archive_helper._worker_profile(api, Path(temporary), CERT, TEAM)
            api.request.assert_not_called()
            api = self.api()
            original = api.items.side_effect
            api.items.side_effect = lambda path: original(path) * 2 if path.startswith('/v1/bundleIds?') else original(path)
            with self.assertRaisesRegex(ValueError, 'iOS-capable'):
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
