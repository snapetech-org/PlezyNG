import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_webos/flutter_secure_storage_webos.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/credential_key_store.dart';

const _options = <String, String>{};
const _index = 'flutter_secure_storage';
const _iv = 'AAAAAAAAAAAAAAAAAAAAAA==';

/// Bind dummy ciphertext to its key so premature key deletion/replacement is
/// observable. OS cryptography is outside this fault-injection test's scope.
class _Backend {
  final keys = <String>{_index, 'vault'};
  final handles = <String, ({String key, bool encrypting})>{};
  final removed = <String>[];
  Map<String, String?> row = {};
  String? unavailableKey;
  bool generationFails = false;
  bool valueEncryptionFails = false;
  bool indexEncryptionFails = false;
  bool storeFails = false;
  bool loadFails = false;
  bool cleanupFails = false;
  bool loseAcknowledgement = false;
  bool conflictOnce = false;
  int stores = 0;
  int generations = 0;
  int serial = 0;

  _Backend() {
    seed({'vault': 'ORIGINAL_DUMMY_KEY'});
  }
  String encrypted(String key, String plain) =>
      _iv + base64Encode(utf8.encode(jsonEncode({'key': key, 'data': base64Encode(utf8.encode(plain))})));
  void seed(Map<String, String> entries) {
    keys.addAll(entries.keys);
    row = {
      'keys': encrypted(_index, jsonEncode(entries.keys.toList())),
      'datas': jsonEncode([for (final entry in entries.entries) encrypted(entry.key, entry.value)]),
    };
  }

  Future<Object?> storage(MethodCall call) async {
    if (call.method == 'load') {
      if (loadFails) throw PlatformException(code: 'io');
      return Map<String, String?>.from(row);
    }
    expect(call.method, 'compareAndStore', reason: 'all writes must compare the expected persisted row');
    stores++;
    if (storeFails) throw PlatformException(code: 'io');
    final args = Map<String, Object?>.from(call.arguments as Map);
    if (conflictOnce) {
      conflictOnce = false;
      seed({'vault': 'ORIGINAL_DUMMY_KEY', 'other-isolate': 'OTHER_DUMMY_KEY'});
    }
    if (row['keys'] != args['expectedKeys'] || row['datas'] != args['expectedDatas']) return false;
    // Both currently referenced legacy keys must survive until the commit.
    if ((row['keys'] ?? '').startsWith(_iv)) expect(keys, contains(_index));
    row = {'keys': args['keys'] as String, 'datas': args['datas'] as String};
    if (loseAcknowledgement) throw PlatformException(code: 'io');
    return true;
  }

