import 'apple_audio_route_picker.dart';
import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_audio_policy.dart';

/// Manual output inspection and recovery for one profile's shared session.
/// Opening or refreshing this panel never changes the queue or starts audio.
class MusicAudioOutputPanel extends StatefulWidget {
  const MusicAudioOutputPanel({super.key, required this.audio, required this.current, required this.onAutomaticOutput});
  final MusicAudioControls audio;
  final bool Function() current;
  final VoidCallback onAutomaticOutput;
  @override
  State<MusicAudioOutputPanel> createState() => _MusicAudioOutputPanelState();
}

class _MusicAudioOutputPanelState extends State<MusicAudioOutputPanel> with WidgetsBindingObserver {
  bool _open = false, _busy = false, _failed = false;
  int _epoch = 0;
  Map<String, String>? _snapshot;
  bool get _current => mounted && widget.current();
  bool get _visible =>
      _current &&
      _open &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) &&
      ModalRoute.of(context)?.isCurrent != false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _epoch++;
    if (mounted) setState(() => _busy = false);
    if (state == AppLifecycleState.resumed && _visible) _read();
  }

  Future<void> _read() async {
    if (!_visible || _busy) return;
    final epoch = ++_epoch;
    setState(() => _busy = true);
    try {
      final values = await widget.audio.inspectAudioOutput();
      if (_visible && epoch == _epoch) {
        setState(() {
          _snapshot = Map.unmodifiable(values);
          _failed = false;
        });
      }
    } catch (_) {
      if (_visible && epoch == _epoch) {
        setState(() {
          _snapshot = null;
          _failed = true;
        });
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _automatic() async {
    if (!_visible || _busy || _snapshot?.isNotEmpty != true) return;
    final epoch = ++_epoch;
    setState(() => _busy = true);
    try {
      // Use the applied policy, preserving general DSP/cache settings rather
      // than silently saving any unrelated edits still in the settings form.
      final policy = MusicAudioPolicy.fromJson({
        ...widget.audio.audioPolicy.toJson(),
        'output': 'auto',
        'exclusive': false,
        'sampleRate': 0,
      });
      await widget.audio.setAudioPolicy(policy);
      if (_visible && epoch == _epoch) {
        widget.onAutomaticOutput();
        setState(() {
          _snapshot = null;
          _failed = false;
        });
      }
    } catch (_) {
      if (_visible && epoch == _epoch) setState(() => _failed = true);
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
    if (_visible && epoch == _epoch) await _read();
  }

  @override
  Widget build(BuildContext context) => !_current
      ? const SizedBox.shrink()
      : ExpansionTile(
          title: Text(t.musicExperience.signalPath),
          subtitle: Text(t.videoSettings.audioOutput),
          onExpansionChanged: (open) {
            _epoch++;
            setState(() {
              _open = open;
              _busy = false;
            });
            if (open) _read();
          },
          children: [
            if (_open)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_snapshot?.isNotEmpty == true)
                      MusicAppleAudioRoutePicker(
                        current: () => _visible,
                        onChanged: () {
                          if (_visible && !_busy) _read();
                        },
                      ),
                    if (_busy) const LinearProgressIndicator(),
                    if (_failed) Text(t.musicExperience.error),
                    if (_snapshot?.isNotEmpty != true && !_busy) Text(t.musicExperience.outputUnknown),
                    for (final entry in _snapshot?.entries ?? const <MapEntry<String, String>>[])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: SelectableText('${entry.key}: ${entry.value}'),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(onPressed: _busy ? null : _read, child: Text(t.common.refresh)),
                        OutlinedButton(
                          onPressed: _busy || _snapshot?.isNotEmpty != true ? null : _automatic,
                          child: Text('${t.common.reset} · ${t.settings.playbackBufferAuto}'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
}
