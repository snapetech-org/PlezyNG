import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'subtitle_wav_reader.dart';

final class SubtitleWaveform {
  const SubtitleWaveform({required this.startMs, required this.endMs, required this.peaks,
      required this.spectrum, required this.columns, required this.bins});
  final int startMs;
  final int endMs;
  final Float32List peaks;
  final Uint8List spectrum;
  final int columns;
  final int bins;
}

abstract final class SubtitleWaveformService {
  static Future<SubtitleWaveform> analyze(String path, {required int startMs, required int endMs}) {
    if (startMs < 0 || endMs <= startMs || endMs - startMs > 300000) {
      throw const FormatException('Choose an audio range up to five minutes for waveform editing.');
    }
    return Isolate.run(() => _analyze(path, startMs, endMs));
  }

  static Future<SubtitleWaveform> _analyze(String path, int startMs, int endMs) async {
    const columns = 1024, bins = 64, fftSize = 512;
    final reader = await SubtitleWavReader.open(path);
    try {
      if (endMs > reader.durationMs) throw const FormatException('The waveform interval exceeds the audio duration.');
      final peaks = Float32List(columns);
      final spectrum = Uint8List(columns * bins);
      final ring = Float64List(fftSize);
      final totalFrames = ((endMs - startMs) * 16).clamp(1, 4800000).toInt();
      var frame = 0, column = 0;
      await reader.forEachMono16kChunk((samples) async {
        for (final sample in samples) {
          ring[frame % fftSize] = sample;
          final bucket = (frame * columns ~/ totalFrames).clamp(0, columns - 1).toInt();
          if (sample.abs() > peaks[bucket]) peaks[bucket] = sample.abs();
          ++frame;
          while (column < columns && frame >= ((column + 1) * totalFrames ~/ columns)) {
            final real = Float64List(fftSize), imaginary = Float64List(fftSize);
            for (var i = 0; i < fftSize; i++) {
              final offset = frame - fftSize + i;
              real[i] = (offset < 0 ? 0 : ring[offset % fftSize]) * (0.5 - 0.5 * math.cos(2 * math.pi * i / (fftSize - 1)));
            }
            _fft(real, imaginary);
            for (var bin = 0; bin < bins; bin++) {
              var power = 0.0;
              for (var j = 0; j < 4; j++) {
                final index = bin * 4 + j;
                power += real[index] * real[index] + imaginary[index] * imaginary[index];
              }
              final db = 10 * math.log(math.max(power / (fftSize * fftSize), 1e-10)) / math.ln10;
              spectrum[column * bins + bin] = ((db + 80) * 255 / 80).round().clamp(0, 255).toInt();
            }
            ++column;
          }
        }
      }, startMs: startMs, endMs: endMs);
      return SubtitleWaveform(startMs: startMs, endMs: endMs, peaks: peaks,
          spectrum: spectrum, columns: columns, bins: bins);
    } finally { await reader.close(); }
  }

  /// In-place radix-2 FFT on one bounded Hann-windowed audio frame.
  static void _fft(Float64List real, Float64List imaginary) {
    final n = real.length;
    var j = 0;
    for (var i = 1; i < n; i++) {
      var bit = n >> 1;
      while ((j & bit) != 0) { j ^= bit; bit >>= 1; }
      j ^= bit;
      if (i < j) { final value = real[i]; real[i] = real[j]; real[j] = value; }
    }
    for (var length = 2; length <= n; length <<= 1) {
      final angle = -2 * math.pi / length;
      final wr = math.cos(angle), wi = math.sin(angle);
      for (var start = 0; start < n; start += length) {
        var ur = 1.0, ui = 0.0;
        for (var offset = 0; offset < length ~/ 2; offset++) {
          final a = start + offset, b = a + length ~/ 2;
          final vr = real[b] * ur - imaginary[b] * ui;
          final vi = real[b] * ui + imaginary[b] * ur;
          real[b] = real[a] - vr; imaginary[b] = imaginary[a] - vi;
          real[a] += vr; imaginary[a] += vi;
          final nextUr = ur * wr - ui * wi;
          ui = ur * wi + ui * wr; ur = nextUr;
        }
      }
    }
  }
}
