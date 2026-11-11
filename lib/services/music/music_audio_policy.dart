import 'dart:math' as math;
import 'dart:io' show Platform;

import '../../media/media_source_info.dart';
import '../../mpv/models.dart';
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
    this.prefetchMiB = 256,
    this.prefetchWifiOnly = true,
  });
  final MusicLeveling leveling;
  final double preampDb;
  final List<double> bands;
  final int sampleRate, cacheMiB, bufferSeconds, prefetchMiB;
  final bool prefetchWifiOnly;
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
        prefetchMiB < 0 ||
        prefetchMiB > 2048 ||
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
    'prefetchMiB': prefetchMiB,
    'prefetchWifiOnly': prefetchWifiOnly,
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
      prefetchMiB: json['prefetchMiB'] as int? ?? 256,
      prefetchWifiOnly: json['prefetchWifiOnly'] as bool? ?? true,
    );
    policy.validate();
    return policy;
  }

  /// Use explicit server gain only when native tags are absent. MPV does not
  /// apply clip prevention to replaygain-fallback, so bound it here. Unknown
  /// peaks permit attenuation but never positive gain; relative seek-print
  /// levels cannot supply an absolute loudness estimate.
  ReplayGainSettings replayGain({required bool albumContext, MediaSourceInfo? source}) {
    final mode = switch (leveling) {
      MusicLeveling.off => ReplayGainMode.off,
      MusicLeveling.track => ReplayGainMode.track,
      MusicLeveling.album => ReplayGainMode.album,
      MusicLeveling.automatic => albumContext ? ReplayGainMode.album : ReplayGainMode.track,
    };
    if (mode == ReplayGainMode.off) return ReplayGainSettings(mode: mode);
    final tracks = source?.audioTracks ?? const <MediaAudioTrack>[];
    final selected = tracks.where((track) => track.selected).toList();
    final track = selected.length == 1
        ? selected.single
        : (selected.isEmpty && tracks.length == 1 ? tracks.single : null);
    final analysis = track?.replayGain;
    if (analysis == null) return ReplayGainSettings(mode: mode);
    final albumDb = mode == ReplayGainMode.album ? MediaReplayGain.validDb(analysis.albumDb) : null;
    final db = albumDb ?? MediaReplayGain.validDb(analysis.trackDb);
    if (db == null) return ReplayGainSettings(mode: mode);
    final albumPeak = albumDb == null ? null : MediaReplayGain.validPeak(analysis.albumPeak);
    final trackPeak = MediaReplayGain.validPeak(analysis.trackPeak);
    final peak = albumPeak == null ? trackPeak : math.max(albumPeak, trackPeak ?? 0);
    final ceiling = peak == null ? 0.0 : -20 * math.log(peak) / math.ln10;
    return ReplayGainSettings(mode: mode, fallbackDb: math.min(db, ceiling).clamp(-60.0, 24.0));
  }

  Future<void> apply(
    Player player, {
    required bool albumContext,
    MediaSourceInfo? source,
    bool Function()? isCurrent,
  }) async {
    validate();
    bool current() => isCurrent?.call() ?? true;
    if (!current()) return;
    if (player.playerType != 'mpv') throw UnsupportedError('This output does not expose music DSP controls');
    if (leveling != MusicLeveling.off || bands.any((b) => b != 0) || preampDb != 0) {
      await player.setAudioPassthrough(false);
    }
    // Native tags take precedence over the bounded server-analysis fallback.
    // Video compression remains off.
    if (!current()) return;
    await player.setAudioNormalization(false);
    if (!current()) return;
    if (player is AudioEqualizerCapable) await (player as AudioEqualizerCapable).setAudioEqualizer(bands);
    if (!current()) return;
    final gain = replayGain(albumContext: albumContext, source: source);
    await player.setProperty('replaygain', gain.mpvMode);
    if (!current()) return;
    await player.setProperty('replaygain-clip', 'no');
    if (!current()) return;
    await player.setProperty('replaygain-fallback', '${gain.fallbackDb}');
    if (!current()) return;
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
  Future<Map<String, String>> availableAudioOutputs();
  Future<MusicAudioPolicy?> outputEqualizer(String output);
  Future<void> setOutputEqualizer(String output, MusicAudioPolicy? policy);
}

abstract interface class MusicCacheControls {
  Future<void> clearPrefetchCache();
}
