import 'dart:async';
import '../../mpv/player/player_parametric_equalizer.dart';
export '../../mpv/player/player_parametric_equalizer.dart';

abstract interface class CalderaEqualizerControls {
  PlayerParametricEqualizer get calderaEqualizer;
  Future<void> setCalderaEqualizer(PlayerParametricEqualizer value, {required bool Function() current});
}

/// Native commands update individual fields; compose them at execution time so
/// rapid enable/gain/band changes do not overwrite an earlier queued decision.
class CalderaMeshEqualizer {
  CalderaMeshEqualizer(this.controls);
  final CalderaEqualizerControls controls;
  Future<void> _tail = Future.value();
  int _queued = 0;

  static bool supports(Object? method) =>
      const ['SetSinkEqualizerEnabled', 'SetSinkEqualizerGain', 'SetSinkEqualizerBands'].contains(method);

  static Map<String, Object> snapshot(PlayerParametricEqualizer value) {
    value.validate();
    return {
      'enabled': value.enabled,
      'gain': value.gain,
      'bands': [
        for (final band in value.bands)
          {'filterType': band.filterType, 'frequency': band.frequency, 'gain': band.gain, 'q': band.q},
      ],
    };
  }

  static PlayerParametricEqualizer restore(Map<String, dynamic> data) {
    final enabled = data['enabled'], gain = data['gain'];
    if (enabled is! bool || gain is! num) throw const FormatException('Invalid native equalizer snapshot');
    try {
      return PlayerParametricEqualizer(
        enabled: enabled,
        gain: gain.toDouble(),
        bands: _bands(data['bands']),
      ).snapshot();
    } on ArgumentError {
      throw const FormatException('Invalid native equalizer snapshot');
    }
  }

  static List<PlayerParametricBand> _bands(Object? value) {
    if (value is! List || value.length > 32) throw const FormatException('Invalid native equalizer bands');
    final result = <PlayerParametricBand>[];
    for (final entry in value) {
      if (entry is! Map ||
          entry.length != 4 ||
          entry['filterType'] is! int ||
          entry['frequency'] is! num ||
          entry['gain'] is! num ||
          entry['q'] is! num) {
        throw const FormatException('Invalid native equalizer band');
      }
      result.add((
        filterType: entry['filterType'] as int,
        frequency: (entry['frequency'] as num).toDouble(),
        gain: (entry['gain'] as num).toDouble(),
        q: (entry['q'] as num).toDouble(),
      ));
    }
    try {
      PlayerParametricEqualizer(bands: result).validate();
    } on ArgumentError {
      throw const FormatException('Invalid native equalizer band');
    }
    return List.unmodifiable(result);
  }

  Future<void> apply(
    Object? method,
    Object? payload, {
    required bool Function() current,
    required void Function() changed,
  }) {
    if (!supports(method) || payload is! Map || payload.length != 1) {
      throw const FormatException('Invalid native equalizer command');
    }
    bool? enabled;
    double? gain;
    List<PlayerParametricBand>? bands;
    switch (method) {
      case 'SetSinkEqualizerEnabled':
        if (payload['enabled'] is! bool) throw const FormatException('Invalid native equalizer enable');
        enabled = payload['enabled'] as bool;
      case 'SetSinkEqualizerGain':
        final value = payload['gain'];
        if (value is! num || !value.isFinite || value.abs() > 24) {
          throw const FormatException('Invalid native equalizer gain');
        }
        gain = value.toDouble();
      case 'SetSinkEqualizerBands':
        bands = _bands(payload['bands']);
    }
    if (!current() || _queued >= 32) throw StateError('Native equalizer unavailable');
    _queued++;
    final operation = _tail.then((_) async {
      if (!current()) throw StateError('Native equalizer scope changed');
      final previous = controls.calderaEqualizer;
      final value = PlayerParametricEqualizer(
        enabled: enabled ?? previous.enabled,
        gain: gain ?? previous.gain,
        bands: bands ?? previous.bands,
      ).snapshot();
      await controls.setCalderaEqualizer(value, current: current);
      if (current()) changed();
    });
    _tail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation.whenComplete(() => _queued--);
  }
}
