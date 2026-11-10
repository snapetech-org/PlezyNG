import 'dart:async';
import 'dart:math';

import 'music_transfer_snapshot.dart';
import 'music_wire_payload.dart';

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
  bool _closed = false;
  int _generation = 0;
  String? _serving;
  String? _request;
  int? _requestVersion;
  Completer<bool>? _pending;
  Timer? _timer;
  String? _assemblyId;
  MusicWirePayload? _assembly;
  Timer? _assemblyTimer;

  static String _id() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<bool> request(MusicTransferSnapshot snapshot, {int version = 1}) {
    if (_closed || !allowed() || _pending != null || (version != 1 && version != 2)) return Future.value(false);
    final Map<String, dynamic> payload;
    final List<String>? frames;
    try {
      payload = snapshot.toJson(
        itemLimit: version == 1 ? MusicTransferSnapshot.maxItems : MusicTransferSnapshot.maxTransferItems,
      );
      frames = version == 2 ? MusicWirePayload.encode(payload) : null;
    } on StateError {
      return Future.value(false);
    }
    final id = _request = _id();
    _requestVersion = version;
    final pending = _pending = Completer<bool>();
    _timer = Timer(timeout, () => _finish(false));
    try {
      if (frames == null) {
        send({'version': 1, 'op': 'request', 'request': id, 'snapshot': payload});
      } else {
        for (var index = 0; index < frames.length; index++) {
          if (_pending != pending) break;
          send({
            'version': 2,
            'op': 'chunk',
            'request': id,
            'index': index,
            'count': frames.length,
            'data': frames[index],
          });
        }
      }
    } catch (_) {
      _finish(false);
    }
    return pending.future;
  }

  void receive(Map<String, dynamic>? message) {
    if (_closed || message == null || !allowed()) return;
    final version = message['version'];
    final id = message['request'];
    if (version is! int || (version != 1 && version != 2) || id is! String || !_idPattern.hasMatch(id)) return;
    final op = message['op'];
    if (op == 'result') {
      if (id != _request || version != _requestVersion) return;
      final accepted = message['accepted'];
      _finish(accepted == true && !message.keys.any((key) => !{'version', 'op', 'request', 'accepted'}.contains(key)));
    } else if (op == 'request' && version == 1) {
      if (message.keys.any((key) => !{'version', 'op', 'request', 'snapshot'}.contains(key))) {
        _reply(id, version, false);
        return;
      }
      _offer(id, version, message['snapshot']);
    } else if (op == 'chunk' && version == 2) {
      _receiveChunk(id, message);
    }
  }

  void _receiveChunk(String id, Map<String, dynamic> message) {
    final prior = _served[id];
    final index = message['index'];
    if (prior != null) {
      if (index == 0) _reply(id, 2, prior);
      return;
    }
    if (_serving == id) return;
    final count = message['count'];
    final data = message['data'];
    if (_serving != null ||
        (_assemblyId != null && _assemblyId != id) ||
        index is! int ||
        count is! int ||
        count < 1 ||
        count > MusicWirePayload.maxFrames ||
        data is! String ||
        message.keys.any((key) => !{'version', 'op', 'request', 'index', 'count', 'data'}.contains(key))) {
      if (_assemblyId == id) _clearAssembly();
      _reply(id, 2, false);
      return;
    }
    if (_assembly == null && index == 0) {
      _assemblyId = id;
      _assembly = MusicWirePayload(count);
      _assemblyTimer = Timer(timeout, () {
        _clearAssembly();
        _reply(id, 2, false);
      });
    }
    final assembly = _assembly;
    if (assembly == null || assembly.count != count || !assembly.add(index, data)) {
      _clearAssembly();
      _reply(id, 2, false);
    } else if (assembly.complete) {
      _clearAssembly();
      _offer(id, 2, assembly.decode());
    }
  }

  void _offer(String id, int version, Object? payload) {
    final prior = _served[id];
    if (prior != null) {
      _reply(id, version, prior);
      return;
    }
    if (_serving == id) return;
    final snapshot = MusicTransferSnapshot.tryParse(
      payload,
      itemLimit: version == 1 ? MusicTransferSnapshot.maxItems : MusicTransferSnapshot.maxTransferItems,
    );
    if (_serving != null || _assembly != null || snapshot == null) {
      _reply(id, version, false);
      return;
    }
    unawaited(_serve(id, version, snapshot));
  }

  Future<void> _serve(String id, int version, MusicTransferSnapshot snapshot) async {
    _serving = id;
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
      if (generation == _generation) _serving = null;
    }
    if (!current()) return;
    if (_served.length >= 256) _served.remove(_served.keys.first);
    _served[id] = accepted;
    _reply(id, version, accepted);
  }

  void _reply(String id, int version, bool accepted) {
    if (_closed || !allowed()) return;
    try {
      send({'version': version, 'op': 'result', 'request': id, 'accepted': accepted});
    } catch (_) {
      // A disconnected peer cannot acknowledge a transfer. The sender stays put.
    }
  }

  void _clearAssembly() {
    _assemblyTimer?.cancel();
    _assemblyTimer = null;
    _assemblyId = null;
    _assembly = null;
  }

  void _finish(bool accepted) {
    _timer?.cancel();
    _timer = null;
    _request = null;
    _requestVersion = null;
    final pending = _pending;
    _pending = null;
    pending?.complete(accepted);
  }

  void reset() {
    _generation++;
    _serving = null;
    _served.clear();
    _clearAssembly();
    _finish(false);
  }

  void close() {
    _closed = true;
    reset();
  }
}
