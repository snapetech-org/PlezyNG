import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../utils/serial_future_queue.dart';
import '../companion_remote/remote_auth_context.dart';
import '../companion_remote/remote_auth_service.dart';
import 'music_connect_channel.dart';
import 'music_device_endpoint.dart';
import 'music_device_link.dart';

/// The relay handles opaque routing. Only paired devices can open this
/// music-only channel. Fresh nonces and directional counters reject replay.
class MusicRelayCipher {
  MusicRelayCipher({
    required this.isHost,
    required this.contexts,
    required this.send,
    required this.endpoint,
    required this.current,
    required this.disconnected,
    required String name,
    this.expectedHostClientId,
    this.deviceName = 'Pleazyng',
    this.platform = 'unknown',
  }) {
    channel = MusicConnectChannel(send: _sendFrame, handle: endpoint.handle, allowed: () => ready);
    output = MusicDeviceLink(name: name, request: channel.request, isConnected: () => ready);
    _deadline = Timer(const Duration(seconds: 10), close);
  }

  final bool isHost;
  final List<RemoteAuthContext> contexts;
  final void Function(Map<String, dynamic>) send;
  final MusicDeviceEndpoint endpoint;
  final bool Function() current;
  final void Function() disconnected;
  final String? expectedHostClientId;
  final String deviceName;
  final String platform;
  final _auth = RemoteAuthService.instance;
  final _incoming = SerialFutureQueue();
  final _outgoing = SerialFutureQueue();
  final _authenticated = Completer<bool>();
  late final MusicConnectChannel channel;
  late final MusicDeviceLink output;
  Timer? _deadline;
  List<int>? _hostNonce;
  List<int>? _key;
  int _sent = 0;
  int _received = 0;
  int _queuedBytes = 0;
  bool _closed = false;
  bool _ready = false;
  bool _challenged = false;

  bool get ready => !_closed && current() && _ready;
  Future<bool> get authenticated => _authenticated.future;

  List<int> _secret(RemoteAuthContext context) =>
      Hmac(sha256, context.homeSecret).convert(utf8.encode('pleazyng-music-connect-relay-v1')).bytes;

  void start() {
    if (!isHost || _closed || !current() || _challenged) return;
    _challenged = true;
    final identities = contexts.where((context) => context.isPaired).take(32).toList();
    if (identities.isEmpty) return close();
    _hostNonce = _auth.generateNonce();
    _send({
      'kind': 'challenge',
      'nonce': base64Encode(_hostNonce!),
      'identities': [
        for (final context in identities) {'id': context.id, 'device': context.clientIdentifier},
      ],
    });
  }

  void _send(Map<String, dynamic> value) {
    if (_closed || !current()) return;
    try {
      send(value);
    } catch (_) {
      close();
    }
  }

  void receive(Object? value) {
    if (_closed || !current()) return;
    if (value is! Map<String, dynamic>) return close();
    final bytes = utf8.encode(jsonEncode(value)).length;
    if (bytes > 48 * 1024 || _queuedBytes + bytes > 8 * 1024 * 1024) return close();
    _queuedBytes += bytes;
    unawaited(
      _incoming.run(() async {
        try {
          if (!_closed && current()) await _receive(value);
        } catch (_) {
          close();
        } finally {
          _queuedBytes -= bytes;
        }
      }),
    );
  }

