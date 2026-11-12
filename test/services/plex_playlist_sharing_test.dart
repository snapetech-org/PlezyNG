import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';

const _uri = 'server://machine/com.plexapp.plugins.library/playlists/123/items';
void main() {
  PlexAuthService auth(Future<http.Response> Function(http.Request) handler) {
    final service = PlexAuthService.forTesting(http: MediaServerHttpClient(client: MockClient(handler)));
    addTearDown(service.dispose);
    return service;
  }

  Future<int> grant(
    PlexAuthService service, {
    String token = 'account-token',
    String uri = _uri,
    String title = 'Night music',
    String recipient = 'friend@example.com',
    bool Function()? current,
  }) => service.grantPlaylistAccess(
    authToken: token,
    playlistUri: uri,
    title: title,
    recipient: recipient,
    isCurrent: current ?? () => true,
  );

  test('playlist grant uses Plex item sharing, JSON and the supplied account token', () async {
    http.Request? sent;
    final service = auth((request) async {
      sent = request;
      return http.Response('[{"sharedSourceId":42}]', 201, headers: {'content-type': 'application/json'});
    });
    expect(await grant(service, recipient: '  friend@example.com  '), 42);
    expect(sent!.method, 'POST');
    expect(sent!.url.toString(), 'https://plex.tv/api/v2/shared_items');
    expect(sent!.headers['X-Plex-Token'], 'account-token');
    expect(sent!.headers['Content-Type'], 'application/json');
    expect(jsonDecode(sent!.body), {
      'items': [
        {'uri': _uri, 'type': 'playlist', 'title': 'Night music'},
      ],
      'invitedEmail': 'friend@example.com',
    });
    expect(sent!.url.queryParameters, isEmpty);
  });

  for (final uri in [
    'https://attacker.example.com/playlists/123/items',
    'server://user:password@machine/com.plexapp.plugins.library/playlists/123/items',
    'server://machine:32400/com.plexapp.plugins.library/playlists/123/items',
    'server://machine/com.plexapp.plugins.library/library/metadata/123',
    'server://machine/com.plexapp.plugins.library/playlists/123/items?X-Plex-Token=token',
    'server://machine/com.plexapp.plugins.library/playlists/123/items#fragment',
    'server://machine/com.plexapp.plugins.library/playlists/../items',
    'server://machine/com.plexapp.plugins.library/playlists/%2f123/items',
  ]) {
    test('rejects non-playlist or credential-bearing URI $uri', () async {
      var calls = 0;
      final service = auth((_) async {
        calls++;
        return http.Response('', 200);
      });
      await expectLater(grant(service, uri: uri), throwsArgumentError);
      expect(calls, 0);
    });
  }

  test('empty, oversized or control-bearing recipients cannot issue a grant', () async {
    var calls = 0;
    final service = auth((_) async {
      calls++;
      return http.Response('', 200);
    });
    for (final recipient in ['', ' ', List.filled(321, 'x').join(), 'friend\n@example.com']) {
      await expectLater(grant(service, recipient: recipient), throwsArgumentError);
    }
    await expectLater(grant(service, token: ''), throwsArgumentError);
    await expectLater(grant(service, title: ''), throwsArgumentError);
    expect(calls, 0);
  });

  test('an expired account scope cannot issue a request', () async {
    var calls = 0;
    final service = auth((_) async {
      calls++;
      return http.Response('', 200);
    });
    await expectLater(grant(service, current: () => false), throwsStateError);
    expect(calls, 0);
  });

  test('a late acknowledgement cannot be adopted by a replacement account', () async {
    var current = true;
    final started = Completer<void>(), pending = Completer<http.Response>();
    final service = auth((_) {
      started.complete();
      return pending.future;
    });
    final operation = grant(service, current: () => current);
    final retired = expectLater(operation, throwsStateError);
    await started.future;
    current = false;
    pending.complete(http.Response('[{"sharedSourceId":42}]', 200, headers: {'content-type': 'application/json'}));
    await retired;
  });

  for (final body in [
    '[]',
    '{}',
    '[{}]',
    '[{"sharedSourceId":0}]',
    '[{"sharedSourceId":true}]',
    '[{"sharedSourceId":42},{"sharedSourceId":43}]',
  ]) {
    test('malformed sharing acknowledgement fails closed: $body', () async {
      final service = auth((_) async => http.Response(body, 200, headers: {'content-type': 'application/json'}));
      await expectLater(grant(service), throwsFormatException);
    });
  }

  for (final status in [401, 403, 409, 500, 503]) {
    test('HTTP $status is surfaced without retrying a mutation', () async {
      var calls = 0;
      final service = auth((_) async {
        calls++;
        return http.Response('{}', status, headers: {'content-type': 'application/json'});
      });
      await expectLater(grant(service), throwsA(isA<Exception>()));
      expect(calls, 1);
    });
  }

  test('a textual shared-source id is accepted without an invented item id', () async {
    final service = auth(
      (_) async => http.Response('[{"sharedSourceId":"42"}]', 200, headers: {'content-type': 'application/json'}),
    );
    expect(await grant(service), 42);
  });
}
