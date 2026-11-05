/// Presentation-neutral state of an opt-in playback transcription session.
enum SubtitleCapturePhase {
  loadingModel, downloadingModel, capturing, startFailed, inferenceFailed,
  noSpeech, captured, playbackEnded, playbackChanged, audioTrackChanged,
  listening, captureUnavailable, waitingForAudio, captureStopped,
}

enum SubtitleModelLoadPhase { downloading, loading }

final class SubtitleCaptureStatus {
  const SubtitleCaptureStatus(this.phase, {this.count = 0, this.received = 0, this.total = 0});

  final SubtitleCapturePhase phase;
  final int count, received, total;
  int? get percent => total > 0 ? (received * 100 / total).round().clamp(0, 100).toInt() : null;

  @override
  bool operator ==(Object other) => other is SubtitleCaptureStatus &&
      phase == other.phase && count == other.count && received == other.received && total == other.total;
  @override
  int get hashCode => Object.hash(phase, count, received, total);
}
