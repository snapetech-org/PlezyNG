import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../utils/serial_future_queue.dart';
import 'music_connect_channel.dart';
import 'music_device_endpoint.dart';
import 'music_device_link.dart';
import 'music_device_session.dart';

enum MusicDeviceMoveResult { completed, rejected, uncertain }

/// Moves ownership while retaining both authenticated links until the target
/// has answered. A failed preflight leaves the playing source untouched.
class MusicDeviceController extends ChangeNotifier {
  MusicDeviceController(this.local, this.session);

  final MusicDeviceEndpoint local;
  final MusicDeviceSession session;
  final _moves = SerialFutureQueue();
  MusicDeviceLink? _active;
  bool _busy = false;
  bool _closed = false;

  MusicDeviceLink? get active => _active;
  bool get busy => _busy;

  Future<MusicDeviceMoveResult> moveTo(MusicDeviceLink? target) => _moves.run(() => _moveTo(target));

  void _activate(MusicDeviceLink? target) {
    _active?.stopPolling();
    _active = target;
    session.setMusicDeviceOutput(target);
    target?.start();
    if (!_closed) notifyListeners();
  }

  Future<MusicDeviceMoveResult> _moveTo(MusicDeviceLink? target) async {
    if (_closed || identical(target, _active)) return MusicDeviceMoveResult.completed;
    if (target != null && !target.connected) return MusicDeviceMoveResult.rejected;
    _busy = true;
    notifyListeners();
    final source = _active;
    await source?.hold();
    await target?.hold();
    final from = source?.request ?? local.handle;
    final to = target?.request ?? local.handle;
    var detached = false;
    try {
      final state = await from({'op': 'state'});
      if (_closed || state?['ok'] != true) return MusicDeviceMoveResult.rejected;
      if (state?['empty'] == true) {
        if (target != null && !await target.refresh(full: true)) return MusicDeviceMoveResult.rejected;
        _activate(target);
        return MusicDeviceMoveResult.completed;
      }
      // Bringing playback here prepares the local receiver, while the source
      // continues playing and remains available for rollback.
      if (target == null && source != null) {
        session.setMusicDeviceOutput(null);
        detached = true;
      }
      final ready = await to({'op': 'prepare', 'queue': state?['queue']});
      final ticket = ready?['ticket'];
      if (_closed || ready?['ok'] != true || !isMusicConnectId(ticket)) return MusicDeviceMoveResult.rejected;
      final frozen = await from({'op': 'freeze', 'revision': state?['revision']});
      if (_closed || frozen?['ok'] != true) {
        await to({'op': 'cancel', 'ticket': ticket});
        return MusicDeviceMoveResult.rejected;
      }
      final commit = <String, dynamic>{
        'op': 'commit',
        'ticket': ticket,
        'position': frozen?['position'],
        'playing': frozen?['playing'],
      };
      var accepted = await to(commit);
      if (accepted == null || accepted['pending'] == true) accepted = await to(commit);
      if (_closed) return MusicDeviceMoveResult.uncertain;
      if (accepted?['ok'] == false) {
        await from({'op': 'resume', 'ticket': frozen?['ticket']});
        return MusicDeviceMoveResult.rejected;
      }
      // With an unknown commit result the source stays paused. Reconnecting
      // the target reconciles its independently owned state without starting
      // a second output during a network partition.
      _activate(target);
      detached = false;
      await target?.refresh(full: true);
      return accepted?['ok'] == true ? MusicDeviceMoveResult.completed : MusicDeviceMoveResult.uncertain;
    } catch (_) {
      return MusicDeviceMoveResult.rejected;
    } finally {
      if (detached && !_closed) session.setMusicDeviceOutput(source);
      source?.release();
      target?.release();
      if (!_closed) {
        _active?.start();
        _busy = false;
        notifyListeners();
      }
    }
  }

  void adopt(MusicDeviceLink target) {
    if (!_closed && !_busy && target.connected) _activate(target);
  }

  /// Disconnecting a controller leaves the receiver playing.
  void disconnect() {
    if (_busy || _closed) return;
    _activate(null);
  }

  @override
  void dispose() {
    _closed = true;
    _active?.stopPolling();
    session.setMusicDeviceOutput(null);
    _active = null;
    local.close();
    super.dispose();
  }
}