  Future<Object?> service(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final key = args['name'] as String?;
    switch (call.method) {
      case 'keymanager/generateKey':
        generations++;
        if (generationFails) return false;
        expect(keys, isNot(contains(key)), reason: 'never regenerate a key backing saved ciphertext');
        keys.add(key!);
        return true;
      case 'keymanager/removeKey':
        if (cleanupFails) throw PlatformException(code: 'unavailable');
        removed.add(key!);
        keys.remove(key);
        return true;
      case 'keymanager/begin':
        if (!keys.contains(key) || key == unavailableKey) return {'returnValue': false};
        final params = Map<String, Object?>.from(args['params'] as Map);
        final id = '${serial++}';
        handles[id] = (key: key!, encrypting: (params['purpose'] as List).contains('encrypt'));
        return {'returnValue': true, 'iv': _iv, 'handle': id};
      case 'keymanager/finish':
        final handle = handles[args['handle']]!;
        if (!keys.contains(handle.key)) return {'returnValue': false};
        if (handle.encrypting) {
          final plain = utf8.decode(base64Decode(args['data'] as String));
          final isIndex =
              plain.startsWith('[') || (plain.startsWith('{') && (jsonDecode(plain) as Map)['context'] == _index);
          if ((isIndex && indexEncryptionFails) || (!isIndex && valueEncryptionFails)) return {'returnValue': false};
          return {'returnValue': true, 'output': encrypted(handle.key, plain).substring(24)};
        }
        final decoded = jsonDecode(utf8.decode(base64Decode(args['data'] as String))) as Map;
        if (decoded['key'] != handle.key) return {'returnValue': false};
        return {'returnValue': true, 'output': decoded['data']};
      case 'keymanager/abort':
        handles.remove(args['handle']);
        return true;
    }
    throw StateError(call.method);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Backend backend;
  late FlutterSecureStorageWebos storage;
  Future<String?> read([String key = 'vault']) => storage.read(key: key, options: _options);
  Future<void> write(String value, [String key = 'vault']) => storage.write(key: key, value: value, options: _options);
  final unavailable = isA<PlatformException>().having((e) => e.code, 'code', 'secure_storage_unavailable');

  setUp(() {
    backend = _Backend();
    storage = FlutterSecureStorageWebos();
    messenger.setMockMethodCallHandler(const MethodChannel('webos/secure_storage'), backend.storage);
    messenger.setMockMethodCallHandler(const MethodChannel('webos_plugin'), backend.service);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(const MethodChannel('webos/secure_storage'), null);
    messenger.setMockMethodCallHandler(const MethodChannel('webos_plugin'), null);
  });

  for (final location in ['keys', 'datas']) {
    for (final field in ['ciphertext', 'tag', 'nonce', 'wrapped']) {
      test('authenticated $location envelope rejects changed $field without rewriting storage', () async {
        await write('SECRET');
        final saved = Map<String, String?>.of(backend.row);
        final values = (jsonDecode(backend.row['datas']!) as List).cast<String>();
        final parts = (location == 'keys' ? backend.row['keys']! : values.single).split(':');
        final payload = jsonDecode(utf8.decode(base64Decode(parts[2]))) as Map<String, dynamic>;
        if (field == 'wrapped') {
          // Changing the OS-wrapped key must never expose unauthenticated data.
          payload[field] = '${payload[field]}!';
        } else {
          final bytes = base64Decode(payload[field] as String);
          bytes[0] ^= 1;
          payload[field] = base64Encode(bytes);
        }
        final changed = '${parts[0]}:${parts[1]}:${base64Encode(utf8.encode(jsonEncode(payload)))}';
        if (location == 'keys') {
          backend.row['keys'] = changed;
        } else {
          values[0] = changed;
          backend.row['datas'] = jsonEncode(values);
        }
        final stores = backend.stores;
        await expectLater(read(), throwsA(isA<PlatformException>()));
        expect(backend.stores, stores);
        backend.row = saved;
        expect(await read(), 'SECRET');
      });
    }
  }

  test('AEAD keys cannot be reinterpreted as legacy CBC keys', () async {
    await write('SECRET');
    final saved = Map<String, String?>.of(backend.row);
    final parts = backend.row['keys']!.split(':');
    final payload = jsonDecode(utf8.decode(base64Decode(parts[2]))) as Map<String, dynamic>;
    // An attacker must not be able to bypass the GCM tag by selecting v2
    // decryption for the random data key's CBC wrapping envelope.
    backend.row['keys'] = 'v2:${parts[1]}:${payload['wrapped']}';
    await expectLater(read(), throwsA(isA<PlatformException>()));
    backend.row = saved;
    expect(await read(), 'SECRET');
  });

  test('wrapped-key and authentication failures expose the same error', () async {
    await write('SECRET');
    final saved = Map<String, String?>.of(backend.row);
    final parts = backend.row['keys']!.split(':');
    Future<List<String?>> failure() async {
      try {
        await read();
        fail('The modified credential must be rejected');
      } on PlatformException catch (error) {
        return [error.code, error.message];
      }
    }

    backend.unavailableKey = parts[1];
    final unavailableError = await failure();
    backend.unavailableKey = null;
    for (final field in ['wrapped', 'tag']) {
      final payload = jsonDecode(utf8.decode(base64Decode(parts[2]))) as Map<String, dynamic>;
      if (field == 'wrapped') {
        payload[field] = '${payload[field]}!';
      } else {
        final tag = base64Decode(payload[field] as String);
        tag[0] ^= 1;
        payload[field] = base64Encode(tag);
      }
      backend.row['keys'] = '${parts[0]}:${parts[1]}:${base64Encode(utf8.encode(jsonEncode(payload)))}';
      expect(await failure(), unavailableError);
    }
    backend.row = saved;
    expect(await read(), 'SECRET');
  });

  for (final fixture in {'ASCII': 'x' * (4 * 1024 * 1024 + 1), 'UTF-8': 'é' * (2 * 1024 * 1024 + 1)}.entries) {
    test('oversized ${fixture.key} credential preserves saved storage', () async {
      final saved = Map<String, String?>.of(backend.row);
      await expectLater(write(fixture.value), throwsA(isA<PlatformException>()));
      expect(backend.generations, 0);
      expect(backend.stores, 0);
      expect(backend.row, saved);
      expect(await read(), 'ORIGINAL_DUMMY_KEY');
    });
  }

  test('oversized logical key is rejected before key allocation or storage mutation', () async {
    final saved = Map<String, String?>.of(backend.row);
    await expectLater(write('SECRET', 'é' * 513), throwsA(isA<PlatformException>()));
    expect(backend.generations, 0);
    expect(backend.stores, 0);
    expect(backend.row, saved);
  });

  test('authenticated credentials cannot be moved to another logical key', () async {
    await write('FIRST', 'vault');
    await write('SECOND', 'other');
    final saved = Map<String, String?>.of(backend.row);
    final values = jsonDecode(backend.row['datas']!) as List;
    backend.row['datas'] = jsonEncode(values.reversed.toList());
    await expectLater(read(), throwsA(isA<PlatformException>()));
    backend.row = saved;
    expect(await read(), 'FIRST');
    expect(await read('other'), 'SECOND');
  });

  test('version-two envelopes remain readable and upgrade on the next write', () async {
    const key = 'fss_01234567890123456789012345678901';
    backend.keys.add(key);
    backend.row['datas'] = jsonEncode(['v2:$key:${backend.encrypted(key, 'LEGACY_TWO')}']);
    expect(await read(), 'LEGACY_TWO');
    expect(backend.stores, 0);
    await write('AUTHENTICATED');
    expect(backend.row['keys'], startsWith('v3:fss3_'));
    expect(backend.keys, isNot(contains(key)));
    expect(await read(), 'AUTHENTICATED');
  });

  test('legacy reads and missing-key checks perform no writes or key rotation', () async {
    expect(await read(), 'ORIGINAL_DUMMY_KEY');
    expect(await read('absent'), isNull);
    expect(await storage.containsKey(key: 'vault', options: _options), isTrue);
    expect(backend.stores, 0);
    expect(backend.generations, 0);
    expect(backend.removed, isEmpty);
  });

  test('startup migration upgrades every legacy credential in one commit', () async {
    backend.seed({'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
    final previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = storage;
    try {
      await CredentialKeyStore.migrateLegacy();
    } finally {
      FlutterSecureStoragePlatform.instance = previous;
    }
    expect(backend.stores, 1);
    expect(backend.row['keys'], startsWith('v3:fss3_'));
    expect((jsonDecode(backend.row['datas']!) as List).cast<String>(), everyElement(startsWith('v3:fss3_')));
    expect(backend.removed, containsAll([_index, 'vault', 'other']));
    storage = FlutterSecureStorageWebos();
    expect(await storage.readAll(options: _options), {'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
    final generations = backend.generations;
    expect(await storage.migrateLegacy(), 0);
    expect(backend.generations, generations);
    expect(backend.stores, 1);
  });

  test('migration of an empty new store creates no keys or rows', () async {
    backend.row = {};
    backend.keys.clear();
    expect(await storage.migrateLegacy(), 0);
    expect(backend.stores, 0);
    expect(backend.generations, 0);
  });

  test('migration preserves existing authenticated values without rotating them', () async {
    backend.seed({'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
    await write('NEW');
    final authenticated = (jsonDecode(backend.row['datas']!) as List).first;
    expect(await storage.migrateLegacy(), 1);
    expect((jsonDecode(backend.row['datas']!) as List).first, authenticated);
    expect(await storage.readAll(options: _options), {'vault': 'NEW', 'other': 'OTHER'});
  });

  for (final failure in ['entry', 'index']) {
    test('$failure failure during migration preserves every old entry and cleans staging', () async {
      backend.seed({'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
      final before = Map<String, String?>.of(backend.row);
      final keys = Set<String>.of(backend.keys);
      backend.unavailableKey = failure == 'entry' ? 'other' : null;
      backend.indexEncryptionFails = failure == 'index';
      await expectLater(storage.migrateLegacy(), throwsA(isA<PlatformException>()));
      expect(backend.row, before);
      expect(backend.keys, keys);
      expect(backend.stores, 0);
      backend.unavailableKey = null;
      backend.indexEncryptionFails = false;
      expect(await storage.migrateLegacy(), 2);
    });
  }

  test('migration reloads a competing commit and retains its added credential', () async {
    backend.conflictOnce = true;
    expect(await storage.migrateLegacy(), 2);
    expect(backend.stores, 2);
    expect(await storage.readAll(options: _options), {'vault': 'ORIGINAL_DUMMY_KEY', 'other-isolate': 'OTHER_DUMMY_KEY'});
  });

  test('lost migration acknowledgement preserves keys used by the durable row', () async {
    backend.seed({'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
    backend.loseAcknowledgement = true;
    await expectLater(storage.migrateLegacy(), throwsA(isA<PlatformException>()));
    backend.loseAcknowledgement = false;
    storage = FlutterSecureStorageWebos();
    expect(await storage.migrateLegacy(), 0);
    expect(await storage.readAll(options: _options), {'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
  });

  for (final key in ['vault', _index]) {
    test('transient $key failure preserves bytes and recovers in a fresh adapter', () async {
      final before = Map.of(backend.row);
      backend.unavailableKey = key;
      await expectLater(read(), throwsA(unavailable));
      expect(backend.row, before);
      expect(backend.stores, 0);
      expect(backend.removed, isEmpty);
      backend.unavailableKey = null;
      storage = FlutterSecureStorageWebos();
      expect(await read(), 'ORIGINAL_DUMMY_KEY');
    });
  }

  test('readAll propagates an unavailable entry instead of returning a partial store', () async {
    backend.seed({'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
    backend.unavailableKey = 'other';
    await expectLater(storage.readAll(options: _options), throwsA(unavailable));
    expect(backend.stores, 0);
    backend.unavailableKey = null;
    expect(await storage.readAll(options: _options), {'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
  });

  test('native load failure is not treated as a new empty store', () async {
    backend.loadFails = true;
    await expectLater(write('replacement'), throwsA(isA<PlatformException>()));
    expect(backend.stores, 0);
    expect(backend.generations, 0);
    backend.loadFails = false;
    expect(await read(), 'ORIGINAL_DUMMY_KEY');
  });

  test('malformed persisted lists are preserved and reported', () async {
    backend.row['datas'] = '[]';
    final before = Map.of(backend.row);
    await expectLater(write('replacement'), throwsA(isA<PlatformException>()));
    expect(backend.row, before);
    expect(backend.stores, 0);
  });

  for (final failure in ['generation', 'value-encryption', 'index-encryption', 'store']) {
    test('$failure failure during overwrite preserves the previous usable credential', () async {
      final before = Map.of(backend.row);
      backend.generationFails = failure == 'generation';
      backend.valueEncryptionFails = failure == 'value-encryption';
      backend.indexEncryptionFails = failure == 'index-encryption';
      backend.storeFails = failure == 'store';
      await expectLater(write('REPLACEMENT'), throwsA(isA<PlatformException>()));
      expect(backend.row, before);
      expect(backend.keys, containsAll([_index, 'vault']));
      if (failure != 'store') {
        expect(backend.keys, {_index, 'vault'}, reason: 'uncommitted staging keys are cleaned up');
      }
      backend.generationFails = backend.valueEncryptionFails = backend.indexEncryptionFails = backend.storeFails =
          false;
      storage = FlutterSecureStorageWebos();
      expect(await read(), 'ORIGINAL_DUMMY_KEY');
    });
  }

  test('overwrite upgrades legacy envelopes atomically and survives restart', () async {
    await write('REPLACEMENT');
    expect(backend.row['keys'], startsWith('v3:fss3_'));
    expect(backend.removed, containsAll([_index, 'vault']));
    storage = FlutterSecureStorageWebos();
    expect(await read(), 'REPLACEMENT');
    await write('SECOND');
    expect(await read(), 'SECOND');
  });

  test('unaffected legacy entries stay readable after an index upgrade', () async {
    backend.seed({'vault': 'ORIGINAL_DUMMY_KEY', 'other': 'OTHER'});
    await write('REPLACEMENT');
    storage = FlutterSecureStorageWebos();
    expect(await storage.readAll(options: _options), {'vault': 'REPLACEMENT', 'other': 'OTHER'});
    expect(backend.keys, contains('other'));
  });

  test('failed delete/deleteAll leaves existing credentials intact', () async {
    backend.storeFails = true;
    final before = Map.of(backend.row);
    await expectLater(storage.delete(key: 'vault', options: _options), throwsA(isA<PlatformException>()));
    await expectLater(storage.deleteAll(options: _options), throwsA(isA<PlatformException>()));
    expect(backend.row, before);
    expect(backend.keys, containsAll([_index, 'vault']));
    backend.storeFails = false;
    expect(await read(), 'ORIGINAL_DUMMY_KEY');
  });

  test('delete and deleteAll work after restart and allow writing again', () async {
    await write('NEW');
    await write('OTHER', 'other');
    await storage.delete(key: 'vault', options: _options);
    storage = FlutterSecureStorageWebos();
    expect(await read(), isNull);
    expect(await read('other'), 'OTHER');
    await storage.deleteAll(options: _options);
    storage = FlutterSecureStorageWebos();
    expect(await storage.readAll(options: _options), isEmpty);
    await write('RESTORED');
    expect(await read(), 'RESTORED');
  });

  test('fresh-store reads do not initialize keys and first writes survive restart', () async {
    backend.row = {};
    backend.keys.clear();
    expect(await read(), isNull);
    expect(backend.generations, 0);
    expect(backend.stores, 0);
    await write('FIRST');
    storage = FlutterSecureStorageWebos();
    expect(await read(), 'FIRST');
  });

  test('two instances serialize writes and refresh their cached view', () async {
    final second = FlutterSecureStorageWebos();
    await Future.wait([write('ONE', 'one'), second.write(key: 'two', value: 'TWO', options: _options)]);
    expect(await storage.readAll(options: _options), {'vault': 'ORIGINAL_DUMMY_KEY', 'one': 'ONE', 'two': 'TWO'});
    expect(await second.read(key: 'one', options: _options), 'ONE');
  });

  test('cross-isolate CAS conflict reloads and preserves the concurrent addition', () async {
    backend.conflictOnce = true;
    await write('NEW');
    expect(await storage.readAll(options: _options), {'vault': 'NEW', 'other-isolate': 'OTHER_DUMMY_KEY'});
    expect(backend.stores, 2);
  });

  test('lost commit acknowledgement never deletes keys that may now be active', () async {
    backend.loseAcknowledgement = true;
    await expectLater(write('COMMITTED'), throwsA(isA<PlatformException>()));
    backend.loseAcknowledgement = false;
    storage = FlutterSecureStorageWebos();
    expect(await read(), 'COMMITTED');
  });

  test('key cleanup failure does not invalidate the newly committed credential', () async {
    backend.cleanupFails = true;
    await write('NEW');
    storage = FlutterSecureStorageWebos();
    expect(await read(), 'NEW');
  });
}
