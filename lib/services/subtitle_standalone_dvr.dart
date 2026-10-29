import 'dart:async';

import '../media/live_tv_timeline.dart';
import '../mpv/mpv.dart';
import '../mpv/player/subtitle_pcm_capture_source.dart';
import 'subtitle_dvr_delay_service.dart';
import 'subtitle_live_clock.dart';

/// A dialog/hold-owned adapter from a fresh native window to the existing DVR
/// controls. No playlist-derived bounds, media reload or synthetic live edge.
class SubtitleStandaloneDvr {
  SubtitleStandaloneDvr._(this.player, this._clock, this._capture)
      : _hold = SubtitleDvrDelayService.forPlayer(player) {
    _hold.addListener(_onHoldChanged);
  }
  final Player player;
  final SubtitleBackendLiveClock _clock;
  final SubtitlePcmCaptureSource _capture;
  final SubtitleDvrDelayService _hold;
  final Stopwatch _age = Stopwatch()..start();
  int _request = 0, _requestedAt = 0;
  int? _seekGeneration, _holdGeneration;
  double? _target;
  bool _failed = false, _dialogClosed = false, _retired = false;

  static Future<SubtitleStandaloneDvr?> open(Player player, bool Function() isCurrent) async {
    if (player is! SubtitlePcmCaptureSource) return null;
    final clock = await SubtitleBackendLiveClock.open(player, isCurrent);
    if (clock == null) return null;
    if (clock.seekableEpochRange == null) { clock.retire(); return null; }
    return SubtitleStandaloneDvr._(player, clock, player);
  }

  bool get isCurrent => !_retired && _clock.isCurrent;

  LiveTvTimeline timeline(Duration position) {
    final range = isCurrent ? _clock.seekableEpochRange : null;
    final epoch = isCurrent ? _clock.epochForPosition(position.inMilliseconds) : null;
    if (_hold.running && _holdGeneration != null && _holdGeneration != _capture.playbackTimelineGeneration) {
      _failed = true; _target = null;
    }
    if (_target != null) {
      if (_seekGeneration != _capture.playbackTimelineGeneration || !isCurrent ||
          _age.elapsedMilliseconds - _requestedAt > 15000) {
        _failed = true; _target = null;
      } else if (epoch != null && (epoch / 1000 - _target!).abs() < 2) {
        _target = null;
      }
    }
    final valid = range != null && range.endMs - range.startMs > 1;
    return LiveTvTimeline.resolve(
      playback: LiveTvPlaybackPosition(epoch: epoch == null ? null : epoch / 1000,
        active: epoch != null, accuracy: epoch == null ? LiveTvTimeAccuracy.unknown : LiveTvTimeAccuracy.estimated),
      // Media3 positions use milliseconds. The window end is exclusive.
      seekable: !valid ? null : LiveTvSeekWindow(startEpoch: range!.startMs / 1000,
        endEpoch: (range.endMs - 1) / 1000, stepSeconds: .001),
      liveEdgeEpoch: !valid ? null : range!.endMs / 1000,
      liveEdgeAccuracy: valid ? LiveTvTimeAccuracy.estimated : LiveTvTimeAccuracy.unknown,
      seekStatus: _failed ? LiveTvSeekStatus.failed : _target == null ? LiveTvSeekStatus.idle : LiveTvSeekStatus.pending,
      pendingSeekEpoch: _target, metadataNowEpoch: epoch == null ? 0 : epoch / 1000);
  }

  void seek(double epoch) {
    if (!epoch.isFinite || !isCurrent || _target != null) return;
    final range = _clock.seekableEpochRange, target = (epoch * 1000).round();
    if (range == null || target < range.startMs || target >= range.endMs) { _failed = true; return; }
    final request = ++_request;
    _failed = false; _target = epoch; _requestedAt = _age.elapsedMilliseconds;
    // The native epoch command, like Player.seek, increments the timeline
    // generation synchronously. Any later viewer seek invalidates this one.
    _seekGeneration = _capture.playbackTimelineGeneration + 1;
    if (_hold.running) _holdGeneration = _seekGeneration;
    unawaited(_apply(target, request));
  }

  Future<void> _apply(int target, int request) async {
    try {
      final accepted = await _clock.seekEpoch(target);
      if (request != _request || _retired) return;
      if (!accepted || _capture.playbackTimelineGeneration != _seekGeneration) { _failed = true; _target = null; }
    } catch (_) { if (request == _request && !_retired) { _failed = true; _target = null; } }
  }

  /// The clock continues only if an explicitly enabled hold owns it. Stopping
  /// that hold, closing its source or changing profile releases polling.
  void closeDialog() {
    if (_dialogClosed) return;
    _dialogClosed = true;
    _releaseWhenIdle();
  }

  void _onHoldChanged() {
    if (!_hold.running) { _holdGeneration = null; _failed = false; }
    _releaseWhenIdle();
  }

  void _releaseWhenIdle() {
    if (!_dialogClosed || _hold.running) return;
    _retired = true; ++_request; _target = null;
    _hold.removeListener(_onHoldChanged); _clock.retire(); _age.stop();
  }
}
