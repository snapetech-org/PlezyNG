import 'dart:async';

import '../../models/companion_remote/remote_command.dart';
import '../companion_remote/companion_remote_peer_service.dart';
import '../../utils/app_logger.dart';
import 'music_group_exchange.dart';
import 'music_transfer_snapshot.dart';

class MusicGroupEndpoint {
  MusicGroupEndpoint({
    required this.peer,
    required this.authorized,
    required this.capture,
    required this.changed,
    required this.ended,
    this.negotiationTimeout = const Duration(seconds: 15),
  }) {
    _group = MusicGroupExchange(
      allowed: () => !_closed && authorized() && _compatible && peer.isConnected,
      capture: capture,
      prepare: (_, _) async => false,
      align: (_, _) async => false,
      release: () async {},
      send: (data) {
        if (!_closed && authorized()) peer.sendCommand(RemoteCommand(type: RemoteCommandType.musicGroup, data: data));
      },
      changed: () {
        changed();
        if (_started && !_group.active) unawaited(close());
      },
    );
    _commands = peer.onCommandReceived.listen((command) {
      if (_closed || !authorized()) return;
      if (command.type == RemoteCommandType.deviceInfo) {
        _compatible = command.data?['musicGroupVersion'] == 1;
        if (!_negotiated.isCompleted) _negotiated.complete(_compatible);
        if (!_compatible && _started) unawaited(close());
      } else if (command.type == RemoteCommandType.musicGroup && _compatible) {
        _group.receive(command.data);
      }
    }, onError: (Object _) => unawaited(close()));
    _disconnect = peer.onDeviceDisconnected.listen((_) => unawaited(close()));
  }

  final CompanionRemotePeerService peer;
  final bool Function() authorized;
  final MusicTransferSnapshot? Function() capture;
  final void Function() changed;
  final void Function() ended;
  final Duration negotiationTimeout;
  late final MusicGroupExchange _group;
  late final StreamSubscription<RemoteCommand> _commands;
  late final StreamSubscription<void> _disconnect;
  final _negotiated = Completer<bool>();
  bool _compatible = false, _started = false, _closed = false;
  Future<void>? _closing;
  bool get active => !_closed && _group.active;
  bool get joined => !_closed && _group.joined;

  Future<bool> start(Future<void> Function(CompanionRemotePeerService) connect) async {
    try {
      if (_closed || !authorized()) return false;
      await connect(peer);
      if (_closed || !authorized() || !await _negotiated.future.timeout(negotiationTimeout)) return false;
      _started = true;
      final joined = await _group.start();
      if (!joined || _closed || !authorized()) {
        await close();
        return false;
      }
      return true;
    } catch (_) {
      await close();
      rethrow;
    } finally {
      if (!_group.active) await close();
    }
  }

  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    final completed = Completer<void>();
    _closing = completed.future;
    _group.leave();
    _closed = true;
    _group.close();
    if (!_negotiated.isCompleted) _negotiated.complete(false);
    ended();
    unawaited(() async {
      try {
        await _commands.cancel();
        await _disconnect.cancel();
        await peer.dispose();
        completed.complete();
      } catch (error, stack) {
        appLogger.w('Music group endpoint cleanup failed', error: error, stackTrace: stack);
        completed.complete();
      }
    }());
    return completed.future;
  }
}
