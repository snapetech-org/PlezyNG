import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'music_audio_policy.dart';

class MusicHeadphonePreset {
  const MusicHeadphonePreset({required this.name, required this.source, required this.bands});
  final String name, source;
  final List<double> bands;
  MusicAudioPolicy get policy => MusicAudioPolicy(bands: bands);
}

/// The catalog and response data are bundled: searching and applying a
/// headphone curve never disclose a query or require a network connection.
class MusicAutoEq {
  static Future<List<MusicHeadphonePreset>>? _catalog;
  static Future<List<MusicHeadphonePreset>> load() => _catalog ??= _load();
  static Future<List<MusicHeadphonePreset>> _load() async {
    try {
      return await compute(parse, await rootBundle.loadString('assets/music/autoeq.json'));
    } catch (_) {
      _catalog = null;
      rethrow;
    }
  }

  static List<MusicHeadphonePreset> parse(String encoded) {
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    if (json['version'] != 1 || json['profiles'] is! List || (json['profiles'] as List).length > 20000) {
      throw const FormatException('Unsupported AutoEq catalog');
    }
    final result = <MusicHeadphonePreset>[];
    for (final row in json['profiles'] as List) {
      final name = row['name'] as String, source = row['source'] as String;
      final bands = List<double>.unmodifiable((row['bands'] as List).map((value) => (value as num).toDouble()));
      if (name.isEmpty || name.length > 512 || source.length > 1024) {
        throw const FormatException('Invalid headphone name');
      }
      MusicAudioPolicy(bands: bands).validate();
      result.add(MusicHeadphonePreset(name: name, source: source, bands: bands));
    }
    return List.unmodifiable(result);
  }

  static List<MusicHeadphonePreset> search(List<MusicHeadphonePreset> presets, String query) {
    final terms = query.toLowerCase().trim().split(RegExp(r'\s+')).where((term) => term.isNotEmpty).toList();
    return presets.where((preset) => terms.every((term) => preset.name.toLowerCase().contains(term))).toList();
  }
}
