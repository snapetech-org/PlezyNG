import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:cryptography/cryptography.dart';

const _channel = MethodChannel('webos_plugin');

class Lock {
  Future<void> _chain = Future.value();

  Future<T> synchronized<T>(Future<T> Function() fn) {
    final Future<T> result = _chain.then((_) => fn());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// OS failures are errors, never an empty value or evidence of a missing key.
class SecureStorageClient {
  final Lock _lock = Lock();
  static final Random _random = Random.secure();

  Future<String> encrypt(String key, String value) => _crypt(key, value, encrypting: true);
  Future<String> decrypt(String key, String value) => _crypt(key, value, encrypting: false);

  Future<String> _crypt(String key, String value, {required bool encrypting}) {
    return _lock.synchronized(() async {
      if (!encrypting && value.length <= 24) throw _corrupt();
      final iv = encrypting ? null : value.substring(0, 24);
      final begin = await _channel.invokeMapMethod<String, dynamic>(
          'keymanager/begin', _header(key, [encrypting ? 'encrypt' : 'decrypt'], iv: iv));
      if (begin?['returnValue'] != true) throw _unavailable();
      final handle = begin?['handle'];
      if (handle is! String || handle.isEmpty) throw _unavailable();
      try {
        final outputIv = encrypting ? (begin?['iv']) : iv;
        if (outputIv is! String || outputIv.length != 24 || base64Decode(outputIv).length != 16) {
          throw _corrupt();
        }
        final reply = await _channel.invokeMapMethod<String, dynamic>('keymanager/finish', {
          'handle': handle,
          'data': encrypting ? base64Encode(utf8.encode(value)) : value.substring(24),
        });
        final output = reply?['output'];
        if (reply?['returnValue'] != true || output is! String || output.isEmpty) throw _unavailable();
        return encrypting ? outputIv + output : utf8.decode(base64Decode(output));
      } on FormatException {
        throw _corrupt();
      } finally {
        // A completed handle may already be closed. Cleanup must not hide the
        // original error or turn a successfully encrypted value into a failure.
        try {
          await _channel.invokeMethod<bool>('keymanager/abort', {'handle': handle});
        } catch (_) {}
      }
    });
  }

  /// Stage an independent key/envelope. Never replace a key backing a saved row.
  Future<String> createSecret(String value, {required String context}) async {
    final key = 'fss_${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final generated = await _channel.invokeMethod<bool>('keymanager/generateKey', _header(key, ['encrypt', 'decrypt']));
    if (generated != true) throw _unavailable();
    try {
      final algorithm = AesGcm.with256bits();
      final dataKey = await algorithm.newSecretKey();
      final box = await algorithm.encrypt(utf8.encode(value), secretKey: dataKey, aad: _aad(context, key));
      // webOS keymanager exposes CBC. Use it only to wrap a random data key;
      // plaintext is released only after the independent GCM tag verifies.
      final wrapped =
          await encrypt(key, jsonEncode({'context': context, 'key': base64Encode(await dataKey.extractBytes())}));
      final payload = base64Encode(utf8.encode(jsonEncode({
        'wrapped': wrapped,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'tag': base64Encode(box.mac.bytes),
      })));
      return 'v3:$key:$payload';
    } catch (_) {
      await removeKeyBestEffort(key);
      rethrow;
    }
  }

  List<int> _aad(String context, String key) => utf8.encode(jsonEncode(['webos-secure-storage-v3', context, key]));

  Future<String> readSecret(String legacyKey, String envelope) async {
    final key = secretKey(legacyKey, envelope);
    if (!envelope.startsWith('v3:')) return decrypt(key, _ciphertext(envelope));
    try {
      if (envelope.length > 8 * 1024 * 1024) throw _corrupt();
      final payload = jsonDecode(utf8.decode(base64Decode(envelope.split(':').last))) as Map<String, dynamic>;
      final wrapped = jsonDecode(await decrypt(key, payload['wrapped'] as String)) as Map<String, dynamic>;
      if (wrapped['context'] != legacyKey) throw _corrupt();
      final keyBytes = base64Decode(wrapped['key'] as String);
      final nonce = base64Decode(payload['nonce'] as String);
      final tag = base64Decode(payload['tag'] as String);
      if (keyBytes.length != 32 || nonce.length != 12 || tag.length != 16) throw _corrupt();
      final box = SecretBox(base64Decode(payload['ciphertext'] as String), nonce: nonce, mac: Mac(tag));
      final plain = await AesGcm.with256bits().decrypt(box, secretKey: SecretKey(keyBytes), aad: _aad(legacyKey, key));
      return utf8.decode(plain);
    } on PlatformException {
      rethrow;
    } catch (_) {
      throw _corrupt();
    }
  }

  String secretKey(String legacyKey, String envelope) {
    if (!envelope.contains(':')) return legacyKey;
    final parts = envelope.split(':');
    if (parts.length != 3 ||
        !const {'v2', 'v3'}.contains(parts[0]) ||
        !RegExp(r'^fss_[0-9a-f]{32}$').hasMatch(parts[1]) ||
        parts[2].isEmpty) {
      throw _corrupt();
    }
    return parts[1];
  }

  String _ciphertext(String envelope) => envelope.startsWith('v2:') ? envelope.split(':').last : envelope;

  Future<void> removeSecretBestEffort(String legacyKey, String envelope) async {
    try {
      await removeKeyBestEffort(secretKey(legacyKey, envelope));
    } catch (_) {}
  }

  Future<void> removeKeyBestEffort(String key) async {
    // Cleanup is only called for uncommitted staging keys or superseded keys
    // after a successful durable row replacement. Failure leaves an orphan,
    // never a broken active credential.
    try {
      await _channel.invokeMethod<bool>('keymanager/removeKey', {'name': key});
    } catch (_) {}
  }

  Map<String, dynamic> _header(String key, List<String> purpose, {String? iv}) => {
        'name': key,
        'params': {
          'type': 'AES',
          'size': '256',
          'mode': ['CBC'],
          'purpose': purpose,
          'padding': ['PKCS7'],
          if (iv != null) 'iv': iv
        },
      };

  PlatformException _unavailable() => PlatformException(
      code: 'secure_storage_unavailable', message: 'The key service is unavailable. Retry the operation.');
  PlatformException _corrupt() =>
      PlatformException(code: 'secure_storage_corrupt', message: 'The saved credential could not be decoded.');
}
