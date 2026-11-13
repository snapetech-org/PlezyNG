enum SubtitleCapturePacketAction { append, resetWindow, resetTimeline, discard }

/// A decoded audio clock. A user seek retains DVR cues, whereas an unexplained
/// backwards live-clock jump starts a new epoch and cannot reuse old cue times.
final class SubtitleCaptureTimeline {
  /// Largest forward PTS gap that can remain in one inference window. The
  /// capture adapter represents gaps through this bound as silence in PCM.
  static const int maximumForwardGapUs = 250000;

  SubtitleCaptureTimeline({required this.live, required this._seekGeneration});
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
    if (sought || formatChanged || gap < -150000 || gap > maximumForwardGapUs) {
      return SubtitleCapturePacketAction.resetWindow;
    }
    return SubtitleCapturePacketAction.append;
  }
}
