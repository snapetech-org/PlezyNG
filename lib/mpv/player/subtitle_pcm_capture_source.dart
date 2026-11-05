import 'player_state.dart';

/// Optional player-owned PCM copy used by local live subtitle capture.
///
/// Implementations must provide bounded, non-blocking native capture and media
/// presentation timestamps. The transcription service never records a file.
abstract interface class SubtitlePcmCaptureSource {
  PlayerState get state;
  Duration get currentPosition;

  int get mediaSessionGeneration;
  bool get isLivePlayback;
  bool get disposed;
  String? get subtitlePcmAudioTrackId;

  Future<bool> subtitlePcmCaptureAvailable();
  Future<bool> setSubtitlePcmCaptureEnabled(bool enabled);
  Future<List<Map<String, Object?>>> drainSubtitlePcmCapture();
}

/// Explicit user seeks are distinct from an unexplained live PTS rollover.
/// Only the former may reuse cues already captured on the current timeline.
abstract interface class SubtitlePcmTimelineSource {
  int get subtitlePcmSeekGeneration;
  Duration? get subtitlePcmSeekTarget;
  Duration get timelineOffset;
}
