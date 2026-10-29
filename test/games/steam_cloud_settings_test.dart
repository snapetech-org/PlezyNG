import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/games/steam_cloud_settings.dart';

void main() {
  const account = '76561198000000001';
  test('unknown or mismatched identity cannot become observed false', () {
    expect(
      SteamCloudSetting.parse({'status': 'observed', 'steamId': 'other', 'enabled': false}, account).status,
      'unknown',
    );
    expect(SteamCloudSetting.parse({'status': 'observed', 'steamId': account}, account).enabled, isNull);
  });
  test('authenticated exchange requires permission and preserves reviewed booleans', () async {
    late SteamCloudSettingsExchange host, client;
    var allowed = false, calls = 0;
    host = SteamCloudSettingsExchange(
      isHost: true,
      allowed: () => allowed,
      execute: (r, current) async {
        calls++;
        expect(current(), isTrue);
        return SteamCloudSetting('observed', steamId: account, enabled: r['enabled'] as bool? ?? true);
      },
      send: (r) => client.receive(r),
    );
    client = SteamCloudSettingsExchange(
      isHost: false,
      allowed: () => false,
      execute: (_, _) => throw StateError('remote'),
      send: host.receive,
    );
    addTearDown(host.close);
    addTearDown(client.close);
    expect((await client.request(account)).status, 'denied');
    expect(calls, 0);
    allowed = true;
    expect((await client.request(account)).enabled, true);
    expect((await client.request(account, expected: true, enabled: false)).enabled, false);
    expect(calls, 2);
  });
  test('duplicate request and unknown arguments cannot execute', () async {
    var calls = 0;
    final host = SteamCloudSettingsExchange(
      isHost: true,
      allowed: () => true,
      execute: (r, current) async {
        calls++;
        return const SteamCloudSetting('unavailable');
      },
      send: (_) {},
    );
    addTearDown(host.close);
    final message = {
      'version': 1,
      'request': 'a' * 32,
      'op': 'set',
      'steamId': account,
      'expected': true,
      'enabled': false,
    };
    host.receive(message);
    await Future<void>.delayed(Duration.zero);
    host.receive(message);
    host.receive({...message, 'request': 'b' * 32, 'script': 'arbitrary'});
    host.receive({...message, 'request': 'c' * 32, 'enabled': 1});
    expect(calls, 1);
  });
  test('profile or permission retirement invalidates asynchronous work', () async {
    final pending = Completer<SteamCloudSetting>();
    bool Function()? current;
    final replies = <Map<String, dynamic>>[];
    final host = SteamCloudSettingsExchange(
      isHost: true,
      allowed: () => true,
      execute: (r, check) {
        current = check;
        return pending.future;
      },
      send: replies.add,
    );
    host.receive({'version': 1, 'request': 'a' * 32, 'op': 'read', 'steamId': account});
    expect(current!(), isTrue);
    host.close();
    expect(current!(), isFalse);
    pending.complete(const SteamCloudSetting('observed', steamId: account, enabled: true));
    await Future<void>.delayed(Duration.zero);
    expect(replies, isEmpty);
  });
  test('old peers and malformed accounts never issue requests', () async {
    final sent = <Map<String, dynamic>>[];
    final client = SteamCloudSettingsExchange(
      isHost: false,
      allowed: () => false,
      execute: (_, _) => throw StateError('remote'),
      send: sent.add,
    );
    addTearDown(client.close);
    expect((await client.request('123')).status, 'unavailable');
    expect((await client.request(account, enabled: true)).status, 'unavailable');
    expect(sent, isEmpty);
  });
}
