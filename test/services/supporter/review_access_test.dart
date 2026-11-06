import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/supporter/review_access.dart';

void main() {
  final now = DateTime.utc(2026, 11, 6);
  late SimpleKeyPair key;
  late String publicKey;

  String encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  Future<String> grant({
    String purpose = 'store-review',
    String package = 'org.snapetech.pleazyng',
    DateTime? expiry,
  }) async {
    final message = utf8.encode(
      jsonEncode({
        'purpose': purpose,
        'package': package,
        'expires': (expiry ?? now.add(const Duration(days: 365))).millisecondsSinceEpoch ~/ 1000,
      }),
    );
    final signature = await Ed25519().sign(message, keyPair: key);
    return '${encode(message)}.${encode(signature.bytes)}';
  }

  setUp(() async {
    key = await Ed25519().newKeyPair();
    publicKey = encode((await key.extractPublicKey()).bytes);
  });

  test('accepts signed full-feature review access independently of trial length', () async {
    final expiry = now.add(const Duration(days: 365));
    expect(await ReviewAccess.verify(await grant(), verificationKey: publicKey, now: now), expiry);
  });

  test('rejects expired grants including exact expiry', () async {
    expect(
      await ReviewAccess.verify(
        await grant(expiry: now),
        verificationKey: publicKey,
        now: now,
      ),
      isNull,
    );
  });

  test('rejects a different application or purpose', () async {
    expect(
      await ReviewAccess.verify(
        await grant(package: 'org.other.app'),
        verificationKey: publicKey,
        now: now,
      ),
      isNull,
    );
    expect(
      await ReviewAccess.verify(
        await grant(purpose: 'purchase'),
        verificationKey: publicKey,
        now: now,
      ),
      isNull,
    );
  });

  test('rejects forged signature and substituted payload', () async {
    final token = await grant();
    final parts = token.split('.');
    final other = (await grant(expiry: now.add(const Duration(days: 730)))).split('.');
    expect(await ReviewAccess.verify('${other[0]}.${parts[1]}', verificationKey: publicKey, now: now), isNull);
    final foreignKey = await Ed25519().newKeyPair();
    final foreignPublic = encode((await foreignKey.extractPublicKey()).bytes);
    expect(await ReviewAccess.verify(token, verificationKey: foreignPublic, now: now), isNull);
  });

  test('malformed or oversized codes fail closed', () async {
    for (final token in ['', 'x.y', 'a.b.c', List.filled(4097, 'x').join()]) {
      expect(await ReviewAccess.verify(token, verificationKey: publicKey, now: now), isNull);
    }
    expect(await ReviewAccess.verify(await grant(), verificationKey: ''), isNull);
  });
}
