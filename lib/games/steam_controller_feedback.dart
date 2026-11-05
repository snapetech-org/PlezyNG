import 'dart:async';

import 'package:flutter/services.dart';

/// Optional effects on the same physical IDs used for button/stick input.
/// Tokens prevent retired panes from vibrating or sampling another pane's pads.
class SteamControllerFeedbackSession {
  SteamControllerFeedbackSession({required this.owner, this.rumble = true, this.motion = false});

  final String owner;
  final bool rumble, motion;
  static const _devices = MethodChannel('dev.universal_gamepad/methods');
  static SteamControllerFeedbackSession? _active;
  MethodChannel? _receiver;
  Timer? _timer;
  String? _token;
  int _generation = 0;
  bool _polling = false;
  final _sensorDevices = <int>{};

  void update(MethodChannel? receiver, bool enabled) {
    if (enabled && receiver == _receiver && _token != null) return;
    stop();
    if (!enabled || receiver == null || (!rumble && !motion)) return;
    _active?.stop();
    _active = this;
    _receiver = receiver;
    final token = _token = '$owner-0-${++_generation}';
    unawaited(_start(receiver, token));
  }

  bool _live(MethodChannel receiver, String token) =>
      identical(_active, this) && _receiver == receiver && _token == token;

  final _pending = <Timer, void Function()>{};
  Future<T?> _invoke<T>(MethodChannel channel, String method, [Map<String, Object?>? arguments]) {
    final result = Completer<T?>();
    late Timer timer;
    void finish(T? value, Object? error) {
      if (result.isCompleted) return;
      timer.cancel();
      _pending.remove(timer);
      if (error != null) {
        result.completeError(error);
      } else {
        result.complete(value);
      }
    }

    timer = Timer(const Duration(seconds: 2), () => finish(null, TimeoutException('Controller response timed out')));
    _pending[timer] = () => finish(null, StateError('Controller effects retired'));
    unawaited(
      channel
          .invokeMethod<T>(method, arguments)
          .then((value) => finish(value, null), onError: (Object error) => finish(null, error)),
    );
    return result.future;
  }

  Future<void> _start(MethodChannel receiver, String token) async {
    try {
      final accepted = await _invoke<bool>(_devices, 'plezyClaimEffects', {'owner': token});
      if (!_live(receiver, token) || accepted != true) {
        if (_live(receiver, token)) stop();
        await _release(token);
        return;
      }
      _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => unawaited(_poll(receiver, token)));
    } catch (_) {
      if (_live(receiver, token)) stop(); // Old plugins retain ordinary input.
    }
  }

  Future<void> _poll(MethodChannel receiver, String token) async {
    if (_polling || !_live(receiver, token)) return;
    _polling = true;
    try {
      final rows = await _invoke<Object?>(receiver, 'readControllerFeedback');
      if (!_live(receiver, token)) return;
      if (rows is! List || rows.length > 4) throw const FormatException('Invalid feedback');
      final seen = <int>{};
      for (final row in rows) {
        if (row is! List || row.length != 9 || row.any((v) => v is! int)) {
          throw const FormatException('Invalid feedback');
        }
        final values = row.cast<int>();
        final id = values[0], flags = values[1];
        if (id < 0 ||
            id > 0x7fffffff ||
            !seen.add(id) ||
            flags < 0 ||
            flags > 7 ||
            [2, 3, 5, 6].any((i) => values[i] < 0 || values[i] > 65535) ||
            [4, 7].any((i) => values[i] < 0 || values[i] > 1000) ||
            values[8] < 0 ||
            values[8] > 1) {
          throw const FormatException('Invalid feedback');
        }
        final sensors = motion && values[8] == 1;
        final sensorChanged = sensors != _sensorDevices.contains(id);
        if (flags != 0 || sensorChanged) {
          await _invoke<bool>(_devices, 'plezyControllerEffects', {
            'owner': token,
            'deviceId': id,
            'flags': flags | (sensorChanged ? 4 : 0),
            'low': rumble ? values[2] : 0,
            'high': rumble ? values[3] : 0,
            'duration': rumble ? values[4] : 0,
            'leftTrigger': rumble ? values[5] : 0,
            'rightTrigger': rumble ? values[6] : 0,
            'triggerDuration': rumble ? values[7] : 0,
            'sensors': sensors,
          });
          if (!_live(receiver, token)) return;
        }
        if (sensors) {
          _sensorDevices.add(id);
          final state = await _invoke<Object?>(_devices, 'plezyControllerState', {'owner': token, 'deviceId': id});
          if (!_live(receiver, token)) return;
          // Unsupported, disconnected and stale devices send neutral motion.
          final motionValues = List<double>.filled(6, 0);
          if (state is List && state.length == 7 && state.every((v) => v is num && v.isFinite)) {
            final caps = (state[0] as num).toInt();
            if (caps >= 0 && caps <= 15) {
              for (var i = 0; i < 6; i++) {
                if ((caps & (i < 3 ? 4 : 8)) != 0) {
                  final limit = i < 3 ? 34.90659 : 19.6133;
                  motionValues[i] = (state[i + 1] as num).toDouble().clamp(-limit, limit);
                }
              }
            }
          }
          await _invoke<bool>(receiver, 'setControllerMotion', {
            'deviceId': id,
            for (var i = 0; i < 6; i++) ['gx', 'gy', 'gz', 'ax', 'ay', 'az'][i]: motionValues[i],
          });
          if (!_live(receiver, token)) return;
        } else {
          _sensorDevices.remove(id);
        }
      }
    } catch (_) {
      if (_live(receiver, token)) stop();
    } finally {
      _polling = false;
    }
  }

  Future<void> _release(String token) async {
    try {
      await _devices.invokeMethod<void>('plezyReleaseEffects', {'owner': token});
    } catch (_) {}
  }

  void stop() {
    final token = _token;
    _token = null;
    _receiver = null;
    _timer?.cancel();
    _timer = null;
    _sensorDevices.clear();
    for (final cancel in _pending.values.toList()) {
      cancel();
    }
    _pending.clear();
    if (identical(_active, this)) _active = null;
    if (token != null) unawaited(_release(token));
  }
}
