import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_stream.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';

import '../test_helpers/backend_client_fixtures.dart';

const _track = MediaItem.plex(
  id: '42',
  kind: MediaKind.track,
  serverId: 'server',
  libraryId: '3',
  mediaVersions: [
    MediaVersion(
      id: 'original',
      parts: [
        MediaPart(
          id: 'part',
          streams: [
            MediaStream(id: '1', kind: MediaStreamKind.audio),
            MediaStream(id: '2', kind: MediaStreamKind.audio, selected: true),
          ],
        ),
      ],
    ),
  ],
);

http.Response _container(Map<String, Object> values) =>
    http.Response(jsonEncode({'MediaContainer': values}), 200, headers: {'content-type': 'application/json'});

void main() {
  late AppDatabase database;
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
  });
  tearDown(() => database.close());

  PlexClient client(Future<http.Response> Function(http.Request) handler, {bool owned = true}) {
    final server = testPlexClient(serverId: ServerId('server'), handler: handler)
      ..plexAccountId = 'plex.owner'
      ..plexMusicUserIdentifier = 'owner'
      ..bindMusicHistoryResource(owned: owned);
    addTearDown(server.close);
    return server;
  }

  test('reads selected stream levels and distinguishes missing data from failures', () async {
    http.Response response = _container({
      'Level': [
        {'v': -20},
      ],
    });
    final server = client((request) async {
      expect(request.url.path, '/library/streams/2/levels');
      expect(request.url.queryParameters['subsample'], '512');
      expect(request.headers['x-plex-token'], 'token');
      return response;
    }, owned: false);
    Future<PlexMusicAnalysisStatus> check() => server.checkMusicAnalysis(_track, current: () => true);
    expect(await check(), PlexMusicAnalysisStatus.ready);
    response = _container({'Level': []});
    expect(await check(), PlexMusicAnalysisStatus.missing);
    response = http.Response('{}', 403);
    expect(await check(), PlexMusicAnalysisStatus.forbidden);
    response = _container({'Level': 'not-an-array'});
    expect(await check(), PlexMusicAnalysisStatus.unavailable);
  });

  test('requests analysis only for a current, confirmed track on a supported owned server', () async {
    final requests = <String>[];
    var version = '1.43.3.10613-abcdef';
    var library = '4';
    final server = client((request) async {
      final path = request.url.path;
      requests.add('${request.method} $path');
      if (path == '/') return _container({'version': version});
      if (path == '/library/metadata/42') {
        return _container({
          'librarySectionID': library,
          'Metadata': [
            {'ratingKey': '42', 'type': 'track'},
          ],
        });
      }
      expect(path, '/library/metadata/42/analyzeLoudness');
      expect(request.url.queryParameters, containsPair('force', '0'));
      expect(request.url.queryParameters, containsPair('manual', '1'));
      return http.Response('', 200);
    });
    Future<PlexMusicAnalysisStatus> request() => server.requestMusicAnalysis(_track, current: () => true);
    expect(await request(), PlexMusicAnalysisStatus.unsupported);
    expect(requests, ['GET /']);
    requests.clear();
    version = '1.43.4.10613-abcdef';
    expect(await request(), PlexMusicAnalysisStatus.unavailable);
    expect(requests, ['GET /', 'GET /library/metadata/42']);
    requests.clear();
    library = '3';
    expect(await request(), PlexMusicAnalysisStatus.requested);
    expect(requests, ['GET /', 'GET /library/metadata/42', 'PUT /library/metadata/42/analyzeLoudness']);
    requests.clear();
    server.bindMusicHistoryResource(owned: false);
    expect(await request(), PlexMusicAnalysisStatus.forbidden);
    expect(requests, isEmpty);
  });

  test('a source change during preflight cannot send a late server write', () async {
    final requested = Completer<void>();
    final pending = Completer<http.Response>();
    final server = client((request) {
      expect(request.method, 'GET');
      expect(request.url.path, '/');
      requested.complete();
      return pending.future;
    });
    final analysis = server.requestMusicAnalysis(_track, current: () => true);
    await requested.future;
    server.bindMusicHistoryResource(owned: false);
    pending.complete(_container({'version': '1.43.4.10613'}));
    expect(await analysis, PlexMusicAnalysisStatus.forbidden);
  });
}
