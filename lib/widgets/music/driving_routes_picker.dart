import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_driving_routes.dart';
import '../../services/music/music_system_audio_route_monitor.dart';
import '../../services/music/music_system_audio_routes.dart';

/// Chooses only currently selected Bluetooth media outputs. Remembered rows
/// remain removable after disconnect; an available-device list cannot arm them.
class MusicDrivingRoutesPicker extends StatefulWidget {
  const MusicDrivingRoutesPicker({super.key, required this.routes, required this.current});
  final MusicDrivingRoutes routes;
  final bool Function() current;
  @override
  State<MusicDrivingRoutesPicker> createState() => _MusicDrivingRoutesPickerState();
}

class _MusicDrivingRoutesPickerState extends State<MusicDrivingRoutesPicker> {
  MusicSystemAudioRouteMonitor? _monitor;
  bool _busy = false, _failed = false;
  bool get _current => mounted && widget.current();
  bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);
  String get _platform => defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  void initState() {
    super.initState();
    widget.routes.addListener(_changed);
    if (_supported) _monitor = MusicSystemAudioRouteMonitor(current: () => _current)..addListener(_changed);
  }

  void _changed() {
    if (_current) setState(() {});
  }

  @override
  void dispose() {
    widget.routes.removeListener(_changed);
    _monitor?.removeListener(_changed);
    _monitor?.dispose();
    super.dispose();
  }

  Future<void> _set(MusicSystemAudioOutput? output, MusicDrivingRoute? saved, bool enabled) async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      if (enabled) {
        // Recheck the exact live OS selection at the moment of the decision.
        if (output == null || _monitor?.value?.outputs.any((row) => row.bluetooth && row.id == output.id) != true) {
          throw StateError('Bluetooth output is no longer selected');
        }
        await widget.routes.select(platform: _platform, output: output, current: () => _current);
      } else if (saved != null) {
        await widget.routes.remove(route: saved, current: () => _current);
      }
      if (_current) setState(() => _failed = false);
    } catch (_) {
      if (_current) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.routes.reset(current: () => _current);
      if (_current) setState(() => _failed = false);
    } catch (_) {
      if (_current) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported || !_current) return const SizedBox.shrink();
    final saved = {
      for (final row in widget.routes.routes)
        if (row.platform == _platform) row.id: row,
    };
    final selected = {
      for (final output in _monitor?.value?.outputs ?? const <MusicSystemAudioOutput>[])
        if (output.bluetooth) output.id: output,
    };
    final ids = {...saved.keys, ...selected.keys};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t.musicExperience.bluetoothDriving, style: Theme.of(context).textTheme.titleMedium),
        Text(t.musicExperience.bluetoothDrivingHint),
        if (_busy || !widget.routes.loaded) const LinearProgressIndicator(),
        if (_failed || widget.routes.loaded && !widget.routes.available) Text(t.musicExperience.error),
        if (ids.isEmpty) Text(t.common.notAvailable),
        for (final id in ids)
          CheckboxListTile(
            key: ValueKey((_platform, id)),
            title: Text(selected[id]?.name ?? saved[id]!.name),
            value: saved.containsKey(id),
            onChanged: _busy || !widget.routes.available
                ? null
                : (enabled) => _set(selected[id], saved[id], enabled == true),
          ),
        if (saved.isNotEmpty || widget.routes.loaded && !widget.routes.available)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(onPressed: _busy ? null : _reset, child: Text(t.common.reset)),
          ),
      ],
    );
  }
}
