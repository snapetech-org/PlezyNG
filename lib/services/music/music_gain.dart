import 'dart:math' as math;

/// Keep the user's native volume curve while applying a linear DSP/fade gain.
double musicVolumeForGain(double volume, double gain, {required bool nativeCubic}) {
  if (!volume.isFinite || !gain.isFinite || gain < 0) throw ArgumentError('Invalid music gain');
  return (volume.clamp(0.0, 100.0) * (nativeCubic ? math.pow(gain, 1 / 3) : gain)).clamp(0.0, 100.0).toDouble();
}

double musicCaptureGain(double volume, {required bool nativeCubic}) {
  if (!volume.isFinite) throw ArgumentError('Invalid music volume');
  final normalized = volume.clamp(0.0, 100.0) / 100;
  return nativeCubic ? math.pow(normalized, 3).toDouble() : normalized;
}

/// The ordered tap precedes MPV's AO gain/mute. Reapply its native ReplayGain
/// and additional volume gain once, without repeating filters already in PCM.
class NativeMusicPcmGainReader {
  NativeMusicPcmGainReader(this.readProperty);
  final Future<String?> Function(String) readProperty;
  final _clock = Stopwatch()..start();
  Object? _revision;
  int _readAt = -1000;
  Future<double>? _pending;

  Future<double> read(Object revision) {
    if (_revision == revision && _pending != null && _clock.elapsedMilliseconds - _readAt < 250) return _pending!;
    _revision = revision;
    _readAt = _clock.elapsedMilliseconds;
    return _pending = _read();
  }

  static double? _number(String? text) {
    if (text == null) return null;
    final value = double.tryParse(text);
    if (value == null || !value.isFinite || value.abs() > 1000000) {
      throw const FormatException('Invalid native audio gain');
    }
    return value;
  }

  static double _amplitude(double db) {
    if (db.abs() > 200) throw const FormatException('Unsupported native audio gain');
    return math.pow(10, db / 20).toDouble();
  }

  Future<double> _read() async {
    final initial = await Future.wait([
      readProperty('replaygain'),
      readProperty('volume-gain'),
      readProperty('replaygain-fallback'),
    ]);
    final mode = initial[0] ?? 'no', extra = _number(initial[1]) ?? 0, fallback = _number(initial[2]) ?? 0;
    var gain = _amplitude(fallback);
    if (mode == 'track' || mode == 'album') {
      final detail = await Future.wait([
        readProperty('current-tracks/audio/replaygain-$mode-gain'),
        readProperty('current-tracks/audio/replaygain-$mode-peak'),
        readProperty('replaygain-preamp'),
        readProperty('replaygain-clip'),
      ]);
      final tagged = _number(detail[0]);
      if (tagged != null) {
        gain = _amplitude(tagged + (_number(detail[2]) ?? 0));
        final peak = _number(detail[1]) ?? 1;
        if (peak < 0) throw const FormatException('Invalid native ReplayGain peak');
        if (detail[3] != 'yes' && peak > 0) gain = math.min(gain, 1 / peak);
      }
    } else if (mode != 'no') {
      throw const FormatException('Unsupported native ReplayGain mode');
    }
    final result = gain * _amplitude(extra);
    if (!result.isFinite || result > 1000000) throw const FormatException('Unsupported native audio gain');
    return result;
  }
}
