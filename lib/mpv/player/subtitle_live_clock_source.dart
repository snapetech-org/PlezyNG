import 'player_media_session_identity.dart';

/// One atomic backend timeline observation. Positions are on the opened
/// file/window clock; [windowStartEpochMs] is supplied by the media timeline,
/// never reconstructed from the local wall clock or playlist length.
class SubtitleLiveClockSnapshot {
  const SubtitleLiveClockSnapshot({required this.generation, required this.positionMs,
    required this.windowStartEpochMs, this.seekableDurationMs});
  final int generation, positionMs, windowStartEpochMs;
  final int? seekableDurationMs;
}

abstract interface class SubtitleLiveClockSource implements PlayerMediaSessionIdentity {
  /// Whether this backend currently owns live playback and has not fallen back
  /// to a renderer that cannot expose its program clock.
  bool get canReadSubtitleLiveClock;
  Future<SubtitleLiveClockSnapshot?> readSubtitleLiveClock();
  /// The native side must re-read the current window and refuse expired
  /// targets/generations before converting this epoch into a source position.
  Future<bool> seekSubtitleLiveEpoch(int epochMs, {required int generation});
}
