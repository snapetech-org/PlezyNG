import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });
  tearDown(() => db.close());

  test('a server-supplied person tag cannot select the cloud destination', () async {
    final requests = <http.Request>[];
    final client = testPlexClient(
      handler: (request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'MediaContainer': request.url.host == 'plex.example.com'
                ? {
                    'Directory': [
                      {'tagKey': 'https://attacker.example/steal'},
                    ],
                  }
                : {'Metadata': <Object>[]},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    client.plexAccountToken = 'account-token';
    addTearDown(client.close);

    await client.fetchPersonDetails('person');
    expect(requests.map((request) => request.url.host), ['plex.example.com', 'discover.provider.plex.tv']);
    expect(requests.last.headers['X-Plex-Token'], 'account-token');
  });

  test('cloud redirects cannot forward Plex credentials to another origin', () async {
    final requests = <http.Request>[];
    final client = testPlexClient(
      handler: (request) async {
        requests.add(request);
        if (request.url.host == 'epg.provider.plex.tv') {
          return http.Response('', 302, headers: {'location': 'https://other.example/favorites'});
        }
        return http.Response('{"MediaContainer":{}}', 200, headers: {'content-type': 'application/json'});
      },
    );
    addTearDown(client.close);

    expect(await client.liveTv.fetchFavoriteChannels(), isEmpty);
    expect(requests.map((request) => request.url.host), ['epg.provider.plex.tv', 'other.example']);
    expect(requests.first.headers['X-Plex-Token'], 'token');
    expect(requests.last.headers['X-Plex-Token'], isNull);
    expect(requests.last.headers['X-Plex-Client-Identifier'], isNull);
  });

  for (final graceful in [false, true]) {
    for (final discover in [false, true]) {
      test('closing Plex cancels cloud requests (graceful: $graceful, discover: $discover)', () async {
        final transport = _PendingCloudClient();
        final client = testPlexClient(httpClient: transport)..plexAccountToken = 'account-token';
        addTearDown(client.close);
        final request = discover ? client.fetchPersonDetails('person') : client.liveTv.fetchFavoriteChannels();
        final failed = expectLater(
          request,
          throwsA(isA<MediaServerHttpException>().having((error) => error.isCancellation, 'cancelled', true)),
        );
        await transport.started.future;
        if (graceful) {
          await client.closeGracefully();
        } else {
          client.close();
        }
        await failed;
        expect(transport.closeCalls, 1, reason: 'the parent closes the shared connection pool exactly once');
      });
    }
  }
}

class _PendingCloudClient extends http.BaseClient {
  final started = Completer<void>();
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'plex.example.com') {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"MediaContainer":{"Directory":[{"tagKey":"person"}]}}')),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final response = Completer<http.StreamedResponse>();
    unawaited(
      (request as http.Abortable).abortTrigger!.then((_) {
        if (!response.isCompleted) response.completeError(http.RequestAbortedException(request.url));
      }),
    );
    started.complete();
    return response.future;
  }

  @override
  void close() {
    closeCalls++;
  }
}
