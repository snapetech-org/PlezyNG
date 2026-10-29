import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'subtitle_retimer.dart';
import 'subtitle_revision_service.dart';

class SubtitleBookPart {
  const SubtitleBookPart({required this.fileIndex, required this.title, required this.startMs,
    required this.durationMs, required this.identity});
  final int fileIndex, startMs, durationMs;
  final String title;
  final SubtitleRevisionIdentity identity;
}

class SubtitleBookCue {
  const SubtitleBookCue(this.part, this.revisionId, this.source, this.fileStartMs, this.fileEndMs);
  final SubtitleBookPart part;
  final String revisionId;
  final SubtitleCue source;
  final int fileStartMs, fileEndMs;
  int get startMs => part.startMs + fileStartMs;
  int get endMs => part.startMs + fileEndMs;
}

enum SubtitleBookIssue {
  changed,
  clockOutsidePart,
  invalidExport,
  exportTooLarge,
  combinedLimit,
}

class SubtitleBookException implements Exception {
  const SubtitleBookException(this.issue);
  final SubtitleBookIssue issue;
}

/// An immutable queue clock, owned and invalidated by SourcePlayback. It never
/// reinterprets a per-file revision as a book clock without an explicit choice.
class SubtitleBookTimeline {
  SubtitleBookTimeline({required this.title, required List<SubtitleBookPart> parts,
    required this.isCurrent, required this.positionMs, required this.seek, required this.changes}) : parts = List.unmodifiable(parts) {
    if (title.length > 1024 || parts.isEmpty || parts.length > 256 || parts.first.startMs != 0) throw const FormatException('Book part limit');
    var end = 0;
    final indices = <int>{};
    for (final part in parts) {
      if (part.fileIndex < 0 || part.title.length > 1024 || part.startMs != end || part.durationMs <= 0 || part.durationMs > 7 * 24 * 3600000 ||
          !indices.add(part.fileIndex)) throw const FormatException('Book timeline is incomplete');
      end += part.durationMs;
    }
    if (end > 7 * 24 * 3600000) throw const FormatException('Book timeline exceeds seven days');
  }
  final String title;
  final List<SubtitleBookPart> parts;
  final bool Function() isCurrent;
  final int Function() positionMs;
  final Future<void> Function(int fileIndex, int filePositionMs) seek;
  final Listenable changes;

  List<SubtitleBookCue> useRevision(SubtitleBookPart part, SubtitleRevision revision, {required bool bookClock}) {
    if (!isCurrent() || !parts.contains(part)) throw const SubtitleBookException(SubtitleBookIssue.changed);
    final shift = bookClock ? part.startMs : 0;
    final result = <SubtitleBookCue>[];
    for (final cue in revision.cues) {
      final start = cue.startMs - shift, end = cue.endMs - shift;
      if (start < 0 || end <= start || end > part.durationMs) {
        throw const SubtitleBookException(SubtitleBookIssue.clockOutsidePart);
      }
      result.add(SubtitleBookCue(part, revision.id, cue, start, end));
    }
    return List.unmodifiable(result);
  }

  Uint8List export(List<SubtitleBookCue> cues) {
    if (!isCurrent()) throw const SubtitleBookException(SubtitleBookIssue.changed);
    if (cues.isEmpty || cues.length > 50000) {
      throw const SubtitleBookException(SubtitleBookIssue.invalidExport);
    }
    if (cues.any((cue) => !parts.contains(cue.part) || cue.fileStartMs < 0 || cue.fileEndMs <= cue.fileStartMs ||
        cue.fileEndMs > cue.part.durationMs) ||
        cues.fold<int>(0, (sum, cue) => sum + utf8.encode(cue.source.text).length) > 5 * 1024 * 1024) {
      throw const SubtitleBookException(SubtitleBookIssue.invalidExport);
    }
    final output = {'schema': 'plezyng.book-transcript.v1', 'title': title,
      'clock': 'current-source-queue-milliseconds', 'complete': parts.every((part) => cues.any((cue) => identical(cue.part, part))),
      'parts': [for (final part in parts) {'fileIndex': part.fileIndex, 'title': part.title,
        'identityDigest': part.identity.storageKey, 'startMs': part.startMs, 'durationMs': part.durationMs}],
      'cues': [for (final cue in cues) {'fileIndex': cue.part.fileIndex, 'revisionId': cue.revisionId,
        'sourceCueId': cue.source.stableId, 'startMs': cue.startMs, 'endMs': cue.endMs,
        'fileStartMs': cue.fileStartMs, 'fileEndMs': cue.fileEndMs, 'text': cue.source.text}],
      'limitations': ['Explicitly selected saved revisions; completeness is not a speech-coverage assertion.',
        'Queue order, file durations and identities are snapshot-bound. This is not a native sidecar or an importable single-file revision.']};
    final bytes = utf8.encode(jsonEncode(output));
    if (bytes.length > 16 * 1024 * 1024) throw const SubtitleBookException(SubtitleBookIssue.exportTooLarge);
    return Uint8List.fromList(bytes);
  }
}
