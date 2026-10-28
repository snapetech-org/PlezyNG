import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/games/steam_cloud_client.dart';
import 'package:plezy/services/trackers/oauth_proxy_client.dart';

const identity = '76561198000000001';
final grant = List.filled(43, 'a').join();
final file = SteamCloudFile(
  name: 'save/slot1.sav',
  size: 3,
  sha: 'a9993e364706816aba3e25717850c26c9cd0d89d',
  modified: _epoch,
);
final _epoch = DateTime.utc(2026);

void main() {
  SteamCloudClient client(http.Client httpClient, {bool write = false}) {
    final c = SteamCloudClient(httpClient: httpClient, baseUri: Uri.parse('https://plezy.test'));
    c.authorize(
      OAuthProxyResult(accessToken: '', steamId: identity, steamCloudToken: grant),
      appId: 620,
      steamId: identity,
      write: write,
    );
    addTearDown(c.retire);
    return c;
  }

  test('read-only Cloud grants cannot write and no catalog token is promoted', () async {
    var requests = 0;
    final c = client(
      MockClient((r) async {
        requests++;
        return http.Response('', 204);
      }),
    );
    await expectLater(c.replace(file, Uint8List(0)), throwsA(isA<SteamCloudUnavailable>()));
    await expectLater(c.delete(file), throwsA(isA<SteamCloudUnavailable>()));
    expect(requests, 0);
    final empty = SteamCloudClient(
      httpClient: MockClient((_) async => http.Response('', 204)),
      baseUri: Uri.parse('https://plezy.test'),
    );
    addTearDown(empty.retire);
    expect(
      () => empty.authorize(
        OAuthProxyResult(accessToken: grant, steamId: identity, steamCatalogToken: grant),
        appId: 620,
        steamId: identity,
        write: true,
      ),
      throwsA(isA<SteamCloudUnavailable>()),
    );
  });
  test('download validates identity, file name, size and checksum', () async {
    var bad = false;
    final c = client(
      MockClient((r) async {
        if (r.method == 'DELETE') return http.Response('', 204);
        expect(r.url.query, isEmpty);
        expect(r.followRedirects, isFalse);
        expect(r.headers['Authorization'], 'Bearer $grant');
        expect(jsonDecode(r.body)['expectedSha'], file.sha);
        return http.Response(
          jsonEncode({
            'name': file.name,
            'sha': file.sha,
            'data': base64Encode(bad ? [0, 0, 0] : [97, 98, 99]),
          }),
          200,
        );
      }),
    );
    expect(await c.download(file), [97, 98, 99]);
    bad = true;
    await expectLater(c.download(file), throwsA(isA<SteamCloudUnavailable>()));
  });
  test('an ambiguous mutation is never retried and retirement revokes once', () async {
    final methods = <String>[];
    final c = client(
      MockClient((r) async {
        methods.add(r.method);
        if (r.method == 'DELETE') return http.Response('', 204);
        final body = jsonDecode(r.body);
        expect(body['action'], 'upload');
        expect(body['filename'], file.name);
        expect(body['expectedSha'], file.sha);
        expect(body['data'], 'AQID');
        return http.Response('{"error":"refresh_required"}', 409);
      }),
      write: true,
    );
    await expectLater(
      c.replace(file, Uint8List.fromList([1, 2, 3])),
      throwsA(isA<SteamCloudUnavailable>().having((e) => e.refreshRequired, 'needs review', true)),
    );
    expect(methods, ['POST']);
    await Future.wait([c.retire(), c.retire()]);
    expect(methods, ['POST', 'DELETE']);
    await expectLater(c.files(), throwsA(isA<SteamCloudUnavailable>()));
  });
  test('bounded responses, hard timeout and authorization URLs fail closed', () async {
    final c = SteamCloudClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'session': 'a' * 24, 'url': 'https://evil.test/auth/steam-cloud?state=${'b' * 24}'}),
          200,
        ),
      ),
      baseUri: Uri.parse('https://plezy.test'),
    );
    addTearDown(c.retire);
    await expectLater(c.start(grant, 620), throwsA(isA<SteamCloudUnavailable>()));
    final oversized = client(MockClient((_) async => http.Response(' ' * (2 * 1024 * 1024 + 1), 200)));
    await expectLater(oversized.files(), throwsA(isA<SteamCloudUnavailable>()));
    final pending = Completer<http.Response>();
    final slow = SteamCloudClient(
      httpClient: MockClient((_) => pending.future),
      baseUri: Uri.parse('https://plezy.test'),
      requestTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(slow.retire);
    await expectLater(slow.capabilities(grant, 620), throwsA(isA<SteamCloudUnavailable>()));
    pending.complete(http.Response('{}', 200));
  });
  test('listing cannot cross an account, AppID or read-only capability', () async {
    final c = client(
      MockClient((r) async {
        if (r.method == 'DELETE') return http.Response('', 204);
        return http.Response(jsonEncode({'steamId': identity, 'appId': 999, 'write': false, 'files': []}), 200);
      }),
    );
    await expectLater(c.files(), throwsA(isA<SteamCloudUnavailable>()));
  });
}
