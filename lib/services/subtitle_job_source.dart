import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'subtitle_analysis_source.dart';

/// A live capability, never serialized. Only its descriptor digest enters the
/// job store. Reopening a job requires a fresh lease and the same explicit audio
/// ordinal, selected-audio descriptor, file duration and source clock.
final class SubtitleJobSource {
  SubtitleJobSource._(this.source, this.durationMs, this.audioOrdinal,
      this.bindingKey, this._current);

  final SubtitleAnalysisSource source;
  final int durationMs;
  final int audioOrdinal;
  final String bindingKey;
  final bool Function() _current;
  bool _closed = false;

  int get timelineOffsetMs => source.timelineOffsetMs;
  bool get isCurrent {
    try { return !_closed && _current() && source.isCurrent(); }
    catch (_) { return false; }
  }

  static Future<SubtitleJobSource> open({
    required Future<SubtitleAnalysisSource> Function() openSource,
    required int audioOrdinal,
    required String audioDescriptor,
    required int fallbackDurationMs,
    required bool Function() isCurrent,
  }) async {
    final source = await openSource();
    try {
      final duration = source.durationMs ?? fallbackDurationMs - source.timelineOffsetMs;
      if (!isCurrent() || !source.isCurrent()) throw StateError('The source changed.');
      if (source.liveEpochForPosition != null || duration <= 0 || duration > 8 * 3600000 ||
          source.timelineOffsetMs < 0 || source.timelineOffsetMs + duration > 24 * 3600000 ||
          audioOrdinal < 0 || audioOrdinal > 63 || audioDescriptor.isEmpty || audioDescriptor.length > 4096 ||
          source.identity.isEmpty || source.identity.length > 16384) {
        throw const FormatException('Choose a complete VOD file up to eight hours and an explicit audio stream.');
      }
      final uri = source.uri;
      if (uri.userInfo.isNotEmpty || uri.hasFragment ||
          !(uri.scheme == 'file' && uri.host.isEmpty || uri.scheme == 'http' && uri.host == '127.0.0.1')) {
        throw const FormatException('A source job requires a local file or its owned loopback transport.');
      }
      // This binds the transport's representation identity, not a claim that a
      // remote file was hashed in full. URLs and credentials are not persisted.
      final key = sha256.convert(utf8.encode(jsonEncode([
        'owned-source-window-v1', source.identity, duration, source.timelineOffsetMs,
        audioOrdinal, audioDescriptor,
      ]))).toString();
      return SubtitleJobSource._(source, duration, audioOrdinal, key, isCurrent);
    } catch (_) { await source.close(); rethrow; }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await source.close();
  }
}
