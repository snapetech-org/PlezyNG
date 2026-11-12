/// Bounded, display-safe analysis data returned by an optional preparation
/// companion. These estimates never become scored note charts implicitly.
class KaraokeAnalysis {
  static const maxDurationMs = 24 * 60 * 60 * 1000;
  static const maxChordCount = 20000;

  static Map<String, dynamic> normalize(Map<String, dynamic> value) {
    final result = <String, dynamic>{};
    final rawKey = value['key'];
    if (rawKey != null) {
      if (rawKey is! String) throw const FormatException('Invalid analysis key');
      final key = rawKey.trim();
      if (key.length > 32 || key.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const FormatException('Invalid analysis key');
      }
      if (key.isNotEmpty) result['key'] = key;
    }

    final rawBpm = value['bpm'];
    if (rawBpm != null) {
      if (rawBpm is! num || !rawBpm.isFinite || rawBpm < 20 || rawBpm > 400) {
        throw const FormatException('Invalid analysis tempo');
      }
      result['bpm'] = rawBpm.toDouble();
    }

    final rawConfidence = value['confidence'];
    if (rawConfidence != null) {
      if (rawConfidence is! num || !rawConfidence.isFinite || rawConfidence < 0 || rawConfidence > 1) {
        throw const FormatException('Invalid analysis confidence');
      }
      result['confidence'] = rawConfidence.toDouble();
    }

    final rawChords = value['chords'];
    if (rawChords != null) {
      if (rawChords is! List || rawChords.length > maxChordCount) {
        throw const FormatException('Invalid analysis chord list');
      }
      final chords = <Map<String, dynamic>>[];
      var previousStartMs = -1;
      for (final rawChord in rawChords) {
        if (rawChord is! Map) throw const FormatException('Invalid analysis chord');
        final chord = Map<String, dynamic>.from(rawChord);
        final rawStartMs = chord['startMs'];
        if (rawStartMs is! num || !rawStartMs.isFinite || rawStartMs < 0 || rawStartMs > maxDurationMs) {
          throw const FormatException('Invalid analysis chord time');
        }
        final startMs = rawStartMs.toInt();
        if (startMs != rawStartMs || startMs < previousStartMs) {
          throw const FormatException('Analysis chords are out of order');
        }
        final rawName = chord['chord'];
        if (rawName is! String) throw const FormatException('Invalid analysis chord name');
        final name = rawName.trim();
        if (name.isEmpty || name.length > 32 || name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
          throw const FormatException('Invalid analysis chord name');
        }
        final entry = <String, dynamic>{'startMs': startMs, 'chord': name};
        final confidence = chord['confidence'];
        if (confidence != null) {
          if (confidence is! num || !confidence.isFinite || confidence < 0 || confidence > 1) {
            throw const FormatException('Invalid chord confidence');
          }
          entry['confidence'] = confidence.toDouble();
        }
        chords.add(entry);
        previousStartMs = startMs;
      }
      result['chords'] = chords;
    }
    return result;
  }

  static Map<String, dynamic> normalizeCorrections(Map<String, dynamic> value) {
    if (value.keys.any((key) => !{'key', 'bpm', 'chords'}.contains(key))) {
      throw const FormatException('Unsupported analysis correction');
    }
    return normalize(value);
  }

  static Map<String, dynamic> withCorrections(Map<String, dynamic> estimates, Map<String, dynamic> corrections) {
    final result = Map<String, dynamic>.from(estimates);
    for (final key in corrections.keys) {
      result[key] = corrections[key];
    }
    return result;
  }

  static Map<String, dynamic> correctionsFromFields({
    required String key,
    required String bpm,
    required String chords,
  }) {
    final result = <String, dynamic>{};
    if (key.trim().isNotEmpty) result['key'] = key.trim();
    if (bpm.trim().isNotEmpty) {
      final parsed = double.tryParse(bpm.trim());
      if (parsed == null || !parsed.isFinite || parsed < 20 || parsed > 400) {
        throw const FormatException('Enter a tempo between 20 and 400 BPM');
      }
      result['bpm'] = parsed;
    }
    result['chords'] = parseChordLines(chords);
    return normalizeCorrections(result);
  }

  static List<Map<String, dynamic>> parseChordLines(String value) {
    if (value.length > 2 * 1024 * 1024) throw const FormatException('Chord corrections are too large');
    final chords = <Map<String, dynamic>>[];
    for (final line in value.split('\n')) {
      final text = line.trim();
      if (text.isEmpty) continue;
      final match = RegExp(r'^(\d{1,9})\s+(.{1,32})$').firstMatch(text);
      if (match == null) {
        throw const FormatException('Use one chord per line: milliseconds, then chord');
      }
      final startMs = int.tryParse(match.group(1)!);
      if (startMs == null) throw const FormatException('Invalid chord time');
      chords.add({'startMs': startMs, 'chord': match.group(2)!.trim()});
      if (chords.length > maxChordCount) throw const FormatException('Too many chord corrections');
    }
    return (normalize({'chords': chords})['chords'] as List).cast<Map<String, dynamic>>();
  }

  static String chordLines(Map<String, dynamic>? analysis) => ((analysis?['chords'] as List?) ?? const [])
      .whereType<Map>()
      .map((chord) => '${chord['startMs']} ${chord['chord']}')
      .join('\n');
}
