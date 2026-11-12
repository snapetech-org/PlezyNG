import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/music/plex_received_playlists.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

Map<String, Object?> access({
  List<int> ids = const [1],
  String machine = 'machine',
  String status = 'accepted',
  int owner = 7,
}) => {
  'id': 42,
  'status': status,
  'owner': {'id': owner, 'username': 'Owner'},
  'sharedItems': [
    for (final id in ids) {'id': 100 + id, 'uri': 'server://$machine/com.plexapp.plugins.library/playlists/$id/items'},
  ],
};

void main() {
  late PlexClient client;
  late PlexAuthService auth;
  late PlexReceivedPlaylists received;
  late List<Object?> sources;
  late List<String> reads;
  late bool current;
  late Map<int, Map<String, Object?>> changes;
  Future<http.Response> Function(http.Request)? cloud, metadata;

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    sources = [access()];
    reads = [];
    current = true;
    changes = {};
    cloud = null;
    metadata = null;
    client = testPlexClient(
      serverId: ServerId('s'),
      config: testPlexConfig(machineIdentifier: 'machine'),
      handler: (request) async {
        reads.add(request.url.path);
        if (metadata != null) return metadata!(request);
        final id = int.parse(request.url.pathSegments.last);
        return jsonResponse({
          'MediaContainer': {
            'Metadata': [
              {'ratingKey': '$id', 'title': 'Playlist $id', 'playlistType': 'audio', 'smart': false, ...?changes[id]},
            ],
          },
        });
      },
    );
    client.plexAccountToken = 'cloud-token';
    auth = PlexAuthService.forTesting(
      http: MediaServerHttpClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.host, 'plex.tv');
          expect(request.headers['X-Plex-Token'], 'cloud-token');
          return cloud != null ? cloud!(request) : jsonResponse(sources);
        }),
      ),
    );
    received = PlexReceivedPlaylists(client: client, auth: auth, isCurrent: () => current);
    addTearDown(client.close);
    addTearDown(auth.dispose);
  });

  test('accepted playlist grants use only the existing authorized server', () async {
    sources = [
      access(),
      access(ids: [2], machine: 'foreign'),
      access(ids: [3], status: 'pending'),
    ];
    await received.refresh();
    final page = await received.page();
    expect(page.items.map((row) => row.playlist.id), ['1']);
    expect(page.items.single.access.userName, 'Owner');
    expect(page.items.single.playlist.serverId, 's');
    expect(reads, ['/playlists/1']);
    expect(page.hasMore, isFalse);
    expect(await received.open(page.items.single), isNotNull);
    expect(reads, ['/playlists/1', '/playlists/1']);
  });

  test('paging advances through invalid rows without skipping later grants', () async {
    sources = [
      access(ids: [1, 2, 3, 4, 5]),
    ];
    changes[2] = {'playlistType': 'video'};
    changes[3] = {'ratingKey': 'wrong'};
    await received.refresh();
    final first = await received.page(size: 3);
    expect(first.items.map((row) => row.playlist.id), ['1']);
    expect(first.failed, 2);
    expect(first.nextOffset, 3);
    expect(first.hasMore, isTrue);
    final second = await received.page(offset: first.nextOffset, size: 3);
    expect(second.items.map((row) => row.playlist.id), ['4', '5']);
    expect(second.nextOffset, 5);
    expect(second.hasMore, isFalse);
  });

  test('metadata work is bounded to four simultaneous requests', () async {
    sources = [access(ids: List.generate(12, (i) => i + 1))];
    var active = 0, maximum = 0;
    metadata = (request) async {
      active++;
      if (active > maximum) maximum = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      final id = request.url.pathSegments.last;
      return jsonResponse({
        'MediaContainer': {
          'Metadata': [
            {'ratingKey': id, 'title': id, 'playlistType': 'audio'},
          ],
        },
      });
    };
    await received.refresh();
    expect((await received.page()).items, hasLength(12));
    expect(maximum, 4);
  });

  test('account changes during discovery or metadata cannot adopt results', () async {
    cloud = (_) async {
      current = false;
      return jsonResponse(sources);
    };
    await expectLater(received.refresh(), throwsStateError);
    expect(reads, isEmpty);
    current = true;
    cloud = null;
    await received.refresh();
    metadata = (_) async {
      current = false;
      return jsonResponse({
        'MediaContainer': {'Metadata': []},
      });
    };
    await expectLater(received.page(), throwsStateError);
  });

  test('refresh and token rotation retire retained browse decisions', () async {
    await received.refresh();
    final entry = (await received.page()).items.single;
    await received.refresh();
    expect(entry.current, isFalse);
    await expectLater(received.open(entry), throwsStateError);
    final fresh = (await received.page()).items.single;
    client.plexAccountToken = 'replacement';
    expect(fresh.current, isFalse);
    await expectLater(received.open(fresh), throwsStateError);
  });

  test('overlapping refreshes cannot replace newer grant results', () async {
    final replies = [Completer<http.Response>(), Completer<http.Response>()];
    var count = 0;
    cloud = (_) => replies[count++].future;
    final first = received.refresh();
    await Future<void>.delayed(Duration.zero);
    final second = received.refresh();
    await Future<void>.delayed(Duration.zero);
    replies[1].complete(
      jsonResponse([
        access(ids: [2]),
      ]),
    );
    await second;
    final old = expectLater(first, throwsStateError);
    replies[0].complete(
      jsonResponse([
        access(ids: [1]),
      ]),
    );
    await old;
    expect((await received.page()).items.single.playlist.id, '2');
  });

  for (final change in ['revoked', 'pending', 'owner', 'source']) {
    test('opening revalidates $change access before reading playlist metadata', () async {
      await received.refresh();
      final entry = (await received.page()).items.single;
      sources = switch (change) {
        'revoked' => [],
        'pending' => [access(status: 'pending')],
        'owner' => [access(owner: 8)],
        _ => [
          {...access(), 'id': 43},
        ],
      };
      await expectLater(received.open(entry), throwsStateError);
      expect(reads, ['/playlists/1']);
    });
  }

  test('open rejects a playlist whose media type changed', () async {
    await received.refresh();
    final entry = (await received.page()).items.single;
    changes[1] = {'playlistType': 'video'};
    await expectLater(received.open(entry), throwsStateError);
  });

  test('an entry cannot be opened by a different catalog instance', () async {
    await received.refresh();
    final entry = (await received.page()).items.single;
    final other = PlexReceivedPlaylists(client: client, auth: auth, isCurrent: () => true);
    await other.refresh();
    await expectLater(other.open(entry), throwsStateError);
    expect(reads, ['/playlists/1']);
  });
}
