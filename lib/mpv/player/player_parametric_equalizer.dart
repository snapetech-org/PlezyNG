import 'package:flutter/foundation.dart' show listEquals;

typedef PlayerParametricBand = ({int filterType, double frequency, double gain, double q});

/// Finite numeric DSP parameters; never accepts a caller-supplied filter graph.
class PlayerParametricEqualizer {
  const PlayerParametricEqualizer({this.enabled = false, this.gain = 0, this.bands = const []});
  final bool enabled;
  final double gain;
  final List<PlayerParametricBand> bands;

  PlayerParametricEqualizer snapshot() {
    validate();
    return PlayerParametricEqualizer(enabled: enabled, gain: gain, bands: List.unmodifiable(bands));
  }

  void validate() {
    if (!gain.isFinite ||
        gain.abs() > 24 ||
        bands.length > 32 ||
        bands.any(
          (band) =>
              !const [0, 1, 2].contains(band.filterType) ||
              !band.frequency.isFinite ||
              band.frequency < 10 ||
              band.frequency > 22000 ||
              !band.gain.isFinite ||
              band.gain.abs() > 24 ||
              !band.q.isFinite ||
              band.q < .1 ||
              band.q > 20,
        )) {
      throw ArgumentError('Invalid parametric equalizer');
    }
  }

  List<String> get filters {
    validate();
    if (!enabled) return const [];
    return [
      if (gain != 0) 'volume=${gain}dB',
      for (final band in bands)
        if (band.gain != 0)
          '${switch (band.filterType) {
                0 => 'equalizer',
                1 => 'bass',
                _ => 'treble',
              }}'
              '=f=${band.frequency}:t=q:w=${band.q}:g=${band.gain}',
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerParametricEqualizer &&
      other.enabled == enabled &&
      other.gain == gain &&
      listEquals(other.bands, bands);
  @override
  int get hashCode => Object.hash(enabled, gain, Object.hashAll(bands));
}

abstract interface class ParametricEqualizerCapable {
  Future<void> setParametricEqualizer(PlayerParametricEqualizer equalizer);
}
