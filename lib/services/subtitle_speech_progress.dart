/// Speech preparation/inference progress contains data, never UI prose.
enum SubtitleSpeechPhase {
  downloadingModel,
  downloadingDetector,
  loadingModel,
  transcribing,
  translating,
  inference,
  cpuFallback,
}

typedef SubtitleSpeechProgressCallback = void Function(SubtitleSpeechPhase phase, int received, int total);

final class SubtitleSpeechProgress {
  const SubtitleSpeechProgress(this.phase, {this.received = 0, this.total = 0});
  final SubtitleSpeechPhase phase;
  final int received, total;
  int? get percent => total > 0 ? (received * 100 / total).round().clamp(0, 100).toInt() : null;
}
