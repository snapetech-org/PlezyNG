import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/plex/plex_playlist_access.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../test_helpers/http_fixtures.dart';

const uri = 'server://machine/com.plexapp.plugins.library/playlists/123/items';
Map<String, Object?> source({String status = 'accepted', List<Object?>? items}) => {
  'id': 42,
  'status': status,
  'origin': 'machine',
  'owner': {'id': 7, 'username': 'owner'},
  'invited': {'id': 8, 'username': 'friend'},
  'sharedItems':
      items ??
      [
        {'id': 99, 'uri': uri},
      ],
};
const grant = PlexPlaylistAccessGrant(
  itemId: 99,
  sourceId: 42,
  userId: 8,
  userName: 'friend',
  uri: uri,
  received: false,
);

void main() {
  PlexAuthService service(Future<http.Response> Function(http.Request) handler) {
    final auth = PlexAuthService.forTesting(http: MediaServerHttpClient(client: MockClient(handler)));
    addTearDown(auth.dispose);
    return auth;
  }

  test('owned grants use includeItems and the actual recipient', () async {
    final auth = service((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://plex.tv/api/v2/shared_sources/owned?includeItems=1');
      expect(request.headers['X-Plex-Token'], 'cloud');
      return jsonResponse([source()]);
    });
    final grants = await auth.getPlaylistAccess(authToken: 'cloud', isCurrent: () => true, playlistUri: uri);
    expect(grants, hasLength(1));
    expect(grants.single.userId, 8);
    expect(grants.single.userName, 'friend');
    expect(grants.single.itemId, 99);
    expect(grants.single.sourceId, 42);
  });

  test('received grants retain the owner and exclude invitations not accepted', () async {
    final auth = service((request) async {
      expect(request.url.path, '/api/v2/shared_sources/received');
      return jsonResponse([source(), source(status: 'pending'), source(status: 'rejected')]);
    });
    final grants = await auth.getPlaylistAccess(authToken: 'cloud', isCurrent: () => true, received: true);
    expect(grants, hasLength(1));
    expect(grants.single.userId, 7);
    expect(grants.single.userName, 'owner');
    expect(grants.single.received, isTrue);
  });

  test('URI filter never exposes other playlists, media types or credential-bearing items', () {
    final grants = PlexPlaylistAccessGrant.parseSources(
      [
        source(
          items: [
            {'id': 99, 'uri': uri},
            {'id': 100, 'uri': 'server://machine/com.plexapp.plugins.library/playlists/456/items'},
            {'id': 101, 'uri': 'server://machine/com.plexapp.plugins.library/library/metadata/123'},
            {'id': 102, 'uri': '$uri?X-Plex-Token=secret'},
            {'id': 103, 'uri': 'https://elsewhere.example.com/123'},
          ],
        ),
      ],
      received: false,
      playlistUri: uri,
    );
    expect(grants.map((g) => g.itemId), [99]);
    expect(() => grants.add(grant), throwsUnsupportedError);
  });

  for (final data in [
    null,
    {},
    [42],
    [
      {'id': 42},
    ],
    [source(), source()],
  ]) {
    test('malformed or ambiguous access data fails closed: $data', () {
      expect(() => PlexPlaylistAccessGrant.parseSources(data, received: false), throwsFormatException);
    });
  }

  test('account retirement before and after a read prevents adoption', () async {
    var current = false, count = 0;
    final auth = service((_) async {
      count++;
      current = false;
      return jsonResponse([source()]);
    });
    await expectLater(auth.getPlaylistAccess(authToken: 'cloud', isCurrent: () => current), throwsStateError);
    expect(count, 0);
    current = true;
    await expectLater(auth.getPlaylistAccess(authToken: 'cloud', isCurrent: () => current), throwsStateError);
    expect(count, 1);
  });

  test('revoke preflights the same recipient and source then deletes only the item', () async {
    final calls = <http.Request>[];
    final auth = service((request) async {
      calls.add(request);
      return request.method == 'GET' ? jsonResponse([source()]) : http.Response('', 204);
    });
    await auth.revokePlaylistAccess(authToken: 'cloud', grant: grant, isCurrent: () => true);
    expect(calls.map((r) => r.method), ['GET', 'DELETE']);
    expect(calls.last.url.toString(), 'https://plex.tv/api/v2/shared_items/99');
    expect(calls.last.headers['X-Plex-Token'], 'cloud');
  });

  for (final change in ['missing', 'source', 'recipient', 'uri']) {
    test('revoke rejects $change grant after confirmation', () async {
      final row = source();
      if (change == 'missing') row['sharedItems'] = [];
      if (change == 'source') row['id'] = 43;
      if (change == 'recipient') row['invited'] = {'id': 9, 'username': 'replacement'};
      if (change == 'uri') {
        row['sharedItems'] = [
          {'id': 99, 'uri': 'server://machine/com.plexapp.plugins.library/playlists/456/items'},
        ];
      }
      final calls = <String>[];
      final auth = service((r) async {
        calls.add(r.method);
        return jsonResponse([row]);
      });
      await expectLater(
        auth.revokePlaylistAccess(authToken: 'cloud', grant: grant, isCurrent: () => true),
        throwsStateError,
      );
      expect(calls, ['GET']);
    });
  }

  test('retirement during grant preflight cannot issue a delete', () async {
    var current = true;
    final calls = <String>[];
    final auth = service((r) async {
      calls.add(r.method);
      current = false;
      return jsonResponse([source()]);
    });
    await expectLater(
      auth.revokePlaylistAccess(authToken: 'cloud', grant: grant, isCurrent: () => current),
      throwsStateError,
    );
    expect(calls, ['GET']);
  });

  test('received grants cannot be mistaken for an owned revocation', () async {
    var calls = 0;
    final auth = service((_) async {
      calls++;
      return jsonResponse([]);
    });
    final received = PlexPlaylistAccessGrant.parseSources([source()], received: true).single;
    await expectLater(
      auth.revokePlaylistAccess(authToken: 'cloud', grant: received, isCurrent: () => true),
      throwsArgumentError,
    );
    expect(calls, 0);
  });

  test('failed delete is not retried and a late reply cannot acknowledge a new actor', () async {
    var current = true, writes = 0;
    final auth = service((r) async {
      if (r.method == 'GET') return jsonResponse([source()]);
      writes++;
      current = false;
      return http.Response('', 204);
    });
    await expectLater(
      auth.revokePlaylistAccess(authToken: 'cloud', grant: grant, isCurrent: () => current),
      throwsStateError,
    );
    expect(writes, 1);
  });

  for (final status in [401, 403, 500, 503]) {
    test('rejected revoke $status remains one mutation attempt', () async {
      var writes = 0;
      final auth = service((r) async {
        if (r.method == 'GET') return jsonResponse([source()]);
        writes++;
        return http.Response('', status);
      });
      await expectLater(
        auth.revokePlaylistAccess(authToken: 'cloud', grant: grant, isCurrent: () => true),
        throwsA(anything),
      );
      expect(writes, 1);
    });
  }
}
