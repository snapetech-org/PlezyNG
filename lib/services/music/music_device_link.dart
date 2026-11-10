import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../utils/serial_future_queue.dart';
import 'music_connect_channel.dart';
import 'music_device_session.dart';
import 'music_transfer_snapshot.dart';

/// A controller observes the receiver's session. The receiver's audio and queue
/// continue independently when this link disconnects.
class MusicDeviceLink extends ChangeNotifier implements MusicDevicePlayback {
  MusicDeviceLink({required this.name, required this.request, required this.isConnected});

  @override
  final String name;
  final MusicConnectRequest request;
  final bool Function() isConnected;
  final _commands = SerialFutureQueue();
  MusicDeviceState? _state;
  bool _closed = false;
  Timer? _poll;
  bool _refreshing = false;
  bool _pollQueued = false;
  bool _moving = false;

  @override
  MusicDeviceState? get state => _state;
  @override
  bool get connected => !_closed && isConnected();

  Future<bool> refresh({bool full = false}) async {
    if (!connected || _refreshing) return false;
    _refreshing = true;
    try {
      final reply = await request({'op': 'state', if (!full) 'revision': _state?.revision});
      if (!connected || reply?['ok'] != true) return false;
      final state = MusicDeviceState.read(reply!, full ? null : _state);
      if (state == null) return false;
      _state = state;
      notifyListeners();
      return true;
    } finally {
      _refreshing = false;
    }
  }

  void start() {
    _poll ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_pollQueued || !connected) return;
      _pollQueued = true;
      unawaited(
        _commands.run(() async {
          try {
            await refresh();
          } finally {
            _pollQueued = false;
          }
        }),
      );
    });
  }

  Future<void> hold() async {
    _moving = true;
    stopPolling();
    await _commands.run<void>(() async {});
  }

  void release() => _moving = false;

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void connectionChanged() {
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> control(String action, [Map<String, dynamic> args = const {}]) => _commands.run(() async {
    if (!connected || _moving) throw StateError('Music device is disconnected or switching');
    final reply = await request({'op': 'control', 'revision': _state?.revision, 'action': action, 'args': args});
    if (!connected) return;
    final value = reply?['state'];
    if (value is Map<String, dynamic>) {
      final state = MusicDeviceState.read(value, null);
      if (state != null) {
        _state = state;
        notifyListeners();
      }
    }
    if (reply?['ok'] != true) {
      await refresh(full: true);
      throw StateError('Music device changed or rejected the command');
    }
  });

  @override
  Future<bool> playSnapshot(MusicTransferSnapshot snapshot) => _commands.run(() async {
    if (!connected || _moving) return false;
    final ready = await request({
      'op': 'prepare',
      'queue': snapshot.toJson(itemLimit: MusicTransferSnapshot.maxTransferItems),
    });
    final ticket = ready?['ticket'];
    if (ready?['ok'] != true || !isMusicConnectId(ticket)) return false;
    final reply = await request({
      'op': 'commit',
      'ticket': ticket,
      'position': snapshot.position.inMilliseconds,
      'playing': snapshot.playing,
    });
    await refresh(full: true);
    return reply?['ok'] == true;
  });

  @override
  void dispose() {
    _closed = true;
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }
}
