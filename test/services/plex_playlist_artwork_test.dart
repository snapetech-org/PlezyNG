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
  const playlist = MediaPlaylist(
    id: '42',
    backend: MediaBackend.plex,
    title: 'Mix',
    playlistType: 'audio',
    serverId: 'srv',
  );
  http.Response jsonResponse(Map<String, dynamic> data) =>
      http.Response(jsonEncode({'MediaContainer': data}), 200, headers: {'content-type': 'application/json'});
  http.Response metadata({String id = '42'}) => jsonResponse({
    'Metadata': [
      {
        'ratingKey': id,
        'type': 'playlist',
        'title': 'Mix',
        'playlistType': 'audio',
        'composite': '/playlists/42/composite/123',
      },
    ],
  });
  http.Response posters({bool selected = false, bool photo = false}) => jsonResponse({
    photo ? 'Photo' : 'Metadata': [
      {'ratingKey': 'upload://poster & 音楽', 'thumb': '/library/metadata/42/thumb/123', 'selected': selected ? 1 : 0},
    ],
  });
  PlexClient client(Future<http.Response> Function(http.Request) handler) {
    final api = testPlexClient(serverId: ServerId('srv'), handler: handler);
    addTearDown(api.close);
    return api;
  }

  for (final photo in [false, true]) {
    test('reads validated artwork options with Photo=$photo', () async {
      final api = client((r) async => r.url.path.endsWith('/posters') ? posters(photo: photo) : metadata());
      final choices = await api.fetchPlaylistArtwork(playlist);
      expect(choices.single.key, 'upload://poster & 音楽');
      expect(choices.single.thumbnailPath, '/library/metadata/42/thumb/123');
      expect(choices.single.selected, isFalse);
      expect(() => choices.clear(), throwsUnsupportedError);
    });
  }

  test('select revalidates opaque server key and accepted selection, then reloads composite', () async {
    final requests = <http.Request>[];
    var changed = false;
    final api = client((r) async {
      requests.add(r);
      if (r.method == 'PUT') {
        changed = true;
        return http.Response('', 204);
      }
      return r.url.path.endsWith('/posters') ? posters(selected: changed) : metadata();
    });
    final updated = await api.updatePlaylistArtwork(playlist: playlist, artworkKey: 'upload://poster & 音楽');
    expect(updated.displayImagePath, '/playlists/42/composite/123');
    expect(requests.map((r) => (r.method, r.url.path)), [
      ('GET', '/playlists/42'),
      ('GET', '/library/metadata/42/posters'),
      ('PUT', '/library/metadata/42/poster'),
      ('GET', '/library/metadata/42/posters'),
      ('GET', '/playlists/42'),
    ]);
    expect(requests[2].url.queryParameters, {'url': 'upload://poster & 音楽'});
  });

  for (final reset in [false, true]) {
    test('upload/reset=$reset uses acknowledged contract and reloads playlist', () async {
      final requests = <http.Request>[];
      final api = client((r) async {
        requests.add(r);
        return r.method == 'GET' ? metadata() : http.Response('', 200);
      });
      await api.updatePlaylistArtwork(playlist: playlist, bytes: reset ? null : [0, 255, 42], reset: reset);
      expect(requests.map((r) => r.method), ['GET', reset ? 'DELETE' : 'POST', 'GET']);
      expect(requests[1].url.path, reset ? '/library/metadata/42/thumb' : '/library/metadata/42/posters');
      if (!reset) {
        expect(requests[1].bodyBytes, [0, 255, 42]);
        expect(requests[1].headers['content-type'], 'application/octet-stream');
      }
    });
  }

  test('upload payload stays frozen while fresh playlist identity is loading', () async {
    final gate = Completer<http.Response>();
    final sent = <List<int>>[];
    var reads = 0;
    final api = client((r) async {
      if (r.method == 'POST') {
        sent.add(r.bodyBytes);
        return http.Response('', 200);
      }
      return reads++ == 0 ? gate.future : metadata();
    });
    final bytes = <int>[1, 2, 3];
    final pending = api.updatePlaylistArtwork(playlist: playlist, bytes: bytes);
    await Future<void>.delayed(Duration.zero);
    bytes
      ..clear()
      ..addAll([9, 8]);
    gate.complete(metadata());
    await pending;
    expect(sent.single, [1, 2, 3]);
  });

  test('unoffered and ignored choices cannot report successful selection', () async {
    var writes = 0;
    final api = client((r) async {
      if (r.method != 'GET') {
        writes++;
        return http.Response('', 200);
      }
      return r.url.path.endsWith('/posters') ? posters() : metadata();
    });
    await expectLater(
      api.updatePlaylistArtwork(playlist: playlist, artworkKey: 'https://caller.invalid/image'),
      throwsStateError,
    );
    expect(writes, 0);
    await expectLater(
      api.updatePlaylistArtwork(playlist: playlist, artworkKey: 'upload://poster & 音楽'),
      throwsStateError,
    );
    expect(writes, 1);
  });

  test('malformed duplicate and unbounded options fail closed', () async {
    for (final rows in [
      'invalid',
      [
        {'ratingKey': 'x', 'thumb': '/x'},
        {'ratingKey': 'x', 'thumb': '/y'},
      ],
      [
        {'ratingKey': 'x', 'thumb': '/a\u0000b'},
      ],
      [
        {'ratingKey': 'x'},
      ],
      List.filled(513, {'ratingKey': 'x', 'thumb': '/x'}),
    ]) {
      final api = client((r) async => r.url.path.endsWith('/posters') ? jsonResponse({'Metadata': rows}) : metadata());
      await expectLater(api.fetchPlaylistArtwork(playlist), throwsFormatException);
    }
  });

  test('invalid operations and foreign playlist identities fail before network', () async {
    var calls = 0;
    final api = client((_) async {
      calls++;
      return metadata();
    });
    for (final action in <Future<void> Function()>[
      () async => api.updatePlaylistArtwork(playlist: playlist),
      () async => api.updatePlaylistArtwork(playlist: playlist, bytes: [], reset: true),
      () async => api.updatePlaylistArtwork(playlist: playlist, bytes: []),
      () async => api.updatePlaylistArtwork(playlist: playlist, bytes: [-1]),
      () async => api.updatePlaylistArtwork(playlist: playlist, bytes: List.filled(10 * 1024 * 1024 + 1, 0)),
      () async => api.updatePlaylistArtwork(playlist: playlist, artworkKey: 'a\u0000b'),
      () async => api.fetchPlaylistArtwork(
        const MediaPlaylist(
          id: '../42',
          backend: MediaBackend.plex,
          title: 'bad',
          playlistType: 'audio',
          serverId: 'srv',
        ),
      ),
      () async => api.fetchPlaylistArtwork(
        const MediaPlaylist(
          id: '42',
          backend: MediaBackend.plex,
          title: 'bad',
          playlistType: 'audio',
          serverId: 'foreign',
        ),
      ),
    ]) {
      await expectLater(action(), throwsArgumentError);
    }
    expect(calls, 0);
  });

  test('retired source after options read cannot write', () async {
    var current = true, writes = 0;
    final api = client((r) async {
      if (r.method != 'GET') writes++;
      if (r.url.path.endsWith('/posters')) {
        current = false;
        return posters();
      }
      return metadata();
    });
    await expectLater(
      api.updatePlaylistArtwork(playlist: playlist, artworkKey: 'upload://poster & 音楽', isCurrent: () => current),
      throwsStateError,
    );
    expect(writes, 0);
  });

  test('retired source after upload cannot reload another account', () async {
    var current = true, reads = 0;
    final api = client((r) async {
      if (r.method == 'POST') {
        current = false;
        return http.Response('', 200);
      }
      reads++;
      return metadata();
    });
    await expectLater(
      api.updatePlaylistArtwork(playlist: playlist, bytes: [1], isCurrent: () => current),
      throwsStateError,
    );
    expect(reads, 1);
  });

  test('source retirement during preflight prevents upload', () async {
    final gate = Completer<http.Response>();
    var current = true, calls = 0;
    final api = client((_) {
      calls++;
      return gate.future;
    });
    final result = api.updatePlaylistArtwork(playlist: playlist, bytes: [1], isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete(metadata());
    await expectLater(result, throwsStateError);
    expect(calls, 1);
  });

  test('wrong fresh identity and offline state cannot authorize writes', () async {
    var calls = 0;
    final api = client((_) async {
      calls++;
      return metadata(id: '99');
    });
    await expectLater(api.updatePlaylistArtwork(playlist: playlist, reset: true), throwsStateError);
    expect(calls, 1);
    api.setOfflineMode(true);
    await expectLater(api.fetchPlaylistArtwork(playlist), throwsStateError);
    expect(calls, 1);
  });

  test('permission failures propagate from artwork reads and writes', () async {
    for (final denyRead in [false, true]) {
      final api = client((r) async => r.url.path == '/playlists/42' ? metadata() : http.Response('', 403));
      await expectLater(
        denyRead ? api.fetchPlaylistArtwork(playlist) : api.updatePlaylistArtwork(playlist: playlist, reset: true),
        throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    }
  });
}
