import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_system_audio_routes.dart';
import '../../services/music/music_system_audio_route_monitor.dart';

/// The supported Apple audio-session picker. macOS uses mpv's CoreAudio
/// device selection; it must not present an AVPlayer-only route as an mpv one.
class MusicAppleAudioRoutePicker extends StatefulWidget {
  const MusicAppleAudioRoutePicker({super.key, required this.current, required this.onChanged});
  final bool Function() current;
  final VoidCallback onChanged;
  @override
  State<MusicAppleAudioRoutePicker> createState() => _MusicAppleAudioRoutePickerState();
}

class _MusicAppleAudioRoutePickerState extends State<MusicAppleAudioRoutePicker> {
  MusicSystemAudioRouteMonitor? _monitor;
  MusicSystemAudioRoute? get _route => _monitor?.value;
  bool get _current => mounted && widget.current();

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _monitor = MusicSystemAudioRouteMonitor(current: () => _current)..addListener(_changed);
    }
  }

  void _changed() {
    if (!_current) return;
    setState(() {});
    widget.onChanged();
  }

  @override
  void dispose() {
    _monitor?.removeListener(_changed);
    _monitor?.dispose();
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
