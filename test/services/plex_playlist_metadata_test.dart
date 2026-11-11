import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';
import '../test_helpers/backend_client_fixtures.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });
  tearDown(() => db.close());

  MediaPlaylist playlist({
    String id = '42',
    String server = 'srv',
    MediaBackend backend = MediaBackend.plex,
    String title = 'Original',
    String? summary = 'Description',
    bool smart = false,
  }) => MediaPlaylist(
    id: id,
    backend: backend,
    title: title,
    summary: summary,
    playlistType: 'audio',
    serverId: server,
    smart: smart,
  );

  http.Response metadata({
    String id = '42',
    String title = 'Original',
    String? summary = 'Description',
    bool smart = false,
  }) => http.Response(
    jsonEncode({
      'MediaContainer': {
        'Metadata': [
          {
            'ratingKey': id,
            'type': 'playlist',
            'title': title,
            'summary': summary,
            'playlistType': 'audio',
            'smart': smart,
          },
        ],
      },
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  PlexClient client(Future<http.Response> Function(http.Request) handler) {
    final result = testPlexClient(serverId: ServerId('srv'), handler: handler);
    addTearDown(result.close);
    return result;
  }

  for (final smart in [false, true]) {
    test('updates playlist smart=$smart without replacing entries or rules', () async {
      final requests = <http.Request>[];
      final api = client((request) async {
        requests.add(request);
        return request.method == 'PUT'
            ? http.Response('', 200)
            : metadata(
                smart: smart,
                title: requests.length == 1 ? 'Original' : 'New & 音楽',
                summary: requests.length == 1 ? 'Description' : '',
              );
      });
      final updated = await api.updatePlaylistMetadata(
        playlist: playlist(smart: smart),
        title: ' New & 音楽 ',
        summary: '',
      );
      expect(updated.title, 'New & 音楽');
      expect(updated.summary, '');
      expect(updated.smart, smart);
      expect(requests.map((r) => (r.method, r.url.path)), [
        ('GET', '/playlists/42'),
        ('PUT', '/playlists/42'),
        ('GET', '/playlists/42'),
      ]);
      final query = requests[1].url.queryParameters;
      expect(query['title.value'], 'New & 音楽');
      expect(query['summary.value'], '');
      expect(query['title.locked'], '1');
      expect(query['summary.locked'], '1');
      expect(query.containsKey('uri'), isFalse);
    });
  }

  test('summary-only edit preserves a concurrent title change', () async {
    final requests = <http.Request>[];
    final api = client((request) async {
      requests.add(request);
      return request.method == 'PUT'
          ? http.Response('', 204)
          : metadata(title: 'Other device', summary: requests.length == 1 ? 'Description' : 'New');
    });
    await api.updatePlaylistMetadata(playlist: playlist(), summary: 'New');
    expect(requests[1].url.queryParameters.containsKey('title.value'), isFalse);
  });

  test('ignored server fields do not report a successful save', () async {
    final api = client((request) async => request.method == 'PUT' ? http.Response('', 200) : metadata());
    await expectLater(api.updatePlaylistMetadata(playlist: playlist(), title: 'New'), throwsStateError);
  });

  test('changed edited field prevents the write', () async {
    final requests = <String>[];
    final api = client((request) async {
      requests.add(request.method);
      return metadata(title: 'Other device');
    });
    await expectLater(api.updatePlaylistMetadata(playlist: playlist(), title: 'New'), throwsStateError);
    expect(requests, ['GET']);
  });

  test('invalid presentation and foreign identities fail before network', () async {
    var calls = 0;
    final api = client((_) async {
      calls++;
      return metadata();
    });
    for (final target in [
      playlist(id: '../42'),
      playlist(id: ''),
      playlist(server: 'other'),
      playlist(backend: MediaBackend.jellyfin),
    ]) {
      await expectLater(api.updatePlaylistMetadata(playlist: target, title: 'New'), throwsArgumentError);
    }
    for (final title in ['', '   ', 'a' * 256, 'a\nb']) {
      await expectLater(api.updatePlaylistMetadata(playlist: playlist(), title: title), throwsArgumentError);
    }
    await expectLater(api.updatePlaylistMetadata(playlist: playlist()), throwsArgumentError);
    await expectLater(api.updatePlaylistMetadata(playlist: playlist(), summary: 'a' * 10001), throwsArgumentError);
    await expectLater(api.updatePlaylistMetadata(playlist: playlist(), summary: 'a\u0000b'), throwsArgumentError);
    expect(calls, 0);
  });

  test('wrong playlist response cannot authorize a write', () async {
    var calls = 0;
    final api = client((_) async {
      calls++;
      return metadata(id: '99');
    });
    await expectLater(api.updatePlaylistMetadata(playlist: playlist(), title: 'New'), throwsStateError);
    expect(calls, 1);
  });

  test('source retirement while preflight is reading prevents write', () async {
    var current = true;
    final read = Completer<http.Response>();
    var calls = 0;
    final api = client((_) {
      calls++;
      return read.future;
    });
    final result = api.updatePlaylistMetadata(playlist: playlist(), title: 'New', isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    read.complete(metadata());
    await expectLater(result, throwsStateError);
    expect(calls, 1);
  });

  test('offline mode prevents reads and writes', () async {
    var calls = 0;
    final api = client((_) async {
      calls++;
      return metadata();
    })..setOfflineMode(true);
    await expectLater(api.updatePlaylistMetadata(playlist: playlist(), title: 'New'), throwsStateError);
    expect(calls, 0);
  });

  test('server permission denial propagates and does not report success', () async {
    var calls = 0;
    final api = client((request) async {
      calls++;
      return request.method == 'PUT' ? http.Response('', 403) : metadata();
    });
    await expectLater(
      api.updatePlaylistMetadata(playlist: playlist(), title: 'New'),
      throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', 403)),
    );
    expect(calls, 2);
  });

  test('retired source after write cannot return another accounts metadata', () async {
    var current = true;
    var reads = 0;
    final api = client((request) async {
      if (request.method == 'PUT') {
        current = false;
        return http.Response('', 200);
      }
      reads++;
      return metadata();
    });
    await expectLater(
      api.updatePlaylistMetadata(playlist: playlist(), title: 'New', isCurrent: () => current),
      throwsStateError,
    );
    expect(reads, 1);
  });
}
