import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/sources/gpodder_client.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/source_transport.dart';

GpodderConfig configuration({String endpoint = 'https://sync.example/prefix'}) => GpodderConfig(
  endpoint: endpoint,
  username: 'name@example.com',
  password: 'secret',
  device: 'plezyng-unique-device',
);

void main() {
  test('gpodder requests preserve server prefixes and scope HTTP authentication', () async {
    final requests = <http.Request>[];
    final client = GpodderClient(
      configuration(),
      transport: SourceTransport(
        client: MockClient((request) async {
          requests.add(request);
          expect(request.url.host, 'sync.example');
          expect(request.headers['authorization'], 'Basic ${base64Encode(utf8.encode('name@example.com:secret'))}');
          if (request.method == 'POST' && request.url.path.endsWith('login.json')) {
            return http.Response('', 200);
          }
          return http.Response('{"add":[],"remove":[],"timestamp":42}', 200);
        }),
      ),
    );
    addTearDown(client.close);
    await client.verifyLogin();
    final changes = await client.subscriptionChanges(20);
    expect(changes.timestamp, 42);
    expect(requests.first.url.pathSegments, ['prefix', 'api', '2', 'auth', 'name@example.com', 'login.json']);
    expect(requests.last.url.queryParameters['since'], '20');
  });
  test('authenticated redirects are rejected without contacting their target', () async {
    var calls = 0;
    final client = GpodderClient(
      configuration(),
      transport: SourceTransport(
        client: MockClient((request) async {
          calls++;
          return http.Response('', 302, headers: {'location': 'https://other.example/login'});
        }),
      ),
    );
    addTearDown(client.close);
    await expectLater(client.verifyLogin(), throwsA(isA<SourceException>()));
    expect(calls, 1);
  });
  test('regressing cursors cannot acknowledge unprocessed subscription history', () async {
    final client = GpodderClient(
      configuration(),
      transport: SourceTransport(
        client: MockClient((_) async => http.Response('{"add":[],"remove":[],"timestamp":9}', 200)),
      ),
    );
    addTearDown(client.close);
    await expectLater(client.subscriptionChanges(10), throwsA(isA<SourceException>()));
  });
  test('rotated credentials and parameter order preserve podcast sync identity', () {
    expect(
      podcastSyncIdentity('https://feed.example/rss?token=one', 'https://cdn.example/a.mp3?b=2&a=1&token=one'),
      podcastSyncIdentity('https://feed.example/rss?token=two', 'https://cdn.example/a.mp3?a=1&b=2&token=two'),
    );
    expect(
      podcastSyncIdentity('https://feed.example/rss', 'https://cdn.example/a.mp3?id=1'),
      isNot(podcastSyncIdentity('https://feed.example/rss', 'https://cdn.example/a.mp3?id=2')),
    );
  });
  test('server configuration rejects insecure and credential-bearing endpoints', () {
    for (final endpoint in [
      'http://sync.example',
      'https://user:pass@sync.example',
      'https://sync.example?token=secret',
    ]) {
      expect(() => configuration(endpoint: endpoint), throwsA(isA<SourceException>()));
    }
  });
}
