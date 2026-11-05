import 'dart:convert';

import 'package:xml/xml.dart';

import '../media/lyrics.dart';
import '../utils/json_utils.dart';
import '../utils/lrc_parser.dart';

/// Parse the response from Plex's `/library/streams/{id}?format=xml` lyrics
/// endpoint.
///
/// Plex normally serializes its `MediaContainer > Lyrics > Line > Span`
/// document as JSON when the client sends `Accept: application/json`. Raw XML
/// is accepted for older servers/proxies, and raw LRC/TXT remains a fallback
/// for implementations that expose the sidecar file directly.
Lyrics? parsePlexLyricsResponse(Object? raw) {
  if (raw is Map) return _parseJsonLyrics(raw);
  if (raw is! String) return null;

  final trimmed = raw.trimLeft();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('<')) {
    try {
      return _parseXmlLyrics(trimmed);
    } on XmlException {
      return null;
    }
  }
  if (trimmed.startsWith('{')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return _parseJsonLyrics(decoded);
    } on FormatException {
      return null;
    }
  }
  return parseLrc(raw);
}

Lyrics? _parseJsonLyrics(Map response) {
  final container = response['MediaContainer'];
  if (container is! Map) return null;

  for (final rawLyrics in flexibleList(container['Lyrics']) ?? const <dynamic>[]) {
    if (rawLyrics is! Map) continue;
    final parsed = <LyricLine>[];
    for (final rawLine in flexibleList(rawLyrics['Line']) ?? const <dynamic>[]) {
      if (rawLine is String) {
        final text = rawLine.trim();
        if (text.isNotEmpty) parsed.add(LyricLine(text: text));
        continue;
      }
      if (rawLine is! Map) continue;

      final spans = flexibleList(rawLine['Span']) ?? const <dynamic>[];
      final text = spans.isEmpty
          ? (rawLine['text'] ?? rawLine['Text'])?.toString().trim() ?? ''
          : spans
                .map((span) => span is Map ? (span['text'] ?? span['Text'])?.toString() ?? '' : span.toString())
                .join()
                .trim();
      if (text.isEmpty) continue;

      Map? firstSpan;
      for (final span in spans) {
        if (span is Map) {
          firstSpan = span;
          break;
        }
      }
      final timedSpans = <LyricSpan>[];
      for (var i = 0; i < spans.length; i++) {
        final span = spans[i];
        if (span is! Map) continue;
        final start = flexibleInt(span['startOffset']);
        if (start == null || start < 0) continue;
        final next = i + 1 < spans.length ? spans[i + 1] : null;
        final end = flexibleInt(span['endOffset']) ?? (next is Map ? flexibleInt(next['startOffset']) : null);
        timedSpans.add(LyricSpan(text: (span['text'] ?? span['Text'])?.toString() ?? '', startMs: start,
          endMs: end != null && end > start ? end : null));
      }
      parsed.add(LyricLine(text: text, startMs: flexibleInt(rawLine['startOffset']) ?? flexibleInt(firstSpan?['startOffset']),
        endMs: flexibleInt(rawLine['endOffset']), spans: List.unmodifiable(timedSpans)));
    }
    final lyrics = _buildLyrics(parsed, timed: flexibleBoolNullable(rawLyrics['timed']));
    if (lyrics != null) return lyrics;
  }
  return null;
}

Lyrics? _parseXmlLyrics(String raw) {
  final document = XmlDocument.parse(raw);
  for (final lyricsElement in document.findAllElements('Lyrics')) {
    final parsed = <LyricLine>[];
    for (final lineElement in lyricsElement.findElements('Line')) {
      final spans = lineElement.findElements('Span').toList(growable: false);
      final text = spans.isEmpty
          ? (lineElement.getAttribute('text') ?? lineElement.innerText).trim()
          : spans.map((span) => span.getAttribute('text') ?? span.innerText).join().trim();
      if (text.isEmpty) continue;

      final timedSpans = <LyricSpan>[];
      for (var i = 0; i < spans.length; i++) {
        final span = spans[i];
        final start = flexibleInt(span.getAttribute('startOffset'));
        if (start == null || start < 0) continue;
        final end = flexibleInt(span.getAttribute('endOffset')) ??
          (i + 1 < spans.length ? flexibleInt(spans[i + 1].getAttribute('startOffset')) : null);
        timedSpans.add(LyricSpan(text: span.getAttribute('text') ?? span.innerText, startMs: start,
          endMs: end != null && end > start ? end : null));
      }
      parsed.add(LyricLine(
        text: text,
        startMs:
            flexibleInt(lineElement.getAttribute('startOffset')) ??
            (spans.isEmpty ? null : flexibleInt(spans.first.getAttribute('startOffset'))),
        endMs: flexibleInt(lineElement.getAttribute('endOffset')), spans: List.unmodifiable(timedSpans),
      ));
    }
    final lyrics = _buildLyrics(parsed, timed: flexibleBoolNullable(lyricsElement.getAttribute('timed')));
    if (lyrics != null) return lyrics;
  }
  return null;
}

Lyrics? _buildLyrics(List<LyricLine> parsed, {required bool? timed}) {
  if (parsed.isEmpty) return null;
  final synced = timed != false && parsed.any((line) => line.startMs != null);
  return Lyrics(
    synced: synced,
    lines: [for (final line in parsed) synced ? line : LyricLine(text: line.text)],
  );
}
