import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/motion_clarity.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/motion_clarity_service.dart';

void main() {
  test('motion compensation passes fractional display cadences to FFmpeg exactly', () async {
    for (final (displayRate, exactRate) in <(double, String)>[
      (48 * 1000 / 1001, '48000/1001'),
      (60 * 1000 / 1001, '60000/1001'),
      (120 * 1000 / 1001, '120000/1001'),
    ]) {
      final player = _RecordingPlayer(displayRate);
      final service = MotionClarityService.forPlayer(player);

      final result = await service.configure(
        preset: MotionClarityPreset.balanced,
        kernel: MotionTemporalKernel.linear,
        thresholdPercent: 1,
        beforeSourceOpen: true,
        engine: MotionClarityEngine.motionCompensated,
        sourceFps: 24,
      );

      expect(result.isConfigured, isTrue, reason: 'display rate $displayRate');
      expect(result.targetFps, closeTo(displayRate, 1e-9));
      expect(player.commands.single[2], contains('minterpolate=fps=$exactRate:'), reason: 'display rate $displayRate');
    }
  });

  test('non-finite display rate falls back without constructing an MCI filter', () async {
    final player = _RecordingPlayer(double.nan);
    final service = MotionClarityService.forPlayer(player);

    final result = await service.configure(
      preset: MotionClarityPreset.balanced,
      kernel: MotionTemporalKernel.linear,
      thresholdPercent: 1,
      beforeSourceOpen: true,
      engine: MotionClarityEngine.motionCompensated,
      sourceFps: 24,
    );

    expect(result.isConfigured, isTrue);
    expect(result.effectiveEngine, MotionClarityEngine.temporalBlend);
    expect(player.commands, isEmpty);
  });
}

class _RecordingPlayer implements Player {
  _RecordingPlayer(double displayRate) : _properties = {'display-fps': displayRate.toString(), 'vo': 'gpu-next'};

  final Map<String, String> _properties;
  final commands = <List<String>>[];
  @override
  final String playerType = 'mpv';
  @override
  final bool audioPassthroughActive = false;

  @override
  Future<String?> getProperty(String name) async => _properties[name];

  @override
  Future<void> setProperty(String name, String value) async {
    _properties[name] = value;
  }

  @override
  Future<void> command(List<String> args) async {
    commands.add(args);
  }

  @override
  PlayerState get state => const PlayerState();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
