import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/companion_remote/remote_auth_context.dart';
import 'package:plezy/utils/certificate_trust.dart';
import 'package:plezy/services/music/music_device_endpoint.dart';
import 'package:plezy/services/music/music_device_session.dart';
import 'package:plezy/services/music/music_relay_configuration.dart';
import 'package:plezy/services/music/music_relay_connection.dart';
import 'package:plezy/services/music/music_relay_host.dart';

import '../../test_helpers/local_tls.dart';

class _Session implements MusicDeviceSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Endpoint extends MusicDeviceEndpoint {
  _Endpoint() : super(_Session(), allowed: () => true);
  @override
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> message) async => {'ok': true, 'echo': message};
}

RemoteAuthContext _identity(String client) => RemoteAuthContext(
  id: 'same-account',
  backend: 'plex',
  connectionId: 'server',
  homeSecret: List.filled(32, 7),
  discoveryKey: const [],
  clientIdentifier: client,
  userUuid: 'user',
  allowedUserUuids: const ['user'],
  isPaired: true,
);

class _Relay {
  late HttpServer server;
  WebSocket? host;
  final controllers = <String, WebSocket>{};
  final wires = <String>[];
  final errors = <Object>[];
  int sequence = 0;
  final credentials = MusicRelayHostCredentials('1' * 64, '2' * 64);
  Uri get uri => Uri.parse('wss://127.0.0.1:${server.port}/music/connect/relay');

  Future<void> start() async {
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, localTlsServer());
    server.listen((request) async {
      try {
        expect(request.uri.path, '/music/connect/relay');
        expect(request.uri.hasQuery, isFalse);
        expect(request.headers.value('X-Pleazyng-Music-Room'), credentials.room);
        final isHost = request.headers.value('X-Pleazyng-Music-Role') == 'host';
        expect(request.headers.value('Authorization'), 'Bearer ${isHost ? credentials.secret : credentials.control}');
        if (isHost) expect(request.headers.value('X-Pleazyng-Music-Control'), credentials.control);
        final socket = await WebSocketTransformer.upgrade(request, compression: CompressionOptions.compressionOff);
        final peer = (++sequence).toRadixString(16).padLeft(32, '0');
        if (isHost) {
          host = socket;
        } else {
          controllers[peer] = socket;
          final event = jsonEncode({'event': 'joined', 'peer': peer});
          socket.add(event);
          host!.add(event);
        }
        socket.listen(
          (raw) {
            wires.add(raw as String);
            final message = jsonDecode(raw) as Map<String, dynamic>;
            if (isHost) {
              final target = controllers[message['peer']];
              if (message['event'] == 'close') {
                unawaited(target?.close());
              } else {
                target?.add(raw);
              }
            } else {
              host?.add(jsonEncode({'peer': peer, 'data': message['data']}));
            }
          },
          onDone: () {
            if (isHost) {
              if (identical(host, socket)) host = null;
            } else {
              controllers.remove(peer);
              host?.add(jsonEncode({'event': 'left', 'peer': peer}));
            }
          },
        );
      } catch (error) {
        errors.add(error);
      }
    });
  }

  Future<void> close() async {
    await host?.close();
    for (final controller in controllers.values.toList()) {
      await controller.close();
    }
    await server.close(force: true);
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Music relay did not reach the expected state');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real WSS relay authenticates, chunks requests and retains receiver after controller disconnect', () async {
    CertificateTrust.debugSetUserAuthoritiesForTesting(localTlsAuthorityContext());
    addTearDown(CertificateTrust.debugReset);
    final relay = _Relay();
    await relay.start();
    addTearDown(relay.close);
    await HttpOverrides.runZoned(() async {
      final host = MusicRelayHost(
        uri: relay.uri,
        credentials: relay.credentials,
        contexts: [_identity('host')],
        endpoint: _Endpoint(),
        current: () => true,
        changed: () {},
      );
      addTearDown(host.close);
      await _until(() => host.connected);
      final target = MusicRelayTarget.read(host.invitation)!;
      Future<MusicRelayConnection> connect() => MusicRelayConnection.connect(
        target: target,
        contexts: [_identity('phone')],
        endpoint: _Endpoint(),
        hostClientId: 'host',
        name: 'Receiver',
        deviceName: 'Phone',
        platform: 'ios',
        current: () => true,
        changed: () {},
      );
      final first = await connect();
      addTearDown(first.close);
      final payload = {'op': 'test', 'title': 'Private song', 'queue': List.filled(4096, 'private-track-identity')};
      expect((await first.output.request(payload))?['echo'], payload);
      expect(relay.wires.join(), isNot(contains('Private song')));
      expect(relay.wires.join(), isNot(contains('private-track-identity')));
      await first.close();
      expect(host.connected, isTrue);
      final second = await connect();
      addTearDown(second.close);
      expect((await second.output.request({'op': 'test'}))?['ok'], isTrue);
      expect(relay.errors, isEmpty);
      await second.close();
      host.close();
    }, createHttpClient: (_) => localTlsClient());
  });
}
