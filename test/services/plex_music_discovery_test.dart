import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/plex_api_cache.dart';
import '../test_helpers/backend_client_fixtures.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });
  tearDown(() => db.close());

  test('sonic requests use authenticated nearest and ordered computePath contracts', () async {
    final requests = <Uri>[];
    final client = testPlexClient(
      serverId: ServerId('srv'),
      handler: (request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {'ratingKey': '42', 'type': 'track', 'title': 'Track'},
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(client.close);
    expect((await client.sonicallySimilar('41', limit: 12, maxDistance: .4)).single.id, '42');
    expect(requests.last.path, '/library/metadata/41/nearest');
    expect(requests.last.queryParameters['limit'], '12');
    expect(requests.last.queryParameters['maxDistance'], '0.4');
    final path = await client.sonicPath(libraryId: '3', startId: '41', endId: '42');
    expect(path.single.libraryId, '3');
    expect(requests.last.path, '/library/sections/3/computePath');
    expect(requests.last.queryParameters['startID'], '41');
    expect(requests.last.queryParameters['endID'], '42');
    expect(requests.last.queryParameters['count'], '50');
    expect(requests.last.queryParameters['maxDistance'], '0.25');
    await client.sonicPath(libraryId: '3', startId: '41', endId: '42', count: 25, maxDistance: .4);
    expect(requests.last.queryParameters['count'], '25');
    expect(requests.last.queryParameters['maxDistance'], '0.4');
  });

  test('invalid bounds do not make requests; forbidden analysis is not an empty success', () async {
    var calls = 0;
    final client = testPlexClient(
      serverId: ServerId('srv'),
      handler: (_) async {
        calls++;
        return http.Response('{}', 403);
      },
    );
    addTearDown(client.close);
    await expectLater(client.sonicallySimilar('a', maxDistance: double.nan), throwsArgumentError);
    for (final count in [1, 501]) {
      await expectLater(
        client.sonicPath(libraryId: '3', startId: '41', endId: '42', count: count),
        throwsArgumentError,
      );
    }
    for (final distance in [-.1, 1.1, double.nan, double.infinity]) {
      await expectLater(
        client.sonicPath(libraryId: '3', startId: '41', endId: '42', maxDistance: distance),
        throwsArgumentError,
      );
    }
    await expectLater(client.sonicPath(libraryId: '', startId: '41', endId: '42'), throwsArgumentError);
    await expectLater(client.sonicPath(libraryId: '3', startId: '', endId: '42'), throwsArgumentError);
    await expectLater(client.sonicPath(libraryId: '3', startId: '41', endId: ''), throwsArgumentError);
    expect(calls, 0);
    await expectLater(client.sonicallySimilar('a'), throwsA(isA<Exception>()));
  });
}
