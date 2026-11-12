import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'music_system_audio_routes.dart';

/// Foreground-only observation shared by route diagnostics and driving entry.
/// It observes system selection without setting a route, focus or playback.
class MusicSystemAudioRouteMonitor extends ValueNotifier<MusicSystemAudioRoute?> with WidgetsBindingObserver {
  MusicSystemAudioRouteMonitor({required this.current}) : super(null) {
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }
  final bool Function() current;
  StreamSubscription<MusicSystemAudioRoute>? _subscription;
  int _epoch = 0;
  bool _closed = false;
  bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);
  bool get foreground =>
      !_closed &&
      current() &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  void _accept(MusicSystemAudioRoute route) {
    if (!foreground) return;
    _epoch++;
    value = route;
  }

  void refresh() {
    final epoch = ++_epoch;
    if (!_supported || !foreground) {
      if (!_closed) value = null;
      return;
    }
    _subscription ??= MusicSystemAudioRoutes.changes.listen(
      _accept,
      onError: (Object _) {
        _epoch++;
        if (!_closed) value = null;
      },
    );
    unawaited(_read(epoch));
  }

  Future<void> _read(int epoch) async {
    try {
      final route = await MusicSystemAudioRoutes.read();
      if (!foreground || epoch != _epoch) return;
      if (route == null) {
        value = null;
      } else {
        _accept(route);
      }
    } on FormatException {
      if (!_closed && epoch == _epoch) value = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refresh();
    } else {
      _epoch++;
      value = null;
      final subscription = _subscription;
      _subscription = null;
      unawaited(subscription?.cancel());
    }
  }

  @override
  void dispose() {
    _closed = true;
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
