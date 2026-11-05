enum SubtitleCapturePacketAction { append, resetWindow, resetTimeline, discard }

/// A decoded audio clock. A user seek retains DVR cues, whereas an unexplained
/// backwards live-clock jump starts a new epoch and cannot reuse old cue times.
final class SubtitleCaptureTimeline {
  SubtitleCaptureTimeline({required this.live, required int seekGeneration}) : _seekGeneration = seekGeneration;
  final bool live;
  int _seekGeneration;
  int? _seekTargetUs;
  int? _expectedUs;
  bool _seekPending = false;

  int get seekGeneration => _seekGeneration;

  SubtitleCapturePacketAction accept({
    required int ptsUs,
    required int durationUs,
    required int seekGeneration,
    int? seekTargetUs,
    bool formatChanged = false,
  }) {
    if (seekGeneration != _seekGeneration) {
      _seekGeneration = seekGeneration;
      _seekTargetUs = seekTargetUs;
      _expectedUs = null;
      _seekPending = true;
    }
    final target = _seekTargetUs;
    if (target != null && (ptsUs - target).abs() > 3000000) return SubtitleCapturePacketAction.discard;
    final sought = _seekPending;
    _seekPending = false;
    _seekTargetUs = null;
    final gap = _expectedUs == null ? 0 : ptsUs - _expectedUs!;
    _expectedUs = ptsUs + durationUs;
    if (live && !sought && gap < -150000) return SubtitleCapturePacketAction.resetTimeline;
    if (sought || formatChanged || gap < -150000 || gap > 1500000) return SubtitleCapturePacketAction.resetWindow;
    return SubtitleCapturePacketAction.append;
  }
}
