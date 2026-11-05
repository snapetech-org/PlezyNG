import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/credential_vault.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  group('CredentialVault.reveal', () {
    test('bulk encryption does not retain plaintext payloads', () async {
      for (var i = 0; i < 1000; i++) {
        await CredentialVault.protect('channel-$i-secret');
      }
      expect(CredentialVault.payloadCacheForTesting, (entries: 0, bytes: 0, pending: 0));
    });

    test('decryption cache stays bounded and evicted values remain readable', () async {
      final values = <String>[];
      for (var i = 0; i < 300; i++) {
        final value = 'credential-$i-${'x' * 2048}';
        final encrypted = await CredentialVault.protect(value);
        values.add(encrypted);
        expect(await CredentialVault.reveal(encrypted), value);
        expect(CredentialVault.payloadCacheForTesting.entries, lessThanOrEqualTo(128));
        expect(CredentialVault.payloadCacheForTesting.bytes, lessThanOrEqualTo(256 * 1024));
      }
      expect(await CredentialVault.reveal(values.first), 'credential-0-${'x' * 2048}');
      CredentialVault.invalidateCache();
      expect(CredentialVault.payloadCacheForTesting, (entries: 0, bytes: 0, pending: 0));
    });

    test('large encrypted journals are readable without entering the cache', () async {
      final journal = 'j' * (256 * 1024);
      final encrypted = await CredentialVault.protect(journal);
      expect(await CredentialVault.reveal(encrypted), journal);
      expect(CredentialVault.payloadCacheForTesting, (entries: 0, bytes: 0, pending: 0));
    });

    test('round-trips a protected value', () async {
      final protected = await CredentialVault.protect('super-secret');
      expect(protected, startsWith('enc:v2:'));
      expect(await CredentialVault.reveal(protected), 'super-secret');
    });

    test('returns unprotected values unchanged', () async {
      expect(await CredentialVault.reveal('plaintext-token'), 'plaintext-token');
    });

    test('returns null instead of throwing on a tampered MAC', () async {
      final protected = await CredentialVault.protect('super-secret');
      final payload = jsonDecode(protected.substring('enc:v2:'.length)) as Map<String, dynamic>;
      payload['m'] = base64Encode(List<int>.filled(16, 0));
      final tampered = 'enc:v2:${jsonEncode(payload)}';

      expect(await CredentialVault.reveal(tampered), isNull);
    });

    test('returns null instead of throwing on a corrupt payload', () async {
      expect(await CredentialVault.reveal('enc:v1:not-json'), isNull);
      expect(await CredentialVault.reveal('enc:v1:{"n":"!!","c":"!!","m":"!!"}'), isNull);
      expect(await CredentialVault.reveal('enc:v1:{"n":"AAAA"}'), isNull);
    });

    test('returns null when the key diverged from the ciphertext', () async {
      final protected = await CredentialVault.protect('super-secret');

      // Simulate the key being lost/regenerated (cleared prefs, clobbered by
      // another isolate, restored backup) while the ciphertext survived.
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();

      expect(await CredentialVault.reveal(protected), isNull);
    });
  });

  group('CredentialVault.revealConnectionConfig', () {
    test('maps an undecryptable account token to the empty string without migrating', () async {
      final protected = await CredentialVault.protect('tok');
      resetSharedPreferencesForTest();
      CredentialVault.resetKeyForTesting();

      final result = await CredentialVault.revealConnectionConfig('plex', {
        'accountToken': protected,
        'servers': [
          {'accessToken': protected},
        ],
      });

      expect(result.config['accountToken'], '');
      expect((result.config['servers'] as List).single['accessToken'], '');
      expect(result.migrated, isFalse);
    });

    test('still reveals and flags plaintext tokens for migration', () async {
      final result = await CredentialVault.revealConnectionConfig('plex', {
        'accountToken': 'plain-tok',
        'servers': const [],
      });

      expect(result.config['accountToken'], 'plain-tok');
      expect(result.migrated, isTrue);
    });

    test('protects and reveals direct Plex connection accessToken', () async {
      final protected = await CredentialVault.protectConnectionConfig('plex', {
        'baseUrl': 'http://192.168.1.50:32400',
        'accessToken': 'secret-token-456',
      });

      expect(protected['accessToken'], startsWith('enc:v2:'));

      final revealed = await CredentialVault.revealConnectionConfig('plex', protected);
      expect(revealed.config['accessToken'], 'secret-token-456');
    });

    test('normalizes empty token to empty string without encrypting', () async {
      final config = await CredentialVault.protectConnectionConfig('plex', {
        'baseUrl': 'http://192.168.1.50:32400',
        'accessToken': '',
      });

      expect(config['accessToken'], '');
      expect(CredentialVault.isProtected(config['accessToken'] as String), isFalse);

      final revealed = await CredentialVault.revealConnectionConfig('plex', config);
      expect(revealed.config['accessToken'], '');
    });
  });
}
