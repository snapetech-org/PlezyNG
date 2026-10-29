import 'subtitle_ruby_text.dart';

class SubtitleLanguageTag {
  const SubtitleLanguageTag(this.language, this.script, this.region);
  final String language;
  final String? script, region;
  String get tag => [language, if (script != null) script!, if (region != null) region!].join('-');

  /// Deliberately bounded language[-Script][-REGION] subset. This does not
  /// validate registrations in the IANA registry or infer a language from text.
  static SubtitleLanguageTag? parse(String input) {
    final match = RegExp(r'^([A-Za-z]{2,3})(?:-([A-Za-z]{4}))?(?:-([A-Za-z]{2}|[0-9]{3}))?$').firstMatch(input);
    if (match == null) return null;
    final script = match[2];
    return SubtitleLanguageTag(match[1]!.toLowerCase(), script == null ? null
        : '${script[0].toUpperCase()}${script.substring(1).toLowerCase()}', match[3]?.toUpperCase());
  }
}

class SubtitleLanguageRun {
  const SubtitleLanguageRun(this.text, this.language);
  final String text;
  final SubtitleLanguageTag? language;
}

/// Bounded, non-executable WebVTT language spans. Cue text remains the canonical
/// representation in revisions, so edits, undo and sync preserve annotations.
abstract final class SubtitleLanguageText {
  static final _tags = RegExp(r'<[^>]*>');
  static final _open = RegExp(r'^<lang(?:\.[A-Za-z0-9_-]+)*[ \t]+([^<>]+)>$', caseSensitive: false);
  static final _close = RegExp(r'^</lang>$', caseSensitive: false);

  static List<SubtitleLanguageRun>? parse(String text) {
    if (text.length > 4000 || !RegExp(r'<lang[. \t>]', caseSensitive: false).hasMatch(text)) return null;
    // Ruby annotation text is not spoken twice or substituted for base text.
    final source = SubtitleRubyText.baseText(text);
    final stack = <SubtitleLanguageTag>[], output = <SubtitleLanguageRun>[];
    var cursor = 0, count = 0, annotations = 0;
    void append(String raw) {
      final plain = SubtitleRubyText.plain(raw);
      if (plain.isNotEmpty) output.add(SubtitleLanguageRun(plain, stack.isEmpty ? null : stack.last));
    }
    for (final match in _tags.allMatches(source)) {
      if (++count > 256) return null;
      append(source.substring(cursor, match.start));
      final raw = match[0]!, opening = _open.firstMatch(raw);
      if (opening != null) {
        final language = SubtitleLanguageTag.parse(opening[1]!);
        if (language == null || stack.length >= 8 || ++annotations > 64) return null;
        stack.add(language);
      } else if (_close.hasMatch(raw)) {
        if (stack.isEmpty) return null;
        stack.removeLast();
      } else if (RegExp(r'^</?lang\b', caseSensitive: false).hasMatch(raw)) { return null; }
      cursor = match.end;
    }
    append(source.substring(cursor));
    if (stack.isNotEmpty || annotations == 0 || output.map((run) => run.text).join() != SubtitleRubyText.plain(text)) return null;
    return List.unmodifiable(output);
  }

  static String removeTagsForSrt(String text) {
    if (parse(text) == null) return text;
    return text.replaceAllMapped(_tags, (match) =>
        _open.hasMatch(match[0]!) || _close.hasMatch(match[0]!) ? '' : match[0]!);
  }

  static String webVtt(String text) {
    String escape(String value) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final runs = parse(text);
    if (runs == null) return escape(SubtitleRubyText.plain(text));
    return runs.map((run) => run.language == null ? escape(run.text)
        : '<lang ${run.language!.tag}>${escape(run.text)}</lang>').join();
  }

  static String annotate(String text, int start, int end, String tag) {
    final language = SubtitleLanguageTag.parse(tag.trim());
    if (language == null) throw const FormatException('Use a language code with optional script and region, such as en or zh-Hant-TW.');
    if (start < 0 || end <= start || end > text.length || text.length > 3900 ||
        RegExp(r'<[^>]*>|\{[^}]*\}|&(?:[A-Za-z]+|#\d+|#x[0-9a-fA-F]+);').hasMatch(text)) {
      throw const FormatException('Select plain cue text without existing markup. Edit existing language tags directly.');
    }
    bool splitsSurrogate(int index) => index > 0 && index < text.length &&
        text.codeUnitAt(index - 1) >= 0xd800 && text.codeUnitAt(index - 1) <= 0xdbff &&
        text.codeUnitAt(index) >= 0xdc00 && text.codeUnitAt(index) <= 0xdfff;
    if (splitsSurrogate(start) || splitsSurrogate(end)) throw const FormatException('Select complete characters.');
    String escape(String value) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final result = '${escape(text.substring(0, start))}<lang ${language.tag}>${escape(text.substring(start, end))}</lang>${escape(text.substring(end))}';
    if (result.length > 4000 || parse(result) == null) throw const FormatException('The language annotation exceeds the cue bound.');
    return result;
  }
}
