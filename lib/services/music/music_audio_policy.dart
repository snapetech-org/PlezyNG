import 'dart:math' as math;
import 'dart:io' show Platform;

import '../../mpv/player/player.dart';
import '../preferred_audio_device.dart';

enum MusicLeveling { off, track, album, automatic }

class MusicAudioPolicy {
  const MusicAudioPolicy({
    this.leveling = MusicLeveling.off,
    this.preampDb = 0,
    this.bands = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.sampleRate = 0,
    this.exclusive = false,
    this.output = 'auto',
    this.cacheMiB = 64,
    this.bufferSeconds = 120,
  });
  final MusicLeveling leveling;
  final double preampDb;
  final List<double> bands;
  final int sampleRate, cacheMiB, bufferSeconds;
  final bool exclusive;
  final String output;
  static const frequencies = [31.25, 62.5, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

  void validate() {
    if (bands.length != 10 ||
        bands.any((b) => !b.isFinite || b.abs() > 12) ||
        !preampDb.isFinite ||
        preampDb < -24 ||
        preampDb > 0 ||
        !const [0, 44100, 48000, 88200, 96000, 176400, 192000].contains(sampleRate) ||
        cacheMiB < 8 ||
        cacheMiB > 512 ||
        bufferSeconds < 5 ||
        bufferSeconds > 600 ||
        output.isEmpty ||
        output.length > 512 ||
        output.contains('\n') ||
        output.contains('\u0000')) {
      throw ArgumentError('Invalid music audio policy');
    }
  }

  // Summed positive filter gains conservatively bound overlapping EQ boosts.
  double get gain =>
      math.pow(10, (preampDb - bands.where((b) => b > 0).fold<double>(0, (a, b) => a + b)) / 20).toDouble();
  Map<String, dynamic> toJson() => {
    'version': 1,
    'leveling': leveling.name,
    'preampDb': preampDb,
    'bands': bands,
    'sampleRate': sampleRate,
    'exclusive': exclusive,
    'output': output,
    'cacheMiB': cacheMiB,
    'bufferSeconds': bufferSeconds,
  };
  factory MusicAudioPolicy.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('Unsupported audio policy');
    final policy = MusicAudioPolicy(
      leveling: MusicLeveling.values.byName(json['leveling'] as String),
      preampDb: (json['preampDb'] as num).toDouble(),
      bands: List.unmodifiable((json['bands'] as List).map((b) => (b as num).toDouble())),
      sampleRate: json['sampleRate'] as int,
      exclusive: json['exclusive'] as bool,
      output: json['output'] as String,
      cacheMiB: json['cacheMiB'] as int,
      bufferSeconds: json['bufferSeconds'] as int,
    );
    policy.validate();
    return policy;
  }

  Future<void> apply(Player player, {required bool albumContext}) async {
    validate();
    if (player.playerType != 'mpv') throw UnsupportedError('This output does not expose music DSP controls');
    if (leveling != MusicLeveling.off || bands.any((b) => b != 0) || preampDb != 0) {
      await player.setAudioPassthrough(false);
    }
    // ReplayGain reads native file tags. No tag => 0 dB, never a guessed gain
    // derived from the seek-print's relative envelope. Video compression is off.
    await player.setAudioNormalization(false);
    if (player is AudioEqualizerCapable) await (player as AudioEqualizerCapable).setAudioEqualizer(bands);
    final mode = leveling == MusicLeveling.automatic ? (albumContext ? 'album' : 'track') : leveling.name;
    await player.setProperty('replaygain', mode == 'off' ? 'no' : mode);
    await player.setProperty('replaygain-clip', 'no');
    await player.setProperty('replaygain-fallback', '0');
    await player.setProperty('audio-samplerate', '$sampleRate');
    // Apple's fallback AudioUnit interprets this as AVAudioSession mixing,
    // not desktop DAC exclusivity. Music must retain lock-screen ownership.
    await player.setProperty('audio-exclusive', (Platform.isIOS || exclusive) ? 'yes' : 'no');
    // An unplugged explicit device must not leave mpv on its null output.
    await player.setProperty('audio-device', 'auto');
    await applyPreferredAudioDevice(player, output);
    await player.setProperty('demuxer-max-bytes', '${cacheMiB * 1024 * 1024}');
    await player.setProperty('demuxer-readahead-secs', '$bufferSeconds');
  }

  /// Import the documented AutoEq GraphicEQ format, logarithmically resampling
  /// its response to this engine's ten bands. It is an approximation, never a
  /// claim that a ten-band EQ reproduces a dense measured convolution filter.
  static List<double> parseGraphicEq(String text) {
    if (text.length > 64000) throw const FormatException('EQ response too large');
    final source = text.trim().replaceFirst(RegExp(r'^GraphicEQ:\s*'), '');
    final points = <(double, double)>[];
    for (final part in source.split(';')) {
      final values = part.trim().split(RegExp(r'\s+'));
      if (values.length != 2) throw const FormatException('Expected frequency and gain');
      final hz = double.parse(values[0]), db = double.parse(values[1]);
      if (!hz.isFinite || !db.isFinite || hz < 10 || hz > 100000 || db.abs() > 60) {
        throw const FormatException('Invalid EQ point');
      }
      if (points.isNotEmpty && hz <= points.last.$1) throw const FormatException('Frequencies must increase');
      points.add((hz, db));
    }
    if (points.length < 2) throw const FormatException('Not enough EQ points');
    return frequencies.map((hz) {
      if (hz <= points.first.$1) return points.first.$2.clamp(-12.0, 12.0);
      if (hz >= points.last.$1) return points.last.$2.clamp(-12.0, 12.0);
      final upper = points.indexWhere((p) => p.$1 >= hz), a = points[upper - 1], b = points[upper];
      final t = math.log(hz / a.$1) / math.log(b.$1 / a.$1);
      return (a.$2 + (b.$2 - a.$2) * t).clamp(-12.0, 12.0);
    }).toList();
  }
}

abstract interface class MusicAudioControls {
  MusicAudioPolicy get audioPolicy;
  Future<void> setAudioPolicy(MusicAudioPolicy policy);
  Future<Map<String, String>> inspectAudioOutput();
}
