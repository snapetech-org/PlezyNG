import 'dart:convert';
import 'dart:math' as math;

import 'subtitle_retimer.dart';

final class SubtitleEditOptions {
  const SubtitleEditOptions({
    this.reflow = false, this.charactersPerLine = 42, this.maximumLines = 2,
    this.charactersPerSecond = 20, this.normalizeSpacing = false,
    this.removeDescriptions = false, this.removeSongs = false, this.removeCredits = false,
    this.replacements = const {}, this.fpsFrom, this.fpsTo,
  });
  final bool reflow;
  final int charactersPerLine;
  final int maximumLines;
  final int charactersPerSecond;
  final bool normalizeSpacing;
  final bool removeDescriptions;
  final bool removeSongs;
  final bool removeCredits;
  /// Explicit user corrections. No inferred spelling changes or profanity filter.
  final Map<String, String> replacements;
  final double? fpsFrom;
  final double? fpsTo;
}

final class SubtitleEditResult {
  const SubtitleEditResult({required this.cues, required this.changed, required this.removed, required this.warnings});
  final List<SubtitleCue> cues;
  final int changed;
  final int removed;
  final List<String> warnings;
}

/// Deterministic opt-in transformations. Authored drawing/animation tags remain
/// intact; operations that need plain text leave those cues unchanged.
abstract final class SubtitleEditingService {
  static final _markup = RegExp(r'<[^>]{0,160}>|\{[^}]{0,160}\}');
  static final _descriptions = RegExp(r'\[[^\]\r\n]{1,200}\]|\([^()\r\n]{1,200}\)');
  static final _credit = RegExp(
    r'^(?:subtitles?\s+(?:by|provided by)|translated\s+by|synced\s+(?:and\s+corrected\s+)?by|www\.[^\s]+|https?://[^\s]+)\b',
    caseSensitive: false,
  );

