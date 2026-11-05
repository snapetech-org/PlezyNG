import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:http/http.dart' as http;

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });
  tearDown(() => db.close());

  for (final value in [true, false, 1, 0, '1', '0', 'true', 'false', null, 'unexpected']) {
    test('live deletion permission handles $value', () async {
      final client = testPlexClient(
        handler: (request) async {
          expect(request.url.path, '/:/prefs');
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Setting': [
                  if (value != null) {'id': 'allowMediaDeletion', 'value': value},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );
      addTearDown(client.close);
      expect(await client.fetchDeletePermission(testMediaItem()), switch (value) {
        true || 1 || '1' || 'true' => true,
        false || 0 || '0' || 'false' => false,
        _ => null,
      });
    });
  }

  test('confirmation rechecks a preference revoked after the menu opened', () async {
    var enabled = true;
    final deleted = <String>[];
    final client = testPlexClient(
      handler: (request) async {
        if (request.method == 'DELETE') {
          deleted.add(request.url.path);
          return http.Response('', 200);
        }
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Setting': [
                {'id': 'allowMediaDeletion', 'value': enabled},
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(client.close);
    final item = testMediaItem();
    expect(await client.fetchDeletePermission(item), isTrue);
    enabled = false;
    expect(await client.deleteMediaItem(item), isFalse);
    expect(deleted, isEmpty);
    enabled = true;
    expect(await client.deleteMediaItem(item), isTrue);
    expect(deleted, ['/library/metadata/${item.id}']);
  });

  test('a refused or malformed preference response cannot enable deletion', () async {
    for (final status in [200, 403, 500]) {
      final client = testPlexClient(handler: (_) async => http.Response('not preferences', status));
      expect(await client.deleteMediaItem(testMediaItem()), isFalse);
      client.close();
    }
  });

  test('a hung preference probe has one bounded attempt', () async {
    var attempts = 0;
    final client = testPlexClient(
      handler: (_) {
        attempts++;
        return Completer<http.Response>().future;
      },
    );
    addTearDown(client.close);
    expect(await client.fetchDeletePermission(testMediaItem()), isNull);
    expect(attempts, 1);
  });
}
