import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'music_transfer_snapshot.dart';

class MusicGroupClock {
  int? _bestRtt;
  double offset = 0;
  bool get ready => _bestRtt != null;

  bool observe(int localSent, int remoteReceived, int remoteSent, int localReceived) {
    if (localSent < 0 || remoteReceived < 0 || remoteSent < remoteReceived || localReceived < localSent) return false;
    final rtt = localReceived - localSent - (remoteSent - remoteReceived);
    if (rtt < 0 || rtt > 1000) return false;
    if (_bestRtt == null || rtt <= _bestRtt!) {
      _bestRtt = rtt;
      offset = ((remoteReceived - localSent) + (remoteSent - localReceived)) / 2;
    }
    return true;
  }
}

class MusicGroupExchange {
  MusicGroupExchange({
    required this.allowed,
    required this.capture,
    required this.prepare,
    required this.align,
    required this.release,
    required this.send,
    required this.changed,
    int Function()? now,
  }) : _now = now ?? (Stopwatch()..start()).elapsedMillisecondsGetter;

  final bool Function() allowed;
  final MusicTransferSnapshot? Function() capture;
  final Future<bool> Function(MusicTransferSnapshot, bool Function()) prepare;
  final Future<bool> Function(MusicTransferSnapshot, bool Function()) align;
  final Future<void> Function() release;
  final void Function(Map<String, dynamic>) send;
  final void Function() changed;
  final int Function() _now;
  final _stopwatch = Stopwatch();
  MusicGroupClock _clock = MusicGroupClock();
  String? _group;
  String? _queue;
  bool _leader = false;
  bool _joined = false;
  bool _closed = false;
  bool _applying = false;
  int _generation = 0;
  int _sequence = 0;
  int _received = -1;
  int _lastAnchor = 0;
  int? _probe;
  Timer? _pulse;
  Timer? _deadline;
  Completer<bool>? _pending;
  Completer<bool>? _clockReady;

  bool get active => _group != null;
  bool get joined => active && _joined;
  bool get leader => active && _leader;

  static String queueIdentity(MusicTransferSnapshot snapshot) {
    final json = snapshot.toJson()
      ..remove('position')
      ..remove('playing');
    json.remove('context');
    json.remove('cursor');
    return jsonEncode(json);
  }

  bool _current(int generation) => !_closed && _group != null && generation == _generation && allowed();

  Future<bool> start() {
    if (_closed || !allowed() || active) return Future.value(false);
    final snapshot = capture();
    if (snapshot == null) return Future.value(false);
    Map<String, dynamic> json;
    try {
      json = snapshot.toJson();
      _queue = queueIdentity(snapshot);
    } on StateError {
      return Future.value(false);
    }
    final random = Random.secure();
    _group = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _leader = true;
    final pending = _pending = Completer<bool>();
    _deadline = Timer(const Duration(seconds: 20), leave);
    _send('prepare', {'snapshot': json});
    changed();
    return pending.future;
  }

  void _send(String op, [Map<String, dynamic> payload = const {}]) {
    if (_closed || !active || !allowed()) return;
    try {
      send({'version': 1, 'group': _group, 'op': op, ...payload});
    } catch (_) {
      leave(notifyPeer: false);
    }
  }

