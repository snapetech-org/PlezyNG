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
