import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/supporter/supporter_mode.dart';
import 'package:plezy/services/supporter/supporter_service.dart';

import '../../test_helpers/prefs.dart';

void main() {
  late String verificationKey;
  late String token;
  String encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  setUp(() async {
    resetSharedPreferencesForTest();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final pair = await Ed25519().newKeyPair();
    verificationKey = encode((await pair.extractPublicKey()).bytes);
    final message = utf8.encode(
      jsonEncode({
        'purpose': 'store-review',
        'package': 'org.snapetech.pleazyng',
        'expires': DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch ~/ 1000,
      }),
    );
    token = '${encode(message)}.${encode((await Ed25519().sign(message, keyPair: pair)).bytes)}';
    final settings = await SettingsService.getInstance();
    await settings.write(
      SettingsService.appAccessTrialStartedAtEpochMs,
      DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch,
    );
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  SupporterService create() {
    final service = SupporterService.forTesting(
      availability: SupporterAvailability.purchasable,
      reviewVerificationKey: verificationKey,
    );
    addTearDown(service.dispose);
    return service;
  }

  test('review grant restores full access after expired trial without recording purchase', () async {
    final service = create();
    await service.init();
    expect(service.hasAccess, isFalse);
    expect(await service.redeemReviewAccess(token), isTrue);
    expect(service.hasAccess, isTrue);
    expect(service.isUnlocked, isTrue);
    expect(service.hasLifetimeUnlock, isFalse);
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.supporterEntitlementCached), isFalse);
    expect(service.isTrialActive, isFalse);
    final restarted = create();
    await restarted.init();
    expect(restarted.hasReviewAccess, isTrue);
  });

  test('rejects tampering without overwriting a valid saved grant', () async {
    final service = create();
    expect(await service.redeemReviewAccess(token), isTrue);
    expect(await service.redeemReviewAccess('invalid'), isFalse);
    expect((await SettingsService.getInstance()).read(SettingsService.storeReviewAccessGrant), token);
  });

  test('Apple cannot redeem or load an Android review grant', () async {
    await (await SettingsService.getInstance()).write(SettingsService.storeReviewAccessGrant, token);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final service = create();
    await service.init();
    expect(service.supportsReviewAccess, isFalse);
    expect(await service.redeemReviewAccess(token), isFalse);
    expect(service.hasAccess, isFalse);
  });
}
