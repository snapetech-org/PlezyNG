import 'dart:async';
import 'dart:math';

import 'music_wire_payload.dart';

typedef MusicConnectMessage = Map<String, dynamic>;
typedef MusicConnectRequest = Future<MusicConnectMessage?> Function(MusicConnectMessage message);

String newMusicConnectId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

bool isMusicConnectId(Object? value) => value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

/// Request/reply on one authenticated peer. Each direction is FIFO, with one
/// incomplete message and one active request per side. A retired peer cannot
/// complete a request or feed frames to its replacement.
class MusicConnectChannel {
  MusicConnectChannel({required this.send, required this.handle, required this.allowed});

  static const deadline = Duration(seconds: 15);
  final void Function(MusicConnectMessage) send;
  final MusicConnectRequest handle;
  final bool Function() allowed;

  bool _closed = false;
  bool _handling = false;
  String? _pendingId;
  Completer<MusicConnectMessage?>? _pending;
  Timer? _replyTimer;
  ({String id, bool reply, MusicWirePayload payload})? _incoming;
  Timer? _frameTimer;

  bool get connected => !_closed && allowed();

  Future<MusicConnectMessage?> request(MusicConnectMessage message) async {
    if (!connected || _pending != null) return null;
    final id = _pendingId = newMusicConnectId();
    final pending = _pending = Completer<MusicConnectMessage?>();
    _replyTimer = Timer(deadline, () => _settle(null));
    if (!_emit(id, false, message)) _settle(null);
    return pending.future;
  }

  bool _emit(String id, bool reply, MusicConnectMessage message) {
    try {
      final frames = MusicWirePayload.encode(message);
      for (var i = 0; i < frames.length; i++) {
        if (!connected) return false;
        send({'v': 1, 'id': id, 'reply': reply, 'i': i, 'n': frames.length, 'data': frames[i]});
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void receive(MusicConnectMessage? frame) {
    if (!connected || frame == null || frame.length != 6 || frame['v'] != 1) return;
    final id = frame['id'];
    final reply = frame['reply'];
    final index = frame['i'];
    final count = frame['n'];
    final data = frame['data'];
    if (id is! String ||
        !isMusicConnectId(id) ||
        reply is! bool ||
        index is! int ||
        count is! int ||
        count < 1 ||
        count > MusicWirePayload.maxFrames ||
        data is! String ||
        (reply && id != _pendingId)) {
      return;
    }
    if (index == 0 && _incoming == null) {
      _incoming = (id: id, reply: reply, payload: MusicWirePayload(count));
      _frameTimer = Timer(deadline, _discardFrames);
    }
    final incoming = _incoming;
    if (incoming == null || incoming.id != id || incoming.reply != reply) return;
    if (incoming.payload.count != count || !incoming.payload.add(index, data)) {
      _discardFrames();
      return;
    }
    if (!incoming.payload.complete) return;
    _discardFrames();
    final message = incoming.payload.decode();
    if (reply) {
      _settle(message);
    } else if (message != null && !_handling) {
      unawaited(_serve(id, message));
    } else {
      _emit(id, true, const {'ok': false});
    }
  }

  Future<void> _serve(String id, MusicConnectMessage message) async {
    _handling = true;
    try {
      final result = await handle(message);
      _emit(id, true, result ?? const {'ok': false});
    } catch (_) {
      _emit(id, true, const {'ok': false});
    } finally {
      _handling = false;
    }
  }

  void _discardFrames() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _incoming = null;
  }

  void _settle(MusicConnectMessage? result) {
    _replyTimer?.cancel();
    _replyTimer = null;
    _pendingId = null;
    final pending = _pending;
    _pending = null;
    pending?.complete(result);
  }

  void close() {
    _closed = true;
    _discardFrames();
    _settle(null);
  }
}
