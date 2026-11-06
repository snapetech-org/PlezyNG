import 'dart:convert';

import '../services/subtitle_retimer.dart';
import 'podcast_metadata.dart';
import 'source_models.dart';

final class PodcastTranscript {
  const PodcastTranscript({required this.text, this.cues = const []});
  static const maximumBytes = 2 * 1024 * 1024;
  static const supportedTypes = {
    'text/plain',
    'text/html',
    'text/vtt',
    'application/srt',
    'application/x-subrip',
    'application/json',
  };
  final String text;
  final List<SubtitleCue> cues;

  factory PodcastTranscript.parse(String body, String type) {
    if (!supportedTypes.contains(type) || body.length > maximumBytes || utf8.encode(body).length > maximumBytes) {
      throw const SourceException(SourceFailure.invalidData);
    }
    var cues = <SubtitleCue>[];
    if (type == 'text/vtt' || type == 'application/srt' || type == 'application/x-subrip') {
      cues = SubtitleRetimer.parseCues(sourceBytes: utf8.encode(body), extension: type == 'text/vtt' ? '.vtt' : '.srt');
    } else if (type == 'application/json') {
      final value = sourceMap(jsonDecode(body));
      final segments = sourceList(value['segments']);
      if (segments.length > 20000) {
        throw const SourceException(SourceFailure.invalidData);
      }
      for (final segment in segments) {
        final data = sourceMap(segment), start = data['startTime'], end = data['endTime'];
        if (start is! num ||
            end is! num ||
            !start.isFinite ||
            !end.isFinite ||
            start < 0 ||
            end <= start ||
            end > 7 * 24 * 3600) {
          continue;
        }
        final text = podcastPlainText(data['body']?.toString() ?? '');
        final speaker = podcastPlainText(data['speaker']?.toString() ?? '');
        if (text.isEmpty) {
          continue;
        }
        cues.add(
          SubtitleCue(
            index: cues.length + 1,
            startMs: (start * 1000).round(),
            endMs: (end * 1000).round(),
            text: speaker.isEmpty ? text : '$speaker: $text',
          ),
        );
      }
      cues.sort((a, b) => a.startMs.compareTo(b.startMs));
    }
    cues = [
      for (final cue in cues)
        if (podcastPlainText(cue.text).isNotEmpty)
          SubtitleCue(index: cue.index, startMs: cue.startMs, endMs: cue.endMs, text: podcastPlainText(cue.text)),
    ];
    if (type == 'application/json' && cues.isEmpty) {
      throw const SourceException(SourceFailure.invalidData);
    }
    if (cues.length > 20000) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final plain = cues.isNotEmpty
        ? cues.map((cue) => cue.text).join('\n')
        : type == 'text/html'
        ? _htmlText(body)
        : body.replaceAll('\u0000', '');
    if (plain.length > 512 * 1024) {
      throw const SourceException(SourceFailure.invalidData);
    }
    return PodcastTranscript(text: plain, cues: List.unmodifiable(cues));
  }

  static String _htmlText(String value) => value
      .replaceAll(RegExp(r'<(?:script|style)\b[^>]*>[\s\S]*?</(?:script|style)\s*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</?(?:p|div|br|li|section|article)\b[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .trim();

  Map<String, dynamic> toJson() => {
    'text': text,
    'cues': [
      for (final cue in cues) {'start': cue.startMs, 'end': cue.endMs, 'text': cue.text},
    ],
  };

  factory PodcastTranscript.fromJson(Map<String, dynamic> value) {
    final text = value['text'];
    final raw = sourceList(value['cues']);
    if (text is! String || text.length > 512 * 1024 || raw.length > 20000) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final cues = <SubtitleCue>[];
    for (final item in raw) {
      final map = sourceMap(item), start = sourceInt(map['start']), end = sourceInt(map['end']);
      final body = map['text'];
      if (body is! String ||
          body.length > 8000 ||
          start == null ||
          end == null ||
          start < 0 ||
          end <= start ||
          end > 7 * 24 * 3600000) {
        throw const SourceException(SourceFailure.invalidData);
      }
      cues.add(SubtitleCue(index: cues.length + 1, startMs: start, endMs: end, text: body));
    }
    return PodcastTranscript(text: text, cues: List.unmodifiable(cues));
  }
}
