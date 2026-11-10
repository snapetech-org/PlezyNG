#!/usr/bin/env python3
"""Prevent old-bundle, wrong-store and shared-target signing profile reuse."""
from copy import deepcopy
from datetime import datetime, timedelta
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_apple_store_archive import (
    BUNDLE, GROUP, MUSIC_NFC_ENTITLEMENT, MUSIC_NFC_FILE, configure_project, music_nfc_allowed, validate_profile,
)

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


if __name__ == '__main__':
    unittest.main()
