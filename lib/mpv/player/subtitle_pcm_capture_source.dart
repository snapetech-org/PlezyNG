import 'player_media_session_identity.dart';
import 'player_state.dart';

/// Optional player-owned PCM copy used by local live subtitle capture.
///
/// Implementations must provide bounded, non-blocking native capture and media
/// presentation timestamps. The transcription service never records a file.
abstract interface class SubtitlePcmCaptureSource implements PlayerMediaSessionIdentity {
  PlayerState get state;
  Duration get currentPosition;

  @override
  int get mediaSessionGeneration;

  /// Changes on explicit timeline seeks without changing the open media item.
  int get playbackTimelineGeneration;

  bool get isLivePlayback;
  bool get disposed;
  String? get subtitlePcmAudioTrackId;

  Future<bool> subtitlePcmCaptureAvailable();
  Future<bool> setSubtitlePcmCaptureEnabled(bool enabled);
  Future<List<Map<String, Object?>>> drainSubtitlePcmCapture();
}

/// Native capture uses the open file/window clock. App captions and replay use
/// the item's clock, including a stacked file's offset. Apply exactly once at
/// the player boundary, never infer an offset from wall time or drain latency.
List<Map<String, Object?>> subtitlePcmOnItemTimeline(Iterable<dynamic> packets, Duration offset) => [
  for (final value in packets) if (value is Map) (() {
    final packet = Map<String, Object?>.from(value);
    final pts = packet['presentationTimeUs'];
    if (pts is num && pts.isFinite) packet['presentationTimeUs'] = pts.toInt() + offset.inMicroseconds;
    return packet;
  })(),
];
