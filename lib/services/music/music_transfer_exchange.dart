import 'dart:async';
import 'dart:math';

import 'music_transfer_snapshot.dart';

/// Request/ack over an already authenticated companion connection. The
/// sender retains its session until a matching, current receiver reply says
/// it opened the queue. Selecting a control target does not invoke this.
class MusicTransferExchange {
  MusicTransferExchange({required this.allowed, required this.accept, required this.send});

  final bool Function() allowed;
  final Future<bool> Function(MusicTransferSnapshot, bool Function() current) accept;
  final void Function(Map<String, dynamic>) send;

  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');
  static const timeout = Duration(seconds: 20);
  final Map<String, bool> _served = {};
  bool _closed = false, _serving = false;
  int _generation = 0;
  String? _request;
  Completer<bool>? _pending;
  Timer? _timer;

  static String _id() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<bool> request(MusicTransferSnapshot snapshot) {
    if (_closed || !allowed() || _pending != null) return Future.value(false);
    Map<String, dynamic> payload;
    try {
      payload = snapshot.toJson();
    } on StateError {
      return Future.value(false);
    }
    final id = _request = _id();
    final pending = _pending = Completer<bool>();
    _timer = Timer(timeout, () => _finish(false));
    try {
      send({'version': 1, 'op': 'request', 'request': id, 'snapshot': payload});
    } catch (_) {
      _finish(false);
    }
    return pending.future;
  }

  void receive(Map<String, dynamic>? message) {
    if (_closed || message == null || message['version'] != 1 || !allowed()) return;
    final id = message['request'];
    if (id is! String || !_idPattern.hasMatch(id)) return;
    if (message['op'] == 'result' && id == _request) {
      if (message.keys.any((key) => !{'version', 'op', 'request', 'accepted'}.contains(key)) ||
          message['accepted'] is! bool) {
        _finish(false);
      } else {
        _finish(message['accepted'] as bool);
      }
    } else if (message['op'] == 'request') {
      unawaited(_serve(id, message));
    }
  }

  Future<void> _serve(String id, Map<String, dynamic> message) async {
    final prior = _served[id];
    if (prior != null) {
      _reply(id, prior);
      return;
    }
    if (_serving || message.keys.any((key) => !{'version', 'op', 'request', 'snapshot'}.contains(key))) {
      _reply(id, false);
      return;
    }
    final snapshot = MusicTransferSnapshot.tryParse(message['snapshot']);
    if (snapshot == null) {
      _reply(id, false);
      return;
    }
    _serving = true;
    final generation = _generation;
    var expired = false;
    bool current() => !_closed && !expired && generation == _generation && allowed();
    var accepted = false;
    try {
      accepted = await accept(snapshot, current).timeout(
        timeout,
        onTimeout: () {
          expired = true;
          return false;
        },
      );
    } catch (_) {
      accepted = false;
    } finally {
      if (generation == _generation) _serving = false;
    }
    if (!current()) return;
    if (_served.length >= 256) _served.remove(_served.keys.first);
    _served[id] = accepted;
    _reply(id, accepted);
  }

  void _reply(String id, bool accepted) {
    if (_closed || !allowed()) return;
    try {
      send({'version': 1, 'op': 'result', 'request': id, 'accepted': accepted});
    } catch (_) {
      // A disconnected peer cannot acknowledge a transfer. The sender stays put.
    }
  }

  void _finish(bool accepted) {
    final pending = _pending;
    _pending = null;
    _request = null;
    _timer?.cancel();
    _timer = null;
    pending?.complete(accepted);
  }

  void reset() {
    _generation++;
    _serving = false;
    _served.clear();
    _finish(false);
  }

  void close() {
    _closed = true;
    reset();
  }
}