  static SubtitleEditResult transform(List<SubtitleCue> source, SubtitleEditOptions options) {
    if (source.isEmpty || source.length > SubtitleRetimer.maximumCueCount ||
        source.fold<int>(0, (n, c) => n + utf8.encode(c.text).length) > SubtitleRetimer.maximumInputBytes) {
      throw const FormatException('The subtitle exceeds the editing bounds.');
    }
    if (options.charactersPerLine < 12 || options.charactersPerLine > 100 ||
        options.maximumLines < 1 || options.maximumLines > 4 || options.charactersPerSecond < 5 ||
        options.charactersPerSecond > 60 || options.replacements.length > 256 ||
        options.replacements.entries.any((e) => e.key.isEmpty || e.key.length > 100 || e.value.length > 200)) {
      throw const FormatException('Invalid reading limits or correction dictionary.');
    }
    final from = options.fpsFrom, to = options.fpsTo;
    if ((from == null) != (to == null) || (from != null &&
        (!from.isFinite || !to!.isFinite || from < 1 || from > 240 || to < 1 || to > 240))) {
      throw const FormatException('Both frame rates must be between 1 and 240.');
    }
    final rate = from == null ? 1.0 : from / to!;
    final output = <SubtitleCue>[];
    final warnings = <String>[];
    var changed = 0, removed = 0, outputBytes = 0;
    void warn(String text) { if (warnings.length < 100) warnings.add(text); }
    for (final cue in source) {
      var text = cue.text;
      final authored = text.contains(RegExp(r'\{[^}]*\\(?:p[1-9]|t\(|move\(|k[of]?\d)', caseSensitive: false));
      if (authored && rate != 1.0) {
        throw const FormatException('Timed ASS drawing/animation/karaoke cannot be safely FPS-converted to SRT. Export with its native renderer.');
      }
      if (authored && (options.reflow || options.removeDescriptions || options.removeSongs || options.removeCredits)) {
        warn('Cue ${cue.index}: authored drawing/karaoke/animation left unchanged.');
      } else {
        var lines = text.replaceAll(r'\N', '\n').split('\n');
        if (options.removeSongs) lines = lines.where((line) => !line.contains(RegExp('[♪♫]'))).toList();
        if (options.removeCredits) lines = lines.where((line) => !_credit.hasMatch(line.trim())).toList();
        if (options.removeDescriptions) {
          lines = lines.map((line) => line.replaceAll(_descriptions, '').trim()).where((line) => line.isNotEmpty).toList();
        }
        text = lines.join('\n');
        // Apply corrections only between tags, at whole word boundaries. Unicode
        // letters and combining marks are part of words, so accents are retained.
        text = _outsideMarkup(text, (plain) {
          var result = plain;
          for (final entry in options.replacements.entries) {
            final pattern = RegExp('(?<![\\p{L}\\p{N}\\p{M}_])${RegExp.escape(entry.key)}(?![\\p{L}\\p{N}\\p{M}_])', unicode: true);
            result = result.replaceAllMapped(pattern, (_) => entry.value);
            if (result.length > 4000) throw const FormatException('A correction expands a cue beyond 4000 characters.');
          }
          if (options.normalizeSpacing) {
            result = result.replaceAll(RegExp(r'[ \t]+'), ' ')
                .replaceAllMapped(RegExp(r' +([,.;:!?])'), (match) => match.group(1)!);
          }
          return result;
        });
        if (options.reflow) {
          // Preserve two-speaker lines and authored explicit-position cues.
          final speakerLines = text.split('\n').where((line) => RegExp(r'^\s*[-–—]\s*\S').hasMatch(line)).length;
          if (speakerLines > 1 || text.contains(RegExp(r'\{[^}]*\\(?:pos|an|a\d)'))) {
            warn('Cue ${cue.index}: speaker/position layout retained.');
          } else if (_markup.hasMatch(text)) {
            warn('Cue ${cue.index}: styled text retained to preserve tag scope.');
          } else {
            text = _wrap(text, options.charactersPerLine, options.maximumLines);
          }
        }
      }
      text = text.trim();
      if (text.isEmpty || _markup.allMatches(text).fold<int>(0, (n, m) => n + m.group(0)!.length) == text.length) {
        ++removed;
        continue;
      }
      final start = (cue.startMs * rate).round(), end = (cue.endMs * rate).round();
      if (start < 0 || end <= start || end > SubtitleRetimer.maximumTimeMs) {
        throw const FormatException('FPS conversion places a cue outside the supported timeline.');
      }
      if (text != cue.text || start != cue.startMs || end != cue.endMs) ++changed;
      final visible = text.replaceAll(_markup, '');
      final length = visible.runes.length;
      if (length * 1000 / (end - start) > options.charactersPerSecond) {
        warn('Cue ${cue.index}: ${(length * 1000 / (end - start)).round()} characters/second exceeds the selected reading limit.');
      }
      if (visible.split('\n').any((line) => line.runes.length > options.charactersPerLine)) {
        warn('Cue ${cue.index}: a line exceeds ${options.charactersPerLine} characters; shorten or split it manually.');
      }
      outputBytes += utf8.encode(text).length;
      if (text.length > 4000 || outputBytes > SubtitleRetimer.maximumInputBytes) {
        throw const FormatException('Edited subtitle exceeds the text bound.');
      }
      output.add(SubtitleCue(index: output.length + 1, startMs: start, endMs: end, text: text, cueId: cue.stableId));
    }
    if (output.isEmpty) throw const FormatException('The selected transformations would remove every cue.');
    if (options.removeDescriptions) warnings.insert(0, 'Description removal also removes bracketed/parenthesized dialogue. Review every affected cue.');
    if (from != null) warnings.insert(0, 'Explicit ${from.toStringAsFixed(3)} → ${to!.toStringAsFixed(3)} FPS conversion scales times by $rate. Video frame rate was not inferred.');
    return SubtitleEditResult(cues: List.unmodifiable(output), changed: changed, removed: removed, warnings: List.unmodifiable(warnings));
  }

  static String _outsideMarkup(String text, String Function(String) operation) {
    final out = StringBuffer();
    var cursor = 0;
    for (final match in _markup.allMatches(text)) {
      out.write(operation(text.substring(cursor, match.start)));
      out.write(match.group(0));
      cursor = match.end;
    }
    out.write(operation(text.substring(cursor)));
    return out.toString();
  }

  static String _wrap(String input, int width, int maxLines) {
    final words = input.trim().split(RegExp(r'\s+'));
    if (words.length < 2) return input.trim();
    final length = words.fold<int>(0, (n, w) => n + w.runes.length) + words.length - 1;
    final lines = math.min(maxLines, math.max(1, (length / width).ceil()));
    final target = (length / lines).ceil();
    final out = <String>[];
    var current = '';
    for (final word in words) {
      if (current.isNotEmpty && out.length < lines - 1 && current.runes.length + word.runes.length + 1 > target) {
        out.add(current);
        current = word;
      } else { current = current.isEmpty ? word : '$current $word'; }
    }
    if (current.isNotEmpty) out.add(current);
    return out.join('\n');
  }
}