  List<int>? _nonce(Object? value) {
    if (value is! String || value.length != 44) return null;
    try {
      final bytes = base64Decode(value);
      return bytes.length == 32 ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _receive(Map<String, dynamic> message) async {
    final kind = message['kind'];
    if (kind == 'cipher' && _key != null) {
      final data = message['data'];
      if (data is! String || data.length > 48000) return close();
      final key = _key!;
      final plain = await _auth.decrypt(base64Decode(data), key, fromHost: !isHost, expectedCounter: _received);
      if (_closed || !current() || !identical(_key, key)) return;
      _received++;
      final decoded = jsonDecode(utf8.decode(plain));
      if (!_ready) {
        if (isHost || decoded is! Map || decoded.length != 1 || decoded['authenticated'] != 1) return close();
        _accept();
      } else if (decoded is Map<String, dynamic>) {
        channel.receive(decoded);
      } else {
        close();
      }
      return;
    }
    if (_key != null || _ready) return close();
    if (isHost && kind == 'auth') {
      final nonce = _nonce(message['nonce']);
      final id = message['context'], user = message['user'], client = message['client'];
      final name = message['name'], platform = message['platform'], tag = message['tag'];
      final context = contexts.where((context) => context.id == id && context.isPaired).firstOrNull;
      if (context == null ||
          _hostNonce == null ||
          nonce == null ||
          user is! String ||
          !context.allowedUserUuids.contains(user) ||
          client is! String ||
          client.isEmpty ||
          client.length > 256 ||
          name is! String ||
          name.isEmpty ||
          name.length > 256 ||
          platform is! String ||
          platform.length > 40 ||
          tag is! String ||
          tag.length != 64) {
        return close();
      }
      final secret = _secret(context);
      if (!_auth.verifyAuthTag(
        authTag: tag,
        homeSecret: secret,
        hostNonce: _hostNonce!,
        clientNonce: nonce,
        hostClientId: context.clientIdentifier,
        userUUID: user,
        clientIdentifier: client,
        deviceName: name,
        platform: platform,
      )) {
        return close();
      }
      final key = await _auth.deriveSessionEncKey(secret, _hostNonce!, nonce);
      if (_closed || !current()) return;
      _key = key;
      await _encrypt({'authenticated': 1});
      if (!_closed && current()) _accept();
    } else if (!isHost && kind == 'challenge' && !_challenged) {
      _challenged = true;
      final nonce = _nonce(message['nonce']);
      final identities = message['identities'];
      if (nonce == null || identities is! List || identities.length > 32 || expectedHostClientId == null) {
        return close();
      }
      final context = contexts
          .where(
            (context) =>
                context.isPaired &&
                identities.any(
                  (identity) =>
                      identity is Map && identity['id'] == context.id && identity['device'] == expectedHostClientId,
                ),
          )
          .firstOrNull;
      if (context == null) return close();
      final clientNonce = _auth.generateNonce();
      final secret = _secret(context);
      final key = await _auth.deriveSessionEncKey(secret, nonce, clientNonce);
      if (_closed || !current()) return;
      _key = key;
      _send({
        'kind': 'auth',
        'context': context.id,
        'nonce': base64Encode(clientNonce),
        'user': context.userUuid,
        'client': context.clientIdentifier,
        'name': deviceName,
        'platform': platform,
        'tag': _auth.computeAuthTag(
          homeSecret: secret,
          hostNonce: nonce,
          clientNonce: clientNonce,
          hostClientId: expectedHostClientId!,
          userUUID: context.userUuid,
          clientIdentifier: context.clientIdentifier,
          deviceName: deviceName,
          platform: platform,
        ),
      });
    } else {
      close();
    }
  }

  void _accept() {
    _ready = true;
    _deadline?.cancel();
    _deadline = null;
    if (!_authenticated.isCompleted) _authenticated.complete(true);
    output.connectionChanged();
  }

  void _sendFrame(Map<String, dynamic> frame) {
    if (!ready) return;
    unawaited(
      _outgoing.run(() async {
        try {
          if (ready) await _encrypt(frame);
        } catch (_) {
          close();
        }
      }),
    );
  }

  Future<void> _encrypt(Map<String, dynamic> plain) async {
    final key = _key;
    if (key == null || _closed || !current()) return;
    final data = await _auth.encrypt(key, utf8.encode(jsonEncode(plain)), isHost: isHost, counter: _sent);
    if (_closed || !current() || !identical(_key, key)) return;
    _sent++;
    _send({'kind': 'cipher', 'data': base64Encode(data)});
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _ready = false;
    _key = null;
    _deadline?.cancel();
    _deadline = null;
    channel.close();
    if (!_authenticated.isCompleted) _authenticated.complete(false);
    output.connectionChanged();
    disconnected();
  }

  void dispose() {
    close();
    output.dispose();
  }
}
