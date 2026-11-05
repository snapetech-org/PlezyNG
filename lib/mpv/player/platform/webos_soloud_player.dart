import 'dart:async';

import 'package:flutter/services.dart';

/// Small app-owned adapter for LG's webOS SoLoud implementation. It uses the
/// plugin's stable audioplayers method/event channel protocol without bringing
/// the cross-platform Dart package into the app's dependency graph.
class WebOSSoLoudPlayer {
  WebOSSoLoudPlayer({
    required this.playerId,
    required this.onPosition,
    required this.onDuration,
    required this.onComplete,
    required this.onError,
  });

  static const _methodChannel = MethodChannel('xyz.luan/audioplayers');

  final String playerId;
  final void Function(Duration position) onPosition;
  final void Function(Duration duration) onDuration;
  final void Function() onComplete;
  final void Function(Object error) onError;

  late final EventChannel _eventChannel = EventChannel('xyz.luan/audioplayers/events/$playerId');
  StreamSubscription<dynamic>? _events;
  Completer<Duration>? _durationReady;
  Timer? _positionTimer;
  bool _polling = false;
  bool _disposed = false;

  Future<void> load(Uri uri, {required bool isLocal}) async {
    await _invoke('create');
    _events = _eventChannel.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error, StackTrace stack) => _onError(error),
    );
    final durationReady = Completer<Duration>();
    _durationReady = durationReady;
    final durationFuture = durationReady.future.timeout(const Duration(seconds: 15));
    await _invoke('setSourceUrl', {
      'url': uri.toString(),
      'isLocal': isLocal,
      'mimeType': '',
    });
    await durationFuture;
  }

  Future<void> resume() async {
    await _invoke('resume');
    _positionTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _pollPosition());
  }

  Future<void> pause() async {
    _positionTimer?.cancel();
    _positionTimer = null;
    await _pollPosition();
    await _invoke('pause');
  }

  Future<void> seek(Duration position) => _invoke('seek', {
    'position': position.inMilliseconds.clamp(0, 0x7fffffff),
  });

  Future<void> setVolume(double value) => _invoke('setVolume', {'volume': value});

  Future<void> setPlaybackRate(double value) => _invoke('setPlaybackRate', {'playbackRate': value});

  Future<Duration?> getDuration() async {
    final milliseconds = await _invoke<int>('getDuration');
    return milliseconds == null || milliseconds < 0 ? null : Duration(milliseconds: milliseconds);
  }

  Future<Duration?> getCurrentPosition() async {
    final milliseconds = await _invoke<int>('getCurrentPosition');
    return milliseconds == null || milliseconds < 0 ? null : Duration(milliseconds: milliseconds);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _positionTimer?.cancel();
    _positionTimer = null;
    await _events?.cancel();
    _events = null;
    try {
      await _invoke('dispose');
    } on MissingPluginException {
      // The webOS plugin may already be unloading.
    } on PlatformException {
      // Native error handling may already have released this player.
    }
  }

  void _onError(Object error) {
    final ready = _durationReady;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    onError(error);
  }

  void _onEvent(dynamic raw) {
    if (_disposed || raw is! Map) return;
    final event = raw['event'];
    final value = raw['value'];
    if (event == 'audio.onDuration' && value is num && value.isFinite && value >= 0) {
      final duration = Duration(milliseconds: value.toInt());
      onDuration(duration);
      final ready = _durationReady;
      if (ready != null && !ready.isCompleted) ready.complete(duration);
    } else if (event == 'audio.onComplete') {
      onComplete();
    }
  }

  Future<void> _pollPosition() async {
    if (_disposed || _polling) return;
    _polling = true;
    try {
      final position = await getCurrentPosition();
      if (position != null && !_disposed) onPosition(position);
    } on MissingPluginException {
      onError(const FormatException('The webOS SoLoud player disappeared.'));
    } on PlatformException catch (error) {
      onError(FormatException(error.message ?? error.code));
    } finally {
      _polling = false;
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?> arguments = const {}]) =>
      _methodChannel.invokeMethod<T>(method, {'playerId': playerId, ...arguments});
}
