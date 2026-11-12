import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/cast_media_service.dart';
import '../../../utils/formatters.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';

class CastVideoControlsScreen extends StatefulWidget {
  const CastVideoControlsScreen({super.key, required this.playback});

  final CastVideoPlayback playback;

  @override
  State<CastVideoControlsScreen> createState() => _CastVideoControlsScreenState();
}

class _CastVideoControlsScreenState extends State<CastVideoControlsScreen> {
  bool _busy = false;
  double? _scrubPosition;

  Future<void> _run(Future<void> Function() command) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await command();
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.companionRemote.errors.connectionLost);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _scrubPosition = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    return Scaffold(
      appBar: AppBar(title: Text(t.musicDevices.playingOn(device: playback.deviceName))),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: playback.changes,
          builder: (context, _) {
            final state = playback.state;
            final start = state?.seekStart.inMilliseconds.toDouble() ?? 0.0;
            final end = state?.seekEnd?.inMilliseconds.toDouble() ?? start;
            final position = _scrubPosition == null ? state?.position : Duration(milliseconds: _scrubPosition!.round());
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(playback.title, style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 16),
                      if (state == null) ...[
                        if (!playback.connected) Text(t.companionRemote.errors.connectionLost),
                        OutlinedButton(
                          onPressed: () => unawaited(Navigator.of(context).maybePop()),
                          child: Text(t.common.close),
                        ),
                      ] else ...[
                        if (end > start)
                          Slider(
                            value: (position?.inMilliseconds.toDouble() ?? start).clamp(start, end).toDouble(),
                            min: start,
                            max: end,
                            semanticFormatterCallback: (value) =>
                                formatDurationTimestamp(Duration(milliseconds: value.round())),
                            onChanged: _busy ? null : (value) => setState(() => _scrubPosition = value),
                            onChangeEnd: (value) =>
                                unawaited(_run(() => playback.seek(Duration(milliseconds: value.round())))),
                          ),
                        if (position != null)
                          Text(
                            [
                              formatDurationTimestamp(position),
                              if (state.duration case final duration?) formatDurationTimestamp(duration),
                            ].join(' / '),
                          ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: _busy ? null : () => unawaited(_run(playback.toggle)),
                              icon: AppIcon(state.paused ? Symbols.play_arrow_rounded : Symbols.pause_rounded),
                              label: Text(state.paused ? t.common.resume : t.common.pause),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => unawaited(
                                      _run(() async {
                                        await playback.stop();
                                        if (context.mounted) await Navigator.of(context).maybePop();
                                      }),
                                    ),
                              icon: const AppIcon(Symbols.stop_rounded),
                              label: Text(t.cast.stopCasting),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
