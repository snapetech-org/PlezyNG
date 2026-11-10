import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/companion_remote/remote_auth_context.dart';
import 'package:plezy/services/music/music_device_endpoint.dart';
import 'package:plezy/services/music/music_device_session.dart';
import 'package:plezy/services/music/music_relay_cipher.dart';

class _Session implements MusicDeviceSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Endpoint extends MusicDeviceEndpoint {
  _Endpoint() : super(_Session(), allowed: () => true);
  @override
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> message) async => {'ok': true, 'echo': message};
}

RemoteAuthContext _context(String client, {int secret = 9}) => RemoteAuthContext(
  id: 'pair',
  backend: 'plex',
  connectionId: 'server',
  homeSecret: List.filled(32, secret),
  discoveryKey: const [],
  clientIdentifier: client,
  userUuid: 'user',
  allowedUserUuids: const ['user'],
  isPaired: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mismatch in [false, true]) {
    test('relay proves pairing and receiver identity with matching secret ${!mismatch}', () async {
      late MusicRelayCipher host, controller;
      final wires = <Map<String, dynamic>>[];
      host = MusicRelayCipher(
        isHost: true,
        contexts: [_context('host')],
        endpoint: _Endpoint(),
        name: 'Controller',
        current: () => true,
        disconnected: () {},
        send: (message) {
          wires.add(message);
          controller.receive(message);
        },
      );
      controller = MusicRelayCipher(
        isHost: false,
        contexts: [_context('phone', secret: mismatch ? 8 : 9)],
        endpoint: _Endpoint(),
        expectedHostClientId: 'host',
        name: 'Living room',
        current: () => true,
        disconnected: () {},
        send: host.receive,
      );
      addTearDown(host.dispose);
      addTearDown(controller.dispose);
      host.start();
      if (mismatch) {
        expect(await host.authenticated, isFalse);
        controller.close();
        expect(await controller.authenticated, isFalse);
      } else {
        expect(await controller.authenticated, isTrue);
        expect(await host.authenticated, isTrue);
        final payload = {'op': 'test', 'title': 'Private library title', 'queue': List.filled(1000, 'track')};
        final reply = await controller.channel.request(payload);
        expect(reply?['echo'], payload);
        expect(jsonEncode(wires), isNot(contains('Private library title')));
        final replay = wires.last;
        controller.receive(replay);
        await pumpEventQueue();
        expect(controller.ready, isFalse);
      }
    });
  }

  test('relay invitation cannot substitute a different receiver', () async {
    late MusicRelayCipher host, controller;
    host = MusicRelayCipher(
      isHost: true,
      contexts: [_context('impostor')],
      endpoint: _Endpoint(),
      name: 'Controller',
      current: () => true,
      disconnected: () {},
      send: (message) => controller.receive(message),
    );
    controller = MusicRelayCipher(
      isHost: false,
      contexts: [_context('phone')],
      endpoint: _Endpoint(),
      expectedHostClientId: 'expected-host',
      name: 'Living room',
      current: () => true,
      disconnected: () {},
      send: host.receive,
    );
    addTearDown(host.dispose);
    addTearDown(controller.dispose);
    host.start();
    expect(await controller.authenticated, isFalse);
  });

  test('a retired profile cannot receive or send commands', () async {
    var current = true;
    late MusicRelayCipher host, controller;
    host = MusicRelayCipher(
      isHost: true,
      contexts: [_context('host')],
      endpoint: _Endpoint(),
      name: 'Controller',
      current: () => current,
      disconnected: () {},
      send: (message) => controller.receive(message),
    );
    controller = MusicRelayCipher(
      isHost: false,
      contexts: [_context('phone')],
      endpoint: _Endpoint(),
      expectedHostClientId: 'host',
      name: 'Living room',
      current: () => current,
      disconnected: () {},
      send: host.receive,
    );
    addTearDown(host.dispose);
    addTearDown(controller.dispose);
    host.start();
    expect(await controller.authenticated, isTrue);
    current = false;
    expect(await controller.channel.request({'op': 'control'}), isNull);
    expect(controller.output.connected, isFalse);
  });
}
