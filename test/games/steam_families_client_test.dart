import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/games/steam_families_client.dart';

const familyIdentity = '76561198000000001';
Map<String, dynamic> familyStateJson() => {
  'family_groupid': '18446744073709551615',
  'is_not_member_of_any_group': false,
  'role': 1,
  'cooldown_seconds_remaining': 0,
  'can_undelete_last_joined_family': false,
  'pending_group_invites': [],
  'family_group': {
    'name': 'Living room',
    'free_spots': 5,
    'members': [
      {'steamid': familyIdentity, 'role': 1},
    ],
    'pending_invites': [],
  },
};

void main() {
  SteamFamiliesClient make(http.Client httpClient, {String origin = 'https://plezy.test'}) {
    final c = SteamFamiliesClient(
      catalog: 'a' * 43,
      steamId: familyIdentity,
      httpClient: httpClient,
      baseUri: Uri.parse(origin),
    );
    addTearDown(c.retire);
    return c;
  }

  Map<String, dynamic> authorization({bool ready = false, String? id, String? challenge}) => {
    'session': 'b' * 43,
    'steamId': id ?? familyIdentity,
    'expires': DateTime.now().add(const Duration(minutes: 3)).millisecondsSinceEpoch ~/ 1000,
    'pollSeconds': 5,
    'authorized': ready,
    'challenge': challenge ?? (ready ? '' : 'https://s.team/q/1/123456'),
  };
  test('QR authority is separate, account-bound and retired exactly once', () async {
    final operations = <String>[];
    final c = make(
      MockClient((r) async {
        expect(r.url.scheme, 'https');
        expect(r.url.query, isEmpty);
        expect(r.followRedirects, isFalse);
        expect(r.headers['Authorization'], 'Bearer ${'a' * 43}');
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        final op = body['operation'] as String;
        operations.add(op);
        if (op == 'start') {
          expect(body['consent'], isTrue);
          expect(body.containsKey('session'), isFalse);
          return http.Response(jsonEncode(authorization()), 200);
        }
        expect(body['session'], 'b' * 43);
        if (op == 'poll') return http.Response(jsonEncode(authorization(ready: true)), 200);
        if (op == 'state') {
          return http.Response(jsonEncode({'steamId': familyIdentity, 'state': familyStateJson()}), 200);
        }
        return http.Response('', 204);
      }),
    );
    await expectLater(c.state(), throwsA(isA<SteamFamiliesUnavailable>()));
    expect(operations, isEmpty);
    await c.start();
    expect(c.authorized, isFalse);
    expect(await c.poll(), isTrue);
    expect((await c.state()).familyId, '18446744073709551615');
    await c.retire();
    await c.retire();
    expect(operations, ['start', 'poll', 'state', 'close']);
    await expectLater(c.state(), throwsA(isA<SteamFamiliesUnavailable>()));
  });
  test('rejects wrong-account and hostile QR challenges without launching them', () async {
    for (final body in [
      authorization(id: '76561198000000002'),
      authorization(challenge: 'https://evil.test/q/1/2'),
      authorization(challenge: 'https://s.team/q/1/2?secret=x'),
    ]) {
      final c = make(
        MockClient(
          (r) async => jsonDecode(r.body)['operation'] == 'close'
              ? http.Response('', 204)
              : http.Response(jsonEncode(body), 200),
        ),
      );
      await expectLater(c.start(), throwsA(isA<SteamFamiliesUnavailable>()));
      expect(c.authorized, isFalse);
      expect(c.challenge, isNull);
      await c.retire();
    }
  });
  test('review response cannot replace the requested target; ambiguous commit is not retried', () async {
    var tamper = true, commits = 0;
    final c = make(
      MockClient((r) async {
        final body = jsonDecode(r.body);
        switch (body['operation']) {
          case 'start':
            return http.Response(jsonEncode(authorization()), 200);
          case 'poll':
            return http.Response(jsonEncode(authorization(ready: true)), 200);
          case 'review':
            return http.Response(
              jsonEncode({
                'review': 'c' * 43,
                'change': {'action': 'rename', 'name': tamper ? 'Other' : 'New'},
                'state': familyStateJson(),
              }),
              200,
            );
          case 'commit':
            commits++;
            expect(body.keys.toSet(), {'operation', 'session', 'review'});
            return http.Response('outcome unknown', 409);
          default:
            return http.Response('', 204);
        }
      }),
    );
    await c.start();
    await c.poll();
    const change = SteamFamilyChange('rename', name: 'New');
    await expectLater(c.review(change), throwsA(isA<SteamFamiliesUnavailable>()));
    tamper = false;
    final review = await c.review(change);
    await expectLater(
      c.commit(review),
      throwsA(isA<SteamFamiliesUnavailable>().having((e) => e.refreshRequired, 'refresh', isTrue)),
    );
    expect(commits, 1);
  });
  test('older servers fall back while insecure origins and oversized replies fail closed', () async {
    final old = make(MockClient((_) async => http.Response('', 404)));
    expect(await old.available(), isFalse);
    var calls = 0;
    final insecure = make(
      MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
      origin: 'http://plezy.test',
    );
    await expectLater(insecure.available(), throwsA(isA<SteamFamiliesUnavailable>()));
    expect(calls, 0);
    final big = make(MockClient((_) async => http.Response(' ' * (128 * 1024 + 1), 200)));
    await expectLater(big.available(), throwsA(isA<SteamFamiliesUnavailable>()));
  });
}
