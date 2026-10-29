import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'subtitle_retimer.dart';
import 'subtitle_text_codec.dart';
import 'subtitle_scc_decoder.dart';

final class SubtitleTextImport {
  const SubtitleTextImport(this.cues, this.warnings, this.encoding);
  final List<SubtitleCue> cues;
  final List<String> warnings;
  final String encoding;
}

/// Editable text conversion, deliberately separate from native rendering.
/// Layout/style flattening is explicit; unsupported timing is refused instead
/// of silently approximated. Originals are never rewritten.
abstract final class SubtitleTextImporter {
  static const extensions = ['srt', 'vtt', 'ass', 'ssa', 'ttml', 'dfxp', 'imsc', 'xml', 'smi', 'sami', 'sub', 'sbv', 'lrc', 'mpl', 'scc'];
  static const nativeTextExtensions = {'.srt', '.vtt', '.ass', '.ssa'};

  static Future<SubtitleTextImport> parseAsync(List<int> bytes, String extension, {
    String encoding = 'unicode', double? framesPerSecond, int finalCueDurationMs = 2000, String? samiClass,
    int sccChannel = 1, bool sccNtsc = true, int sccClockOriginMs = 0,
  }) => compute(_parseRequest, (bytes, extension, encoding, framesPerSecond, finalCueDurationMs, samiClass, sccChannel, sccNtsc, sccClockOriginMs));

  static SubtitleTextImport _parseRequest((List<int>, String, String, double?, int, String?, int, bool, int) request) => parse(
    request.$1, request.$2, encoding: request.$3, framesPerSecond: request.$4,
    finalCueDurationMs: request.$5, samiClass: request.$6,
    sccChannel: request.$7, sccNtsc: request.$8, sccClockOriginMs: request.$9,
  );

  static SubtitleTextImport parse(List<int> bytes, String extension, {
    String encoding = 'unicode', double? framesPerSecond, int finalCueDurationMs = 2000, String? samiClass,
    int sccChannel = 1, bool sccNtsc = true, int sccClockOriginMs = 0,
  }) {
    final text = SubtitleTextCodec.decode(bytes, encoding: encoding);
    if (text.contains('\u0000') || utf8.encode(text).length > SubtitleRetimer.maximumInputBytes) {
      throw const FormatException('Decoded subtitle is binary or exceeds the 5 MiB text bound.');
    }
    if (finalCueDurationMs < 100 || finalCueDurationMs > 30000) {
      throw const FormatException('The final cue duration must be between 100 and 30000 ms.');
    }
    final format = extension.toLowerCase();
    final warnings = <String>[
      if (encoding != 'unicode') 'Explicit ${SubtitleTextCodec.encodings[encoding]} decoding; derived output is UTF-8. Review names and punctuation.',
    ];
    final cues = <SubtitleCue>[];
    void add(int start, int end, String payload) {
      final value = payload.trim();
      if (value.isEmpty) return;
      if (start < 0 || end <= start || end > SubtitleRetimer.maximumTimeMs || value.length > 4000) {
        throw const FormatException('Subtitle has invalid times or a cue over 4000 characters.');
      }
      if (cues.length >= SubtitleRetimer.maximumCueCount) throw const FormatException('Subtitle exceeds 50000 cues.');
      cues.add(SubtitleCue(index: cues.length + 1, startMs: start, endMs: end, text: value));
    }
    if (nativeTextExtensions.contains(format)) {
      cues.addAll(SubtitleRetimer.parseCues(sourceBytes: utf8.encode(text), extension: format));
      if (format == '.ass' || format == '.ssa') warnings.add('Editing/translation creates an SRT derivative. Native ASS styling, fonts and animation are not preserved by SRT.');
    } else if (const {'.ttml', '.dfxp', '.imsc', '.xml'}.contains(format)) {
      _ttml(text, add);
      warnings.add('TTML/IMSC text and timed spans are flattened to SRT. Regions, fonts, ruby, styling and writing modes stay only in the original; image profiles and non-media clocks are refused.');
    } else if (format == '.scc') {
      SubtitleSccDecoder.decode(text, add, warnings, channel: sccChannel, ntsc: sccNtsc,
        clockOriginMs: sccClockOriginMs, finalDurationMs: finalCueDurationMs);
    } else if (format == '.sub') {
      _microDvd(text, framesPerSecond, add, warnings);
    } else if (format == '.smi' || format == '.sami') {
      _sami(text, samiClass, finalCueDurationMs, add, warnings);
    } else if (format == '.sbv') {
      final blocks = text.replaceAll('\r\n', '\n').split(RegExp(r'\n[ \t]*\n'));
      for (final block in blocks) {
        final lines = block.trim().split('\n');
        if (lines.first.isEmpty) continue;
        final timing = lines.first.split(',');
        if (timing.length != 2 || lines.length < 2) throw const FormatException('Invalid SubViewer/SBV cue.');
        add(_clock(timing[0]), _clock(timing[1]), lines.skip(1).join('\n'));
      }
    } else if (format == '.lrc') {
      _lrc(text, finalCueDurationMs, add, warnings);
    } else if (format == '.mpl') {
      for (final line in text.split(RegExp(r'\r?\n'))) {
        if (line.trim().isEmpty) continue;
        final match = RegExp(r'^\[(\d+)\]\[(\d+)\](.*)$').firstMatch(line);
        if (match == null) throw const FormatException('Invalid MPL2 subtitle line.');
        add(int.parse(match[1]!) * 100, int.parse(match[2]!) * 100,
          match[3]!.split('|').map((part) => part.startsWith('/') ? '<i>${part.substring(1)}</i>' : part).join('\n'));
      }
    } else {
      throw const FormatException('This text subtitle format is not supported by the editor.');
    }
    if (cues.isEmpty) throw const FormatException('No non-empty text subtitle cues were found.');
    var outputBytes = 0;
    for (final cue in cues) {
      outputBytes += utf8.encode(cue.text).length;
      if (cue.text.length > 4000 || outputBytes > SubtitleRetimer.maximumInputBytes) {
        throw const FormatException('Converted subtitle exceeds the 5 MiB text / 4000-character cue bound.');
      }
    }
    cues.sort((a, b) { final order = a.startMs.compareTo(b.startMs); return order == 0 ? a.index.compareTo(b.index) : order; });
    return SubtitleTextImport(List.unmodifiable(cues), List.unmodifiable(warnings), encoding);
  }

