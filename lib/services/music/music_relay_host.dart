import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../utils/web_socket_connect.dart';
import '../companion_remote/remote_auth_context.dart';
import 'music_connect_channel.dart';
import 'music_device_endpoint.dart';
import 'music_relay_cipher.dart';
import 'music_relay_configuration.dart';

/// One outbound receiver socket. Each controller has independent E2E keys.
/// Closing or reconnecting this transport leaves committed audio playing.
class MusicRelayHost {
  MusicRelayHost({
    required this.uri,
    required this.credentials,
    required this.contexts,
    required this.endpoint,
    required this.current,
    required this.changed,
  }) {
    unawaited(_connect());
  }

  final Uri uri;
  final MusicRelayHostCredentials credentials;
  final List<RemoteAuthContext> contexts;
  final MusicDeviceEndpoint endpoint;
  final bool Function() current;
  final void Function() changed;
  final _controllers = <String, MusicRelayCipher>{};
  WebSocketConnectAttempt? _attempt;
  WebSocket? _socket;
  // Cancelled by close or when this exact socket is retired.
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
  bool _closed = false;
  bool _connecting = false;

  bool get connected => !_closed && current() && _socket != null;
  Map<String, dynamic>? get invitation =>
      connected ? MusicRelayTarget(uri: uri, room: credentials.room, control: credentials.control).toJson() : null;

  Future<void> _connect() async {
    if (_closed || !current() || _connecting) return;
    _connecting = true;
    final attempt = _attempt = WebSocketConnectAttempt(
      uri,
      connectTimeout: const Duration(seconds: 10),
      maxPayloadLength: 64 * 1024,
      followRedirects: false,
      headers: {
        'Authorization': 'Bearer ${credentials.secret}',
        'X-Pleazyng-Music-Role': 'host',
        'X-Pleazyng-Music-Room': credentials.room,
        'X-Pleazyng-Music-Control': credentials.control,
      },
    );
    try {
      final socket = await attempt.socket;
      if (_closed || !current() || !identical(_attempt, attempt)) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 20);
      _subscription = socket.listen(
        (raw) => _receive(socket, raw),
        onDone: () => _lost(socket),
        onError: (Object _) => _lost(socket),
      );
      changed();
    } catch (_) {
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _scheduleRetry() {
    if (_closed || !current()) return;
    _retry ??= Timer(const Duration(seconds: 15), () {
      _retry = null;
      unawaited(_connect());
    });
    changed();
  }

  void _lost(WebSocket socket) {
    if (!identical(_socket, socket)) return;
    _socket = null;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    unawaited(socket.close().catchError((_) {}));
    final controllers = _controllers.values.toList();
    _controllers.clear();
    for (final cipher in controllers) {
      cipher.dispose();
    }
    _scheduleRetry();
  }

  void _receive(WebSocket socket, Object? raw) {
    if (_closed || !current() || !identical(_socket, socket)) return;
    try {
      if (raw is! String || raw.length > 64 * 1024) return _lost(socket);
      final message = jsonDecode(raw);
      if (message is! Map<String, dynamic> || !isMusicConnectId(message['peer'])) return _lost(socket);
      final peer = message['peer'] as String;
      if (message['event'] == 'joined') {
        if (_controllers.containsKey(peer) || _controllers.length >= 8) return _reject(socket, peer);
        late MusicRelayCipher cipher;
        cipher = MusicRelayCipher(
          isHost: true,
          contexts: contexts,
          endpoint: endpoint,
          name: 'Controller',
          current: () => !_closed && current() && identical(_socket, socket) && identical(_controllers[peer], cipher),
          disconnected: () {
            if (identical(_controllers[peer], cipher)) {
              _controllers.remove(peer);
              _reject(socket, peer);
              // Defer disposal until the disconnect callback has unwound.
              scheduleMicrotask(cipher.dispose);
            }
          },
          send: (data) => socket.add(jsonEncode({'peer': peer, 'data': data})),
        );
        _controllers[peer] = cipher;
        cipher.start();
      } else if (message['event'] == 'left') {
        _controllers.remove(peer)?.dispose();
      } else if (message['event'] == null) {
        _controllers[peer]?.receive(message['data']);
      } else {
        _lost(socket);
      }
    } catch (_) {
      _lost(socket);
    }
  }

  void _reject(WebSocket socket, String peer) {
    if (identical(_socket, socket)) socket.add(jsonEncode({'event': 'close', 'peer': peer}));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _attempt?.cancel();
    final socket = _socket;
    if (socket != null) _lost(socket);
  }
}
