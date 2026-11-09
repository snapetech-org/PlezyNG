import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../media/media_source_info.dart';
import '../../services/music/music_playback_service.dart';

/// Bounded server-analysis overview. The adjacent standard seek slider retains
/// keyboard, screen-reader and fine-seeking behavior when analysis is absent.
class MusicSeekPrint extends StatefulWidget {
  const MusicSeekPrint({super.key, required this.trackKey});
  final String trackKey;
  @override
  State<MusicSeekPrint> createState() => _MusicSeekPrintState();
}

class _MusicSeekPrintState extends State<MusicSeekPrint> {
  Future<AudioLoudnessProfile?>? _profile;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(MusicSeekPrint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackKey != widget.trackKey) {
      _profile = null;
      _load();
    }
  }

  void _load() {
    final service = context.read<MusicPlaybackService>();
    if (_profile == null && service is MusicLoudnessProfileService) {
      _profile = (service as MusicLoudnessProfileService).loadCurrentTrackLoudnessProfile();
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.read<MusicPlaybackService>();
    return FutureBuilder<AudioLoudnessProfile?>(
      future: _profile,
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final duration = service.duration;
        if (profile == null || profile.isEmpty || duration == null || duration <= Duration.zero) {
          return const SizedBox.shrink();
        }
        final colors = Theme.of(context).colorScheme;
        return ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              onTapDown: (details) {
                final fraction = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                service.seek(Duration(milliseconds: (fraction * duration.inMilliseconds).round()));
              },
              child: StreamBuilder<Duration>(
                stream: service.positionStream,
                initialData: service.position,
                builder: (context, position) => CustomPaint(
                  size: const Size(double.infinity, 28),
                  painter: _SeekPrintPainter(
                    profile.levelsDb,
                    (position.data ?? Duration.zero).inMilliseconds / duration.inMilliseconds,
                    colors.primary,
                    colors.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SeekPrintPainter extends CustomPainter {
  const _SeekPrintPainter(this.levels, this.progress, this.played, this.upcoming);
  final List<double> levels;
  final double progress;
  final Color played, upcoming;
  @override
  void paint(Canvas canvas, Size size) {
    final count = math.min(256, math.max(1, (size.width / 3).floor()));
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final level = levels[(i * levels.length ~/ count).clamp(0, levels.length - 1)];
      final height = level.isFinite ? ((level + 60) / 60).clamp(.04, 1.0) * size.height : 1.0;
      final x = (i + .5) * size.width / count;
      paint.color = i / count <= progress ? played : upcoming;
      canvas.drawLine(Offset(x, (size.height - height) / 2), Offset(x, (size.height + height) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_SeekPrintPainter old) =>
      old.levels != levels || old.progress != progress || old.played != played || old.upcoming != upcoming;
}