  static int _clock(String input) {
    final match = RegExp(r'^(\d{1,6}):([0-5]\d):([0-5]\d)(?:[.,](\d{1,6}))?$').firstMatch(input.trim());
    if (match == null) throw const FormatException('Invalid clock timestamp.');
    return ((int.parse(match[1]!) * 3600 + int.parse(match[2]!) * 60 + int.parse(match[3]!)) * 1000 +
      (match[4] == null ? 0 : (double.parse('0.${match[4]}') * 1000).round()));
  }

  static void _microDvd(String text, double? fps, void Function(int, int, String) add, List<String> warnings) {
    var first = true;
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      if (line.length > 16000) throw const FormatException('MicroDVD source line exceeds the text bound.');
      final match = RegExp(r'^\{(\d+)\}\{(\d+)\}(.*)$').firstMatch(line);
      if (match == null) throw const FormatException('This is not a MicroDVD text SUB file. VobSub bitmap SUB needs OCR.');
      final start = int.parse(match[1]!), end = int.parse(match[2]!);
      final declared = double.tryParse(match[3]!.trim());
      if (first && start == end && (start == 0 || start == 1) && declared != null) {
        fps ??= declared;
        first = false;
        continue;
      }
      first = false;
      if (fps == null || !fps.isFinite || fps < 1 || fps > 240) {
        throw const FormatException('MicroDVD needs an explicit source frame rate (1–240 fps) or its declared FPS header.');
      }
      final input = match[3]!, plain = StringBuffer();
      var cursor = 0;
      while (cursor < input.length) {
        final startTag = input.indexOf('{', cursor);
        if (startTag < 0) break;
        final endTag = input.indexOf('}', startTag + 1);
        if (endTag < 0) break;
        plain.write(input.substring(cursor, startTag));
        cursor = endTag + 1;
      }
      plain.write(input.substring(cursor));
      final payload = plain.toString().replaceAll('|', '\n');
      add((start * 1000 / fps).round(), (end * 1000 / fps).round(), payload);
    }
    warnings.add('MicroDVD uses ${fps?.toStringAsFixed(6)} fps, explicitly selected or declared by the file. Inline MicroDVD style codes are removed; media FPS is not inferred.');
  }

  static String _htmlText(String text) {
    final plain = StringBuffer();
    var cursor = 0;
    String? hidden;
    for (final tag in _htmlTags(text)) {
      if (hidden == null) plain.write(text.substring(cursor, tag.start));
      final kind = tag.text.substring(1).trimLeft().toLowerCase().split(RegExp(r'[\s/>]')).first;
      if (hidden != null) {
        if (tag.text.toLowerCase().startsWith('</$hidden')) hidden = null;
      } else if (kind == 'script' || kind == 'style') { hidden = kind; }
      else if (kind == 'br') { plain.write('\n'); }
      cursor = tag.end;
    }
    if (hidden == null) plain.write(text.substring(cursor));
    text = plain.toString();
    return text.replaceAllMapped(RegExp(r'&(#x[0-9a-f]+|#\d+|nbsp|amp|lt|gt|quot|apos);', caseSensitive: false), (m) {
      final token = m[1]!;
      if (!token.startsWith('#')) return const {'nbsp': ' ', 'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"}[token.toLowerCase()]!;
      final scalar = token.toLowerCase().startsWith('#x') ? int.tryParse(token.substring(2), radix: 16) : int.tryParse(token.substring(1));
      if (scalar == null || scalar <= 0 || scalar > 0x10ffff || scalar >= 0xd800 && scalar <= 0xdfff) throw const FormatException('Invalid HTML character entity.');
      return String.fromCharCode(scalar);
    });
  }

  /// Deterministic tag scanning avoids repeated regex searches over malformed,
  /// unterminated HTML. Comments are skipped without allocating their payload.
  static List<({int start, int end, String text})> _htmlTags(String text) {
    final tags = <({int start, int end, String text})>[];
    var cursor = 0;
    while (cursor < text.length) {
      final start = text.indexOf('<', cursor);
      if (start < 0) break;
      if (text.startsWith('<!--', start)) {
        final end = text.indexOf('-->', start + 4);
        if (end < 0) throw const FormatException('SAMI contains an unterminated comment.');
        tags.add((start: start, end: end + 3, text: '<!comment>'));
        cursor = end + 3;
      } else {
        final end = text.indexOf('>', start + 1), nested = text.indexOf('<', start + 1);
        if (end < 0 || end - start > 4096 || nested >= 0 && nested < end) throw const FormatException('SAMI has a malformed or oversized HTML tag.');
        tags.add((start: start, end: end + 1, text: text.substring(start, end + 1)));
        cursor = end + 1;
      }
      if (tags.length > 200000) throw const FormatException('SAMI exceeds the HTML token bound.');
    }
    return tags;
  }

  static String? _attribute(String tag, String name) {
    final pattern = RegExp('(?:^|\\s)${RegExp.escape(name)}\\s*=\\s*(?:"([^\"]*)"|\x27([^\x27]*)\x27|([^\\s>]+))', caseSensitive: false);
    final match = pattern.firstMatch(tag);
    return match == null ? null : match[1] ?? match[2] ?? match[3];
  }

  static void _sami(String text, String? selectedClass, int tail, void Function(int, int, String) add, List<String> warnings) {
    final tags = _htmlTags(text);
    if (tags.any((tag) => RegExp(r'^<script\b', caseSensitive: false).hasMatch(tag.text))) {
      throw const FormatException('Active/scripted SAMI content is not supported for text conversion.');
    }
    final syncTag = RegExp(r'^<sync\b', caseSensitive: false), paragraphTag = RegExp(r'^<p\b', caseSensitive: false);
    final matches = tags.where((tag) => syncTag.hasMatch(tag.text)).toList();
    if (matches.isEmpty || matches.length > 100000) throw const FormatException('SAMI has no sync markers or exceeds the marker bound.');
    final classes = tags.where((tag) => paragraphTag.hasMatch(tag.text))
      .map((tag) => _attribute(tag.text, 'class')).whereType<String>().toSet();
    if (classes.length > 128 || classes.any((name) => name.length > 128)) throw const FormatException('SAMI language classes exceed the preview bound.');
    final chosen = selectedClass?.trim().isNotEmpty == true ? selectedClass!.trim() : classes.firstOrNull;
    if (chosen != null && !classes.any((value) => value.toLowerCase() == chosen.toLowerCase())) {
      throw FormatException('Unknown SAMI class. Available: ${classes.take(20).join(', ')}');
    }
    for (var i = 0; i < matches.length; i++) {
      int startOf(int n) => int.tryParse(_attribute(matches[n].text, 'start') ?? '') ?? (throw const FormatException('Invalid SAMI sync start.'));
      final start = startOf(i), end = i + 1 < matches.length ? startOf(i + 1) : startOf(i) + tail;
      if (end <= start) throw const FormatException('SAMI sync starts must increase.');
      final block = text.substring(matches[i].end, i + 1 < matches.length ? matches[i + 1].start : text.length);
      final paragraphs = _htmlTags(block).where((tag) => paragraphTag.hasMatch(tag.text)).toList();
      final parts = <String>[];
      for (var n = 0; n < paragraphs.length; n++) {
        if (chosen != null && (_attribute(paragraphs[n].text, 'class') ?? '').toLowerCase() != chosen.toLowerCase()) continue;
        parts.add(_htmlText(block.substring(paragraphs[n].end, n + 1 < paragraphs.length ? paragraphs[n + 1].start : block.length)));
      }
      if (paragraphs.isEmpty && chosen == null) parts.add(_htmlText(block));
      add(start, end, parts.join('\n'));
    }
    warnings.add('SAMI class: ${chosen ?? 'unclassified'}. Available: ${classes.take(20).join(', ')}. HTML layout is flattened. A final non-empty sync without a following clear uses the selected $tail ms duration.');
  }

  static void _lrc(String text, int tail, void Function(int, int, String) add, List<String> warnings) {
    final timed = <(int, String)>[];
    final offsetMatch = RegExp(r'\[offset:([+-]?\d+)\]', caseSensitive: false).firstMatch(text);
    final offset = offsetMatch == null ? 0 : int.parse(offsetMatch[1]!);
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (line.length > 16000) throw const FormatException('LRC source line exceeds the text bound.');
      final tags = RegExp(r'\[(\d{1,6}):([0-5]\d)(?:[.:](\d{1,3}))?\]').allMatches(line).toList();
      if (tags.isEmpty) continue;
      final payload = line.substring(tags.last.end).replaceAll(RegExp(r'<\d+:[0-5]\d[.:]\d+>'), '');
      for (final tag in tags) {
        final time = (int.parse(tag[1]!) * 60 + int.parse(tag[2]!)) * 1000 +
          (tag[3] == null ? 0 : (double.parse('0.${tag[3]}') * 1000).round()) - offset;
        if (time < 0) throw const FormatException('LRC offset moves a cue before zero; correct its offset explicitly.');
        timed.add((time, payload));
        if (timed.length > 100000) throw const FormatException('LRC exceeds the timestamp bound.');
      }
    }
    timed.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 0; i < timed.length;) {
      var next = i + 1;
      while (next < timed.length && timed[next].$1 == timed[i].$1) next++;
      for (var n = i; n < next; n++) {
        add(timed[n].$1, next < timed.length ? timed[next].$1 : timed[n].$1 + tail, timed[n].$2);
      }
      i = next;
    }
    warnings.add('LRC uses the next timestamp as each line’s end and the selected $tail ms final duration. Enhanced word markers are flattened; these are lyric lines, not verified speech word timings.');
  }

  static void _ttml(String text, void Function(int, int, String) add) {
    if (RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(text)) throw const FormatException('TTML DTDs and entity declarations are not accepted.');
    var depth = 0, count = 0;
    for (final event in parseEvents(text, validateNesting: true, validateDocument: true)) {
      if (++count > 200000) throw const FormatException('TTML exceeds 200000 XML events.');
      if (event is XmlStartElementEvent && !event.isSelfClosing && ++depth > 64) throw const FormatException('TTML nesting exceeds 64 elements.');
      if (event is XmlEndElementEvent) depth--;
    }
    final root = XmlDocument.parse(text).rootElement;
    String? attr(XmlElement node, String name) => node.attributes.where((a) => a.name.local == name).firstOrNull?.value;
    if (root.name.local != 'tt' || (attr(root, 'timeBase') ?? 'media') != 'media') throw const FormatException('Only TTML text with a media time base can be converted.');
    final nominalFps = double.tryParse(attr(root, 'frameRate') ?? '30') ?? 0;
    final subframes = double.tryParse(attr(root, 'subFrameRate') ?? '1') ?? 0;
    final multiplier = (attr(root, 'frameRateMultiplier') ?? '1 1').trim().split(RegExp(r'\s+')).map(double.tryParse).toList();
    if (!nominalFps.isFinite || nominalFps <= 0 || nominalFps > 240 || !subframes.isFinite || subframes <= 0 || subframes > 1000 || multiplier.length != 2 || multiplier.any((n) => n == null || !n.isFinite || n <= 0)) throw const FormatException('Invalid TTML clock parameters.');
    final fps = nominalFps * multiplier[0]! / multiplier[1]!;
    final tick = double.tryParse(attr(root, 'tickRate') ?? '${attr(root, 'frameRate') == null ? 1 : fps * subframes}') ?? 0;
    if (!fps.isFinite || fps <= 0 || fps > 240 || !tick.isFinite || tick <= 0) throw const FormatException('Invalid TTML frame/tick rate.');
    int time(String value) {
      final offset = RegExp(r'^(\d+(?:\.\d+)?)(ms|h|m|s|f|t)$').firstMatch(value);
      if (offset != null) {
        final factor = switch (offset[2]) { 'h' => 3600000.0, 'm' => 60000.0, 's' => 1000.0, 'ms' => 1.0, 'f' => 1000 / fps, _ => 1000 / tick };
        final ms = double.parse(offset[1]!) * factor;
        if (!ms.isFinite || ms > SubtitleRetimer.maximumTimeMs) throw const FormatException('TTML time exceeds the processing bound.');
        return ms.round();
      }
      final frames = RegExp(r'^(\d{1,6}):([0-5]\d):([0-5]\d):(\d+)(?:\.(\d+))?$').firstMatch(value);
      if (frames == null) return _clock(value);
      final frame = int.parse(frames[4]!), subframe = int.parse(frames[5] ?? '0');
      if (frame >= nominalFps || subframe >= subframes) throw const FormatException('Invalid TTML frame/subframe clock.');
      return _clock('${frames[1]}:${frames[2]}:${frames[3]}') + ((frame + subframe / subframes) * 1000 / fps).round();
    }
    const forever = SubtitleRetimer.maximumTimeMs + 1;
    (int, int) interval(XmlElement node, int parentStart, int parentEnd) {
      final start = parentStart + (attr(node, 'begin') == null ? 0 : time(attr(node, 'begin')!));
      var end = attr(node, 'end') == null ? parentEnd : math.min(parentEnd, parentStart + time(attr(node, 'end')!));
      if (attr(node, 'dur') != null) end = math.min(end, start + time(attr(node, 'dur')!));
      return (start, end);
    }
    void validate(XmlElement node) {
      if ((attr(node, 'timeContainer') ?? 'par') != 'par') throw const FormatException('Sequential TTML timing needs native rendering; conversion accepts parallel containers only.');
      if (const {'image', 'audio', 'animation', 'animate', 'set'}.contains(node.name.local) ||
          node.attributes.any((a) => a.name.local == 'backgroundImage')) throw const FormatException('TTML image/media/animation content cannot be flattened safely.');
    }
    for (final node in root.descendants.whereType<XmlElement>()) { validate(node); }
    validate(root);
    var conversionWork = 0;
    void paragraph(XmlElement node, int start, int end, bool preserve) {
      final leaves = <(int, int, String)>[];
      void collect(XmlNode child, int begin, int finish, bool keepSpace) {
        if (leaves.length > 4000) throw const FormatException('TTML paragraph has too many text spans.');
        if (child is XmlText || child is XmlCDATA) {
          final value = child is XmlText ? child.value : (child as XmlCDATA).value;
          leaves.add((begin, finish, keepSpace ? value : value.replaceAll(RegExp(r'[\t\r\n ]+'), ' ')));
        } else if (child is XmlElement) {
          if (child.name.local == 'metadata') return;
          final span = interval(child, begin, finish);
          if (span.$2 <= span.$1) return;
          final keep = attr(child, 'space') == null ? keepSpace : attr(child, 'space') == 'preserve';
          if (child.name.local == 'br') { leaves.add((span.$1, span.$2, '\n')); return; }
          for (final part in child.children) { collect(part, span.$1, span.$2, keep); }
        }
      }
      for (final child in node.children) { collect(child, start, end, preserve); }
      if (leaves.isEmpty) return;
      if (leaves.any((leaf) => leaf.$2 == forever && leaf.$3.trim().isNotEmpty)) throw const FormatException('TTML text has no finite end/duration.');
      final changes = {for (final leaf in leaves) ...[leaf.$1, leaf.$2]}.toList()..sort();
      conversionWork += changes.length * leaves.length;
      if (changes.length * leaves.length > 200000 || conversionWork > 4000000) throw const FormatException('TTML timed text exceeds the conversion work bound.');
      for (var i = 0; i + 1 < changes.length; i++) {
        final value = leaves.where((leaf) => leaf.$1 <= changes[i] && leaf.$2 > changes[i]).map((leaf) => leaf.$3).join();
        add(changes[i], changes[i + 1], value);
      }
    }
    void walk(XmlElement node, int parentStart, int parentEnd, bool preserve) {
      if (const {'head', 'metadata'}.contains(node.name.local)) return;
      final span = interval(node, parentStart, parentEnd);
      if (span.$2 <= span.$1) return;
      final keep = attr(node, 'space') == null ? preserve : attr(node, 'space') == 'preserve';
      if (node.name.local == 'p') { paragraph(node, span.$1, span.$2, keep); return; }
      for (final child in node.childElements) { walk(child, span.$1, span.$2, keep); }
    }
    walk(root, 0, forever, false);
  }
}