  void receive(Map<String, dynamic>? message) {
    if (_closed || !allowed() || message == null || message['version'] != 1) return;
    final group = message['group'];
    final op = message['op'];
    if (group is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(group) || op is! String) return;
    final keys = switch (op) {
      'prepare' => {'snapshot'},
      'probe' => {'sent'},
      'clock' => {'sent', 'received', 'replied'},
      'anchor' => {'sequence', 'sent', 'snapshot'},
      'ready' || 'joined' || 'leave' => <String>{},
      _ => null,
    };
    if (keys == null || message.keys.any((key) => !{'version', 'group', 'op', ...keys}.contains(key))) return;
    if (op == 'prepare') {
      if (active) return;
      final snapshot = MusicTransferSnapshot.tryParse(message['snapshot']);
      if (snapshot == null) return;
      _group = group;
      _queue = queueIdentity(snapshot);
      _leader = false;
      _clock = MusicGroupClock();
      _clockReady = Completer<bool>();
      _deadline = Timer(const Duration(seconds: 20), leave);
      _sendProbe();
      unawaited(_prepare(snapshot, _generation));
      changed();
      return;
    }
    if (group != _group) return;
    switch (op) {
      case 'probe':
        final sent = message['sent'];
        if (!_leader || sent is! int || sent < 0) return;
        final received = _now();
        _send('clock', {'sent': sent, 'received': received, 'replied': _now()});
      case 'clock':
        final sent = message['sent'], received = message['received'], replied = message['replied'];
        if (_leader || sent is! int || sent != _probe || received is! int || replied is! int) return;
        _probe = null;
        if (_clock.observe(sent, received, replied, _now())) {
          if (_clockReady?.isCompleted == false) _clockReady!.complete(true);
        }
      case 'ready':
        if (!_leader || _joined) return;
        _joined = true;
        _lastAnchor = _now();
        _pulse = Timer.periodic(const Duration(seconds: 1), (_) => _anchor());
        _anchor();
      case 'anchor':
        if (_leader || !_clock.ready) return;
        final sequence = message['sequence'], sent = message['sent'];
        final snapshot = MusicTransferSnapshot.tryParse(message['snapshot']);
        if (sequence is! int ||
            sequence <= _received ||
            sequence > 1 << 31 ||
            sent is! int ||
            sent < 0 ||
            snapshot == null) {
          return;
        }
        final age = (_now() + _clock.offset - sent).round();
        if (age < -100 || age > 3000) return;
        _received = sequence;
        _lastAnchor = _now();
        if (_applying) return;
        unawaited(_align(snapshot, max(0, age), _generation));
      case 'joined':
        if (!_leader || !_joined) return;
        _lastAnchor = _now();
        _deadline?.cancel();
        final pending = _pending;
        _pending = null;
        pending?.complete(true);
        changed();
      case 'leave':
        leave(notifyPeer: false);
    }
  }

  Future<void> _prepare(MusicTransferSnapshot snapshot, int generation) async {
    bool current() => _current(generation);
    var accepted = false;
    try {
      accepted = await prepare(
        MusicTransferSnapshot(
          queue: snapshot.queue,
          position: snapshot.position,
          playing: false,
          playContext: snapshot.playContext,
        ),
        current,
      ).timeout(const Duration(seconds: 18));
      if (accepted && current()) {
        accepted = await _clockReady!.future.timeout(const Duration(seconds: 2), onTimeout: () => false);
      }
    } catch (_) {
      accepted = false;
    }
    if (!current()) return;
    if (!accepted) {
      leave();
      return;
    }
    _lastAnchor = _now();
    _pulse = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!allowed() || _now() - _lastAnchor > 5000) {
        leave();
      } else if (_stopwatch.elapsedMilliseconds > 10000) {
        _stopwatch.reset();
        _sendProbe();
      }
    });
    _stopwatch
      ..reset()
      ..start();
    _send('ready');
  }

  void _sendProbe() {
    _probe = _now();
    _send('probe', {'sent': _probe});
  }

  void _anchor() {
    if (!allowed() || (_pending == null && _now() - _lastAnchor > 5000)) {
      leave();
      return;
    }
    final snapshot = capture();
    if (snapshot == null || queueIdentity(snapshot) != _queue) {
      leave();
      return;
    }
    _send('anchor', {'sequence': ++_sequence, 'sent': _now(), 'snapshot': snapshot.toJson()});
  }

  Future<void> _align(MusicTransferSnapshot snapshot, int age, int generation) async {
    _applying = true;
    bool current() => _current(generation);
    var accepted = false;
    try {
      if (queueIdentity(snapshot) == _queue) {
        accepted = await align(
          MusicTransferSnapshot(
            queue: snapshot.queue,
            position: snapshot.position + Duration(milliseconds: snapshot.playing ? age : 0),
            playing: snapshot.playing,
            playContext: snapshot.playContext,
          ),
          current,
        ).timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      accepted = false;
    } finally {
      if (generation == _generation) _applying = false;
    }
    if (!current()) return;
    if (!accepted) {
      leave();
      return;
    }
    if (!_joined) {
      _joined = true;
      _deadline?.cancel();
      changed();
    }
    _send('joined');
  }

  void leave({bool notifyPeer = true}) {
    if (!active) return;
    if (notifyPeer) _send('leave');
    _group = null;
    _queue = null;
    _joined = false;
    _generation++;
    _sequence = 0;
    _received = -1;
    _applying = false;
    _pulse?.cancel();
    _deadline?.cancel();
    _pulse = null;
    _deadline = null;
    _stopwatch.stop();
    final pending = _pending;
    _pending = null;
    pending?.complete(false);
    if (_clockReady?.isCompleted == false) _clockReady!.complete(false);
    _clockReady = null;
    unawaited(release());
    changed();
  }

  void close() {
    leave();
    _closed = true;
  }
}

extension on Stopwatch {
  int elapsedMillisecondsGetter() => elapsedMilliseconds;
}
