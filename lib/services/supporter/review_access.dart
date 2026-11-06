import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// A disclosed Android store-review grant, separate from store ownership.
/// Only the public verification key ships in the app. Apple builds deliberately
/// exclude this alternative unlock mechanism and use StoreKit review purchases.
class ReviewAccess {
  static const publicKey = String.fromEnvironment('REVIEW_ACCESS_PUBLIC_KEY');

  static bool supportedFor(String key) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android && key.isNotEmpty;

  static Future<DateTime?> verify(String token, {String verificationKey = publicKey, DateTime? now}) async {
    if (token.length > 4096 || verificationKey.isEmpty) return null;
    try {
      final parts = token.trim().split('.');
      if (parts.length != 2) return null;
      final message = base64Url.decode(base64Url.normalize(parts[0]));
      final signature = base64Url.decode(base64Url.normalize(parts[1]));
      final key = base64Url.decode(base64Url.normalize(verificationKey));
      if (key.length != 32 || signature.length != 64) return null;
      if (!await Ed25519().verify(
        message,
        signature: Signature(signature, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
      )) {
        return null;
      }
      final payload = jsonDecode(utf8.decode(message));
      if (payload is! Map<String, dynamic> ||
          payload['purpose'] != 'store-review' ||
          payload['package'] != 'org.snapetech.pleazyng' ||
          payload['expires'] is! int) {
        return null;
      }
      final expiry = DateTime.fromMillisecondsSinceEpoch((payload['expires'] as int) * 1000, isUtc: true);
      return expiry.isAfter((now ?? DateTime.now()).toUtc()) ? expiry : null;
    } catch (_) {
      return null;
    }
  }
}
