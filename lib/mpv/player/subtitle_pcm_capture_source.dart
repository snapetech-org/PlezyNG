/// Optional player-owned PCM copy used by local live subtitle capture.
///
/// Implementations must provide bounded, non-blocking native capture and media
/// presentation timestamps. The transcription service never records a file.
abstract interface class SubtitlePcmCaptureSource {
  int get mediaSessionGeneration;
  bool get isLivePlayback;
  bool get disposed;
  String? get subtitlePcmAudioTrackId;
  Duration get subtitlePcmPosition;
  Duration get subtitlePcmDuration;

  Future<bool> subtitlePcmCaptureAvailable();
  Future<bool> setSubtitlePcmCaptureEnabled(bool enabled);
  Future<List<Map<String, Object?>>> drainSubtitlePcmCapture();
}
