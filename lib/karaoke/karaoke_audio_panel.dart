import '../widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../i18n/strings.g.dart' as l10n;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'karaoke_audio.dart';
import 'karaoke_scoring.dart';
import 'karaoke_session.dart';

class KaraokeAudioPanel extends StatefulWidget {
  const KaraokeAudioPanel({super.key, required this.session, required this.audio, required this.singer});
  final KaraokeSession session;
  final KaraokeAudio audio;
  final String? singer;
  @override
  State<KaraokeAudioPanel> createState() => _KaraokeAudioPanelState();
}

class _KaraokeAudioPanelState extends State<KaraokeAudioPanel> {
  bool _busy = false;
  Future<void> run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      widget.session.report(e);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> enable() => run(() async {
    final devices = await widget.audio.devices();
    if (!mounted) {
      return;
    }
    InputDevice? device;
    if (devices.length > 1) {
      device = await showDialog<InputDevice>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(l10n.t.karaokeUi.chooseAMicrophone),
          children: devices
              .map((d) => SimpleDialogOption(onPressed: () => Navigator.pop(context, d), child: Text(d.label)))
              .toList(),
        ),
      );
      if (device == null) {
        return;
      }
    } else {
      device = devices.firstOrNull;
    }
    await widget.audio.start(singer: widget.singer!, device: device);
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.audio,
    builder: (context, _) {
      final a = widget.audio, s = widget.session, result = a.score?.result();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.t.karaokeUi.microphoneAndPrivateTake, style: Theme.of(context).textTheme.titleLarge),
              Text(
                a.supported
                    ? l10n.t.karaokeUi.pitchFeedbackAndDryRecordingUseYourSelectedMicrophone
                    : l10n.t.karaokeUi.tvMicrophoneCaptureUnavailable,
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy || a.starting || widget.singer == null || !s.hasPerformance || !a.supported
                        ? null
                        : () => a.capturing ? run(a.stop) : enable(),
                    icon: AppIcon(a.capturing ? Symbols.mic_off_rounded : Symbols.mic_rounded),
                    label: Text(a.capturing ? l10n.t.karaokeUi.muteMicrophone : l10n.t.karaokeUi.enableMicrophone),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || !a.capturing
                        ? null
                        : () => run(a.recording ? a.stopRecording : a.startRecording),
                    icon: AppIcon(a.recording ? Symbols.stop_rounded : Symbols.fiber_manual_record_rounded),
                    label: Text(a.recording ? l10n.t.karaokeUi.savePrivateTake : l10n.t.karaokeUi.recordPrivateTake),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: (a.rms * 4).clamp(0, 1), semanticsLabel: l10n.t.karaokeUi.microphoneLevel),
              Text(
                a.midi == null
                    ? l10n.t.karaokeUi.noConfidentPitch
                    : l10n.t.karaokeUi.pitchMIDI(value1: a.midi!.toStringAsFixed(1)),
              ),
              if (a.trace.isNotEmpty)
                SizedBox(height: 120, child: CustomPaint(painter: _PitchTrace(a.trace.toList(), s.positionMs.value))),
              Text(
                result?['eligible'] == true
                    ? l10n.t.karaokeUi.performanceScore(
                        value1: result!['score'].toString(),
                        value2: KaraokeScore.rulesVersion,
                      )
                    : result?['invalidated'] == true
                    ? l10n.t.karaokeUi.practicePassCompetitiveScoringDisabled
                    : l10n.t.karaokeUi.singAlongNeedsReviewedChart,
              ),
              Text(
                l10n.t.karaokeUi.inputOffsetMs(
                  value1: (a.inputOffsetMs).toString(),
                  value2: a.calibrated ? l10n.t.karaokeUi.inputCalibrated : l10n.t.karaokeUi.inputManualUncalibrated,
                ),
              ),
              Slider(
                min: -500,
                max: 1000,
                divisions: 150,
                value: a.inputOffsetMs.toDouble().clamp(-500, 1000),
                label: l10n.t.karaokeUi.inputOffsetSliderLabel(value1: a.inputOffsetMs.toString()),
                onChanged: _busy ? null : (value) => run(() => a.setCalibration(value.round(), measured: false)),
              ),
              TextButton(
                onPressed: _busy || a.rangeSamples.length < 30 || widget.singer == null
                    ? null
                    : () => run(() async {
                        final range = karaokeRange(a.rangeSamples, s.track?.notes ?? []),
                            singer = s.singers.firstWhere((p) => p.id == widget.singer);
                        singer.lowMidi = range.low;
                        singer.highMidi = range.high;
                        await s.save();
                        if (mounted && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                l10n.t.karaokeUi.comfortableRangeSavedMIDISuggestedKey(
                                  value1: (range.low.round()).toString(),
                                  value2: (range.high.round()).toString(),
                                  value3: (range.suggestedKey).toString(),
                                ),
                              ),
                            ),
                          );
                        }
                      }),
                child: Text(l10n.t.karaokeUi.saveMyComfortableRange),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _PitchTrace extends CustomPainter {
  _PitchTrace(this.frames, this.now);
  final List<KaraokePitch> frames;
  final int now;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.amber
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    var connected = false;
    for (final f in frames.where((f) => f.sourceMs > now - 10000)) {
      if (f.midi == null) {
        connected = false;
        continue;
      }
      final x = (f.sourceMs - (now - 10000)) / 10000 * size.width,
          y = size.height * (1 - (f.midi! - 36) / 60).clamp(0, 1);
      if (!connected) {
        path.moveTo(x, y);
        connected = true;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_PitchTrace old) => true;
}
