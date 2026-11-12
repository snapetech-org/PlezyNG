import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_system_audio_routes.dart';

/// The supported Apple audio-session picker. macOS uses mpv's CoreAudio
/// device selection; it must not present an AVPlayer-only route as an mpv one.
class MusicAppleAudioRoutePicker extends StatefulWidget {
  const MusicAppleAudioRoutePicker({super.key, required this.current, required this.onChanged});
  final bool Function() current;
  final VoidCallback onChanged;
  @override
  State<MusicAppleAudioRoutePicker> createState() => _MusicAppleAudioRoutePickerState();
}

class _MusicAppleAudioRoutePickerState extends State<MusicAppleAudioRoutePicker> with WidgetsBindingObserver {
  StreamSubscription<MusicSystemAudioRoute>? _subscription;
  MusicSystemAudioRoute? _route;
  int _epoch = 0;
  bool get _current => mounted && widget.current();
  bool get _foreground =>
      _current &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _listen();
      unawaited(_read());
    }
  }

  void _accept(MusicSystemAudioRoute route) {
    if (!_foreground) return;
    _epoch++;
    setState(() => _route = route);
    widget.onChanged();
  }

  void _listen() {
    if (_subscription != null) return;
    _subscription = MusicSystemAudioRoutes.changes.listen(
      _accept,
      onError: (Object _) {
        _epoch++;
        if (_current) setState(() => _route = null);
      },
    );
  }

  Future<void> _read() async {
    final epoch = ++_epoch;
    try {
      final route = await MusicSystemAudioRoutes.read();
      if (!_foreground || epoch != _epoch) return;
      if (route == null) {
        setState(() => _route = null);
      } else {
        _accept(route);
      }
    } on FormatException {
      if (_current && epoch == _epoch) setState(() => _route = null);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _epoch++;
    if (state == AppLifecycleState.resumed) {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        _listen();
        unawaited(_read());
      }
    } else {
      if (mounted) setState(() => _route = null);
      final subscription = _subscription;
      _subscription = null;
      unawaited(subscription?.cancel());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = _route;
    if (!_current || route == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(t.videoSettings.audioOutput),
            SizedBox(
              width: 48,
              height: 48,
              child: UiKitView(
                viewType: 'com.pleazyng/music_audio_route_picker',
                creationParams: {'tint': Theme.of(context).colorScheme.onSurface.toARGB32()},
                creationParamsCodec: const StandardMessageCodec(),
              ),
            ),
          ],
        ),
        for (final output in route.outputs)
          Text('${output.name.isEmpty ? t.common.unknown : output.name} · ${output.type}'),
        Text('${t.performanceOverlay.sampleRate}: ${route.sampleRate.toStringAsFixed(0)} Hz'),
      ],
    );
  }
}
