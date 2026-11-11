import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../utils/web_socket_connect.dart';
import '../companion_remote/remote_auth_context.dart';
import '../companion_remote/remote_pairing_store.dart';
import 'music_connect_channel.dart';
import 'music_device_endpoint.dart';
import 'music_device_link.dart';
import 'music_device_peer.dart';
import 'music_relay_cipher.dart';
import 'music_relay_configuration.dart';

class MusicRelayConnection implements MusicDeviceConnection {
  MusicRelayConnection._({
    required this.target,
    required this.current,
    required this.changed,
    required List<RemoteAuthContext> contexts,
    required MusicDeviceEndpoint endpoint,
    required String hostClientId,
    required String name,
    required String deviceName,
    required String platform,
  }) {
    _cipher = MusicRelayCipher(
      isHost: false,
      contexts: contexts,
      endpoint: endpoint,
      expectedHostClientId: hostClientId,
      name: name,
      deviceName: deviceName,
      platform: platform,
      current: () => !_closed && current(),
      disconnected: () => unawaited(close()),
      send: (message) {
        final peer = _peer;
        if (peer == null || _socket == null) throw StateError('Music relay has no route');
        _socket!.add(jsonEncode({'peer': peer, 'data': message}));
      },
    );
  }

  static Future<MusicRelayConnection> connect({
    required MusicRelayTarget target,
    required List<RemoteAuthContext> contexts,
    required MusicDeviceEndpoint endpoint,
    required String hostClientId,
    required String name,
    required String deviceName,
    required String platform,
    required bool Function() current,
    required void Function() changed,
  }) async {
    final connection = MusicRelayConnection._(
      target: target,
      contexts: contexts,
      endpoint: endpoint,
      hostClientId: hostClientId,
      name: name,
      deviceName: deviceName,
      platform: platform,
      current: current,
      changed: changed,
    );
    try {
      await connection._connect();
      return connection;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  final MusicRelayTarget target;
  final bool Function() current;
  final void Function() changed;
  late final MusicRelayCipher _cipher;
  WebSocketConnectAttempt? _attempt;
  WebSocket? _socket;
  // Cancelled by close or when this exact socket is retired.
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? _subscription;
  String? _peer;
  bool _closed = false;

  @override
  MusicDeviceLink get output => _cipher.output;

  Future<void> _connect() async {
    final attempt = _attempt = WebSocketConnectAttempt(
      target.uri,
      connectTimeout: const Duration(seconds: 10),
      maxPayloadLength: 64 * 1024,
      followRedirects: false,
      headers: {
        'Authorization': 'Bearer ${target.control}',
        'X-Pleazyng-Music-Role': 'controller',
        'X-Pleazyng-Music-Room': target.room,
      },
    );
    final socket = await attempt.socket;
    if (_closed || !current()) {
      unawaited(socket.close());
      throw StateError('Music profile changed');
    }
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 20);
    _subscription = socket.listen(
      _receive,
      onDone: () => unawaited(close()),
      onError: (Object _) => unawaited(close()),
    );
    if (!await _cipher.authenticated || _closed || !current()) throw const RemotePairingRequired();
    changed();
  }

  void _receive(Object? raw) {
    if (_closed || !current()) return;
    try {
      if (raw is! String || raw.length > 64 * 1024) return unawaited(close());
      final message = jsonDecode(raw);
      if (message is! Map<String, dynamic>) return unawaited(close());
      if (message['event'] == 'joined' && _peer == null && isMusicConnectId(message['peer'])) {
        _peer = message['peer'] as String;
      } else if (message['peer'] == _peer && message['event'] == null && message['data'] is Map<String, dynamic>) {
        _cipher.receive(message['data']);
      } else {
        unawaited(close());
      }
    } catch (_) {
      unawaited(close());
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cipher.close();
    _attempt?.cancel();
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;
    await subscription?.cancel();
    if (socket != null) unawaited(socket.close().catchError((_) {}));
    _cipher.dispose();
    changed();
  }
}
