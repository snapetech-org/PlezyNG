import 'dart:convert';

import '../../../media/media_source_info.dart';
import '../../models.dart';

/// Source metadata for an unchanged original, never a converted rendition or
/// an inferred receiver/output format. Both native TV backends use this path.
List<Map<String, Object?>> nativeTvDirectAudioMetadata(MediaSourceInfo? source, {required bool isTranscoding}) {
  if (isTranscoding || source == null) return const [];
  final tracks = source.audioTracks.where((track) => !track.isExternal).toList();
  if (tracks.length > 128) return const [];
  String? bounded(String? value) => value != null && value.length <= 64 ? value : null;
  return [
    for (final track in tracks)
      {
        'codec': bounded(track.codec),
        'codecProfile': bounded(track.codecProfile),
        'channels': track.channels,
        'sampleRate': track.sampleRate,
        'bitRate': track.bitrate,
      },
  ];
}

List<Map<String, dynamic>> decodeNativeTvAudioMetadata(String value) {
  try {
    final decoded = value.length <= 65536 ? jsonDecode(value) : null;
    if (decoded is List && decoded.length <= 128 && decoded.every((row) => row is Map)) {
      return [for (final row in decoded) Map<String, dynamic>.from(row as Map)];
    }
  } on FormatException {
    // Invalid optional metadata cannot prevent playback.
  }
  return const [];
}

/// Callers match complete source/native catalogs before passing a hint.
/// Prefer a known native codec; an unknown codec can use one atomic original
/// source descriptor rather than mixing values from different renditions.
({AudioTrack track, String origin}) nativeTvAudioDescriptor(AudioTrack native, Map<String, dynamic>? hint) {
  String? text(Object? value) => value is String && value.trim().isNotEmpty && value.length <= 64 ? value.trim() : null;
  String? codec(Object? value) {
    final result = text(value);
    return result == null || const {'unknown', 'none', 'n/a', 'undefined'}.contains(result.toLowerCase())
        ? null
        : result;
  }

  int? positive(Object? value) {
    final number = value is num && value.isFinite ? value.toInt() : int.tryParse('$value');
    return number != null && number > 0 ? number : null;
  }

  final nativeCodec = codec(native.codec);
  final sourceCodec = codec(hint?['codec']);
  final sourceChannels = positive(hint?['channels']);
  final sourceRate = positive(hint?['sampleRate']);
  final conflicts =
      (native.channels != null && sourceChannels != null && native.channels != sourceChannels) ||
      (native.sampleRate != null && sourceRate != null && native.sampleRate != sourceRate);
  if (nativeCodec != null || sourceCodec == null || conflicts) {
    return (track: native.copyWith(codec: nativeCodec), origin: nativeCodec == null ? 'unreported' : 'native-source');
  }
  return (
    track: native.copyWith(
      codec: sourceCodec,
      codecProfile: text(hint?['codecProfile']),
      channels: sourceChannels ?? native.channels,
      sampleRate: sourceRate ?? native.sampleRate,
      bitrate: positive(hint?['bitRate']) ?? native.bitrate,
    ),
    origin: 'server-source',
  );
}
