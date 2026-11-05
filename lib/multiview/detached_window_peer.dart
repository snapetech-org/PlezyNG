import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

typedef DetachedWindowRequest = Future<Object?> Function(String method, Object? arguments);

/// A bounded connection between the app and one child it launched.
///
/// The launch secret travels through the child's stdin. Mutual challenge/response
/// proves possession before native requests are accepted, including if a failed
/// launch's loopback port is subsequently reused by another process.
final class DetachedWindowPeer {
  DetachedWindowPeer._(this._socket, this._secret, this._server, this.onRequest) {
    _subscription = _socket.listen(_receive, onError: _fail, onDone: () => _fail(StateError('Detached window disconnected')));
    _handshakeTimer = Timer(const Duration(seconds: 5), () => _fail(TimeoutException('Detached window authentication timed out')));
    if (!_server) {
      _challenge = newSecret();
      unawaited(_send({'type': 'hello', 'version': 1, 'challenge': _challenge}).catchError(_fail));
    }
  }

  static const maxFrameBytes = 4 * 1024 * 1024;
  static const maxQueuedBytes = 8 * 1024 * 1024;
  static const maxPendingCalls = 32;
  static const _codec = StandardMessageCodec();
  static final _noncePattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

  static String newSecret() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
  }

  static DetachedWindowPeer accept(Socket socket, {required String secret, DetachedWindowRequest? onRequest}) =>
      _create(socket, secret, true, onRequest);

  static Future<DetachedWindowPeer> connect(int port, {required String secret, DetachedWindowRequest? onRequest}) async {
    if (port < 1 || port > 65535 || !_noncePattern.hasMatch(secret)) throw const FormatException('Invalid child connection');
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 5));
    return _create(socket, secret, false, onRequest);
  }

  static DetachedWindowPeer _create(Socket socket, String secret, bool server, DetachedWindowRequest? handler) {
    if (!_noncePattern.hasMatch(secret) || !socket.remoteAddress.isLoopback) {
      socket.destroy();
      throw const FormatException('Invalid child connection');
    }
    return DetachedWindowPeer._(socket, secret, server, handler);
  }

  final Socket _socket;
  final String _secret;
  final bool _server;
  final DetachedWindowRequest? onRequest;
  final _ready = Completer<void>();
  final _closed = Completer<void>();
  final _events = StreamController<Object?>.broadcast(sync: true);
  final Map<int, Completer<Object?>> _pending = {};
  final Map<int, Timer> _deadlines = {};
  StreamSubscription<Uint8List>? _subscription;
  Timer? _handshakeTimer;
  Uint8List _buffer = Uint8List(0);
  String? _challenge, _serverNonce;
  bool _authenticated = false, _disposed = false;
  int _queuedBytes = 0, _nextId = 0, _inflightRequests = 0;
  Future<void> _writes = Future.value();
  Future<void> _requests = Future.value();

  Future<void> get ready => _ready.future;
  Future<void> get closed => _closed.future;
  Stream<Object?> get notifications => _events.stream;
  bool get isClosed => _disposed;

  String _proof(String role) => Hmac(sha256, base64Url.decode('$_secret='))
      .convert(utf8.encode('plezy-window-v1|$role|$_challenge|$_serverNonce')).toString();

  static bool _equal(String a, Object? b) {
    if (b is! String || a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    return difference == 0;
  }

  Future<Object?> call(String method, [Object? arguments, Duration timeout = const Duration(seconds: 15)]) async {
    await ready;
    if (_disposed) throw StateError('Detached window is closed');
    if (method.isEmpty || method.length > 128 || _pending.length >= maxPendingCalls) throw StateError('Detached window request limit');
    do { _nextId = (_nextId % 0x7fffffff) + 1; } while (_pending.containsKey(_nextId));
    final id = _nextId, result = Completer<Object?>();
    // A native error may arrive before the socket flush completes. Observe the
    // future immediately, while still returning its original error to callers.
    unawaited(result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _pending[id] = result;
    _deadlines[id] = Timer(timeout, () {
      _pending.remove(id)?.completeError(TimeoutException('Detached window request timed out'));
      _deadlines.remove(id);
      _fail(TimeoutException('Detached window operation has an unknown outcome'));
    });
    try {
      await _send({'type': 'call', 'id': id, 'method': method, 'arguments': arguments});
    } catch (error, stack) {
      _deadlines.remove(id)?.cancel();
      _pending.remove(id)?.completeError(error, stack);
    }
    return result.future;
  }

  Future<void> notify(Object? value) async {
    await ready;
    await _send({'type': 'event', 'value': value});
  }

  Future<void> _send(Map<String, Object?> message) {
    if (_disposed) return Future.error(StateError('Detached window is closed'));
    final authentication = const {'hello', 'challenge', 'authenticate', 'ready'}.contains(message['type']);
    final bytes = authentication
        ? ByteData.sublistView(Uint8List.fromList(utf8.encode(jsonEncode(message))))
        : _codec.encodeMessage(message)!;
    if (bytes.lengthInBytes > maxFrameBytes || (!_authenticated && bytes.lengthInBytes > 4096)) {
      return Future.error(const FormatException('Detached window frame is too large'));
    }
    final size = bytes.lengthInBytes + 4;
    if (_queuedBytes + size > maxQueuedBytes) {
      _fail(StateError('Detached window output backlog'));
      return Future.error(StateError('Detached window output backlog'));
    }
    final frame = Uint8List(size);
    ByteData.sublistView(frame).setUint32(0, bytes.lengthInBytes, Endian.big);
    frame.setRange(4, size, bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    _queuedBytes += size;
    final sent = _writes.then((_) async {
      if (_disposed) throw StateError('Detached window is closed');
      _socket.add(frame);
      await _socket.flush().timeout(const Duration(seconds: 5));
    }).whenComplete(() => _queuedBytes -= size);
    _writes = sent.catchError(_fail);
    return sent;
  }

  void _receive(Uint8List incoming) {
    if (_disposed) return;
    try {
      if (_buffer.length + incoming.length > maxQueuedBytes) throw const FormatException('Detached window input backlog');
      final merged = Uint8List(_buffer.length + incoming.length)..setAll(0, _buffer)..setAll(_buffer.length, incoming);
      var offset = 0;
      while (merged.length - offset >= 4) {
        final size = ByteData.sublistView(merged, offset, offset + 4).getUint32(0, Endian.big);
        if (size == 0 || size > (_authenticated ? maxFrameBytes : 4096)) throw const FormatException('Invalid detached window frame');
        if (merged.length - offset < size + 4) break;
        // StandardMessageCodec may allocate from declared collection lengths.
        // An unauthenticated peer gets only small JSON handshake messages;
        // native typed values are decoded after mutual authentication.
        final payload = Uint8List.sublistView(merged, offset + 4, offset + 4 + size);
        final value = _authenticated ? _codec.decodeMessage(ByteData.sublistView(payload)) : jsonDecode(utf8.decode(payload));
        if (value is! Map) throw const FormatException('Invalid detached window message');
        _message(value);
        offset += size + 4;
        if (_disposed) return;
      }
      _buffer = Uint8List.fromList(merged.sublist(offset));
    } catch (error) { _fail(error); }
  }

  void _message(Map message) {
    final type = message['type'];
    if (!_authenticated) {
      if (_server && type == 'hello' && _challenge == null && message['version'] == 1 &&
          message['challenge'] is String && _noncePattern.hasMatch(message['challenge'] as String)) {
        _challenge = message['challenge'] as String;
        _serverNonce = newSecret();
        unawaited(_send({'type': 'challenge', 'nonce': _serverNonce, 'proof': _proof('server')}).catchError(_fail));
        return;
      }
      if (!_server && type == 'challenge' && _serverNonce == null && message['nonce'] is String &&
          _noncePattern.hasMatch(message['nonce'] as String)) {
        _serverNonce = message['nonce'] as String;
        if (!_equal(_proof('server'), message['proof'])) throw const FormatException('Detached window authentication failed');
        unawaited(_send({'type': 'authenticate', 'proof': _proof('client')}).catchError(_fail));
        return;
      }
      if (_server && type == 'authenticate' && _serverNonce != null && _equal(_proof('client'), message['proof'])) {
        _authenticated = true;
        unawaited(_send({'type': 'ready', 'proof': _proof('ready')}).catchError(_fail));
        _handshakeTimer?.cancel(); _ready.complete(); return;
      }
      if (!_server && type == 'ready' && _serverNonce != null && _equal(_proof('ready'), message['proof'])) {
        _authenticated = true; _handshakeTimer?.cancel(); _ready.complete(); return;
      }
      throw const FormatException('Detached window authentication failed');
    }
    if (type == 'reply') {
      final id = message['id'];
      if (id is! int) throw const FormatException('Invalid detached window reply');
      final result = _pending.remove(id);
      _deadlines.remove(id)?.cancel();
      if (result == null) return; // A timed-out request cannot revive its owner.
      if (message['ok'] == true) { result.complete(message['value']); }
      else { result.completeError(PlatformException(code: 'detached-window', message: message['error'] is String ? message['error'] as String : 'Native request failed')); }
      return;
    }
    if (type == 'event') { _events.add(message['value']); return; }
    if (type != 'call' || message['id'] is! int || (message['id'] as int) < 1 ||
        message['method'] is! String || (message['method'] as String).length > 128 || _inflightRequests >= maxPendingCalls) {
      throw const FormatException('Invalid detached window request');
    }
    _inflightRequests++;
    final id = message['id'] as int, method = message['method'] as String, arguments = message['arguments'];
    _requests = _requests.then((_) async {
      try {
        if (_disposed) return;
        final handler = onRequest;
        final result = method == '__ping' ? true : handler == null ? throw MissingPluginException() : await handler(method, arguments);
        await _send({'type': 'reply', 'id': id, 'ok': true, 'value': result});
      } catch (_) {
        if (!_disposed) await _send({'type': 'reply', 'id': id, 'ok': false, 'error': 'Native request failed'});
      } finally { _inflightRequests--; }
    }).catchError(_fail);
  }

  void _fail(Object error) {
    if (_disposed) return;
    _disposed = true;
    _handshakeTimer?.cancel();
    _socket.destroy();
    unawaited(_subscription?.cancel());
    for (final timer in _deadlines.values) timer.cancel();
    _deadlines.clear();
    for (final pending in _pending.values) pending.completeError(StateError('Detached window disconnected'));
    _pending.clear();
    if (!_ready.isCompleted) _ready.completeError(StateError('Detached window authentication failed'));
    unawaited(_events.close());
    _closed.complete();
  }

  void close() => _fail(StateError('Detached window closed'));
}
