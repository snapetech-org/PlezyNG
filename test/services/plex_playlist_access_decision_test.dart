import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/models/plex/plex_playlist_access.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/services/plex_playlist_sharing.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

const playlist = MediaPlaylist(
  id: '123',
  backend: MediaBackend.plex,
  title: 'Music',
  playlistType: 'audio',
  serverId: 's',
);

void main() {
  late PlexClient client;
  late PlexAuthService auth;
  late PlexPlaylistSharing sharing;
  late Map<String, Object?> metadata;
  late List<http.Request> grants;
  late bool current;
  Future<http.Response> Function()? beforeMetadata;
  Future<http.Response> Function()? cloudResponse;

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    metadata = {'ratingKey': '123', 'title': 'Music', 'playlistType': 'audio', 'smart': false, 'leafCount': 2};
    current = true;
    grants = [];
    beforeMetadata = null;
    cloudResponse = null;
    client = testPlexClient(
      serverId: ServerId('s'),
      config: testPlexConfig(machineIdentifier: 'machine'),
      handler: (_) async => beforeMetadata != null
          ? beforeMetadata!()
          : jsonResponse({
              'MediaContainer': {
                'Metadata': [metadata],
              },
            }),
    );
    client.plexAccountToken = 'cloud-token';
    auth = PlexAuthService.forTesting(
      http: MediaServerHttpClient(
        client: MockClient((request) async {
          grants.add(request);
          return cloudResponse != null
              ? cloudResponse!()
              : jsonResponse([
                  {'sharedSourceId': 42},
                ]);
        }),
      ),
    );
    sharing = PlexPlaylistSharing(client: client, auth: auth, playlist: playlist, isCurrent: () => current);
    addTearDown(client.close);
    addTearDown(auth.dispose);
  });

  test('fresh displayed title and exact playlist URI reach the account grant', () async {
    metadata['title'] = 'Fresh music';
    final draft = await sharing.prepare();
    expect(draft.playlist.title, 'Fresh music');
    expect(draft.uri, 'server://machine/com.plexapp.plugins.library/playlists/123/items');
    expect(await sharing.grant(draft, 'friend'), 42);
    expect(jsonDecode(grants.single.body), {
      'items': [
        {'uri': draft.uri, 'type': 'playlist', 'title': 'Fresh music'},
      ],
      'invitedEmail': 'friend',
    });
    expect(grants.single.headers['X-Plex-Token'], 'cloud-token');
  });

  test('a live playlist can change its contents without being copied', () async {
    final draft = await sharing.prepare();
    metadata['leafCount'] = 10;
    expect(await sharing.grant(draft, 'friend'), 42);
    expect(grants, hasLength(1));
  });

  for (final change in [
    {'title': 'Renamed'},
    {'ratingKey': '456'},
    {'playlistType': 'video'},
    {'smart': true},
  ]) {
    test('a changed playlist decision cannot be granted: $change', () async {
      final draft = await sharing.prepare();
      metadata.addAll(change);
      await expectLater(sharing.grant(draft, 'friend'), throwsStateError);
      expect(grants, isEmpty);
    });
  }

  test('a retired authorization blocks preparation and an existing decision', () async {
    final draft = await sharing.prepare();
    current = false;
    await expectLater(sharing.prepare(), throwsStateError);
    await expectLater(sharing.grant(draft, 'friend'), throwsStateError);
    expect(grants, isEmpty);
  });

  test('a cloud account token replacement retires the existing decision', () async {
    final draft = await sharing.prepare();
    client.plexAccountToken = 'replacement';
    expect(sharing.current, isFalse);
    await expectLater(sharing.grant(draft, 'friend'), throwsStateError);
    expect(grants, isEmpty);
  });

  test('authorization is checked after the fresh server read', () async {
    final draft = await sharing.prepare();
    beforeMetadata = () async {
      current = false;
      return jsonResponse({
        'MediaContainer': {
          'Metadata': [metadata],
        },
      });
    };
    await expectLater(sharing.grant(draft, 'friend'), throwsStateError);
    expect(grants, isEmpty);
  });

  test('preparing another decision invalidates the previous draft', () async {
    final first = await sharing.prepare();
    final second = await sharing.prepare();
    await expectLater(sharing.grant(first, 'friend'), throwsStateError);
    expect(await sharing.grant(second, 'friend'), 42);
  });

  test('concurrent and acknowledged submissions cannot send duplicates', () async {
    final pending = Completer<http.Response>(), started = Completer<void>();
    cloudResponse = () {
      started.complete();
      return pending.future;
    };
    final draft = await sharing.prepare();
    final first = sharing.grant(draft, 'friend');
    await started.future;
    await expectLater(sharing.grant(draft, 'friend'), throwsStateError);
    pending.complete(
      jsonResponse([
        {'sharedSourceId': 42},
      ]),
    );
    expect(await first, 42);
    await expectLater(sharing.grant(draft, 'friend'), throwsStateError);
    expect(grants, hasLength(1));
  });

  test('a late cloud reply cannot acknowledge a replacement profile', () async {
    cloudResponse = () async {
      current = false;
      return jsonResponse([
        {'sharedSourceId': 42},
      ]);
    };
    final draft = await sharing.prepare();
    await expectLater(sharing.grant(draft, 'friend'), throwsStateError);
    expect(grants, hasLength(1));
  });

  test('a denied request is not automatically retried', () async {
    cloudResponse = () async => http.Response('', 403);
    final draft = await sharing.prepare();
    await expectLater(sharing.grant(draft, 'friend'), throwsA(anything));
    expect(grants, hasLength(1));
  });
  test('revoke requires a displayed grant and retires changed playlist metadata', () async {
    cloudResponse = () async => jsonResponse([
      {
        'id': 42,
        'invited': {'id': 8, 'username': 'friend'},
        'sharedItems': [
          {'id': 99, 'uri': 'server://machine/com.plexapp.plugins.library/playlists/123/items'},
        ],
      },
    ]);
    final draft = await sharing.prepare();
    final access = await sharing.listAccess(draft);
    final forged = PlexPlaylistAccessGrant(
      itemId: 99,
      sourceId: 42,
      userId: 8,
      userName: 'friend',
      uri: draft.uri,
      received: false,
    );
    await expectLater(sharing.revoke(draft, forged), throwsStateError);
    metadata['title'] = 'Renamed';
    await expectLater(sharing.revoke(draft, access.single), throwsStateError);
    expect(grants.where((r) => r.method == 'DELETE'), isEmpty);
  });

  test('revocation removes only the displayed grant once', () async {
    cloudResponse = () async => grants.last.method == 'GET'
        ? jsonResponse([
            {
              'id': 42,
              'invited': {'id': 8, 'username': 'friend'},
              'sharedItems': [
                {'id': 99, 'uri': 'server://machine/com.plexapp.plugins.library/playlists/123/items'},
              ],
            },
          ])
        : http.Response('', 204);
    final draft = await sharing.prepare();
    final access = await sharing.listAccess(draft);
    await sharing.revoke(draft, access.single);
    await expectLater(sharing.revoke(draft, access.single), throwsStateError);
    expect(grants.map((r) => r.method), ['GET', 'GET', 'DELETE']);
  });
}
