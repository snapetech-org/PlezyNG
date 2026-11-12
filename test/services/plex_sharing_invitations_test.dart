import 'package:drift/native.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/plex/plex_source_invitation.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/services/music/plex_sharing_invitations.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

Map<String, Object?> _invite({
  int id = 42,
  int owner = 7,
  int recipient = 8,
  String name = 'Owner',
  String? status = 'pending',
}) => {
  'id': id,
  'status': ?status,
  'owner': {'id': owner, 'username': name},
  'invited': {'id': recipient},
};
PlexSourceInvitation _entry() => PlexSourceInvitation.parsePending([_invite()]).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
  });
  PlexAuthService auth(Future<http.Response> Function(http.Request) handler) {
    final value = PlexAuthService.forTesting(http: MediaServerHttpClient(client: MockClient(handler)));
    addTearDown(value.dispose);
    return value;
  }

  test('pending route carries original cloud token with no item expansion', () async {
    final service = auth((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://plex.tv/api/v2/shared_sources/invites/received/pending');
      expect(request.headers['X-Plex-Token'], 'cloud');
      return jsonResponse([_invite(status: null), _invite(id: 43, status: 'accepted')]);
    });
    final pending = await service.getPendingSourceInvitations(authToken: 'cloud', isCurrent: () => true);
    expect(pending.single.ownerName, 'Owner');
    expect(pending.single.recipientId, 8);
    expect(() => pending.clear(), throwsUnsupportedError);
  });

  for (final data in <Object?>[
    null,
    {},
    [42],
    [_invite(), _invite()],
    [_invite(owner: 0)],
    [_invite(recipient: 0)],
    [_invite(name: '\n')],
    List.generate(513, (_) => _invite()),
  ]) {
    test('invalid/ambiguous pending identities cannot become decisions (${data.runtimeType})', () {
      expect(() => PlexSourceInvitation.parsePending(data), throwsFormatException);
    });
  }

  for (final accept in [true, false]) {
    test('confirmed entire invitation preflights before one $accept mutation', () async {
      final calls = <http.Request>[];
      final service = auth((request) async {
        calls.add(request);
        return request.method == 'GET' ? jsonResponse([_invite()]) : http.Response('', 204);
      });
      await service.respondToSourceInvitation(
        authToken: 'cloud',
        invitation: _entry(),
        accept: accept,
        isCurrent: () => true,
      );
      expect(calls.map((r) => r.method), ['GET', accept ? 'POST' : 'DELETE']);
      expect(calls.last.url.path, '/api/v2/shared_sources/42${accept ? '/accept' : ''}');
      expect(calls.last.headers['X-Plex-Token'], 'cloud');
      expect(calls.last.body, isEmpty);
    });

    for (final change in ['missing', 'owner', 'recipient', 'name', 'accepted', 'source']) {
      test('$change invitation cannot receive an old $accept decision', () async {
        final calls = <String>[];
        final row = _invite(
          id: change == 'source' ? 43 : 42,
          owner: change == 'owner' ? 9 : 7,
          recipient: change == 'recipient' ? 9 : 8,
          name: change == 'name' ? 'New name' : 'Owner',
          status: change == 'accepted' ? 'accepted' : 'pending',
        );
        final service = auth((r) async {
          calls.add(r.method);
          return jsonResponse(change == 'missing' ? [] : [row]);
        });
        await expectLater(
          service.respondToSourceInvitation(
            authToken: 'cloud',
            invitation: _entry(),
            accept: accept,
            isCurrent: () => true,
          ),
          throwsStateError,
        );
        expect(calls, ['GET']);
      });
    }

    test('retired read or late mutation acknowledgement cannot accept $accept', () async {
      for (final retireOnWrite in [false, true]) {
        var current = true;
        final calls = <String>[];
        final service = auth((r) async {
          calls.add(r.method);
          if ((r.method != 'GET') == retireOnWrite) current = false;
          return r.method == 'GET' ? jsonResponse([_invite()]) : http.Response('', 204);
        });
        await expectLater(
          service.respondToSourceInvitation(
            authToken: 'cloud',
            invitation: _entry(),
            accept: accept,
            isCurrent: () => current,
          ),
          throwsStateError,
        );
        expect(calls, ['GET', if (retireOnWrite) accept ? 'POST' : 'DELETE']);
      }
    });

    test('lost $accept acknowledgement never retries a mutation automatically', () async {
      var writes = 0;
      final service = auth((r) async {
        if (r.method == 'GET') return jsonResponse([_invite()]);
        writes++;
        return http.Response('', 503);
      });
      await expectLater(
        service.respondToSourceInvitation(
          authToken: 'cloud',
          invitation: _entry(),
          accept: accept,
          isCurrent: () => true,
        ),
        throwsA(anything),
      );
      expect(writes, 1);
    });
  }

  test('retirement before a cloud read makes no request', () async {
    var calls = 0;
    final service = auth((_) async {
      calls++;
      return jsonResponse([]);
    });
    await expectLater(
      service.getPendingSourceInvitations(authToken: 'cloud', isCurrent: () => false),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('catalog decisions cannot be forged, duplicated or retried without fresh pending data', () async {
    final write = Completer<http.Response>();
    var writes = 0;
    final service = auth((r) async {
      if (r.method == 'GET') return jsonResponse([_invite()]);
      writes++;
      return write.future;
    });
    final client = testPlexClient(handler: (_) async => jsonResponse({}))..plexAccountToken = 'cloud';
    final catalog = PlexSharingInvitations(client: client, auth: service, isCurrent: () => true);
    final entries = await catalog.refresh();
    await expectLater(catalog.respond(_entry(), accept: true), throwsStateError);
    final first = catalog.respond(entries.single, accept: true);
    await expectLater(catalog.respond(entries.single, accept: false), throwsStateError);
    await expectLater(catalog.refresh(), throwsStateError);
    write.complete(http.Response('', 204));
    await first;
    await expectLater(catalog.respond(entries.single, accept: true), throwsStateError);
    expect(writes, 1);
  });

  test('new refresh retires an older in-flight read without replacing its result', () async {
    final old = Completer<http.Response>();
    var reads = 0;
    final service = auth((r) async => ++reads == 1 ? old.future : jsonResponse([_invite(id: 43)]));
    final client = testPlexClient(handler: (_) async => jsonResponse({}))..plexAccountToken = 'cloud';
    final catalog = PlexSharingInvitations(client: client, auth: service, isCurrent: () => true);
    final retired = expectLater(catalog.refresh(), throwsStateError);
    final entries = await catalog.refresh();
    expect(entries.single.id, 43);
    old.complete(jsonResponse([_invite()]));
    await retired;
  });

  for (final retire in ['profile', 'authentication', 'token']) {
    test('catalog binds the original $retire throughout decision preflight', () async {
      var current = true;
      final preflight = Completer<http.Response>();
      var reads = 0, writes = 0;
      final service = auth((r) async {
        if (r.method != 'GET') {
          writes++;
          return http.Response('', 204);
        }
        return ++reads == 1 ? jsonResponse([_invite()]) : preflight.future;
      });
      final client = testPlexClient(
        handler: (_) async => jsonResponse({
          'MediaContainer': {'machineIdentifier': 'server-1'},
        }),
      )..plexAccountToken = 'cloud';
      final catalog = PlexSharingInvitations(client: client, auth: service, isCurrent: () => current);
      final entries = await catalog.refresh();
      final rejected = expectLater(catalog.respond(entries.single, accept: true), throwsStateError);
      if (retire == 'profile') current = false;
      if (retire == 'authentication') {
        await client.applyProfileUpdate(newToken: 'replacement', newProfileScopeId: client.profileScopeId);
      }
      if (retire == 'token') client.plexAccountToken = 'replacement';
      preflight.complete(jsonResponse([_invite()]));
      await rejected;
      expect(writes, 0);
      expect(catalog.current, isFalse);
    });
  }
}
