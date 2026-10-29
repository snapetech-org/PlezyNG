import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../media/live_tv_timeline.dart';
import '../mpv/mpv.dart';
import '../mpv/player/player_media_session_identity.dart';
import '../mpv/player/subtitle_pcm_capture_source.dart';

/// Explicit, bounded DVR delay hold. All targets come from the backend's
/// current seek grid. No wall-clock estimate supplies a media timestamp.
class SubtitleDvrDelayService extends ChangeNotifier {
  SubtitleDvrDelayService._(this.player);
  static final Expando<SubtitleDvrDelayService> _sessions = Expando();
  static SubtitleDvrDelayService forPlayer(Player player) => _sessions[player] ??= SubtitleDvrDelayService._(player);
  final Player player;
  Timer? _timer;
  LiveTvTimeline Function(Duration)? _timeline;
  ValueChanged<double>? _seek;
  bool Function()? _isCurrent;
  int? _media, _seekGeneration;
  String? _audio;
  bool _seekKeepsPlaybackState = false;
  DateTime? _requestAt, _lastSeekAt, _unavailableAt;
  double delaySeconds = 15;
  String status = 'Delay hold is off';
  bool get running => _timer != null;

  void start({required double seconds, required LiveTvTimeline Function(Duration) timeline,
      required ValueChanged<double> seek, required bool Function() isCurrent, bool seekKeepsPlaybackState = false}) {
    if (!seconds.isFinite || seconds < 5 || seconds > 120) throw ArgumentError('Choose a delay between 5 and 120 seconds');
    stop();
    _timeline = timeline; _seek = seek; _isCurrent = isCurrent; delaySeconds = seconds;
    _seekKeepsPlaybackState = seekKeepsPlaybackState;
    _media = player is PlayerMediaSessionIdentity ? (player as PlayerMediaSessionIdentity).mediaSessionGeneration : null;
    _seekGeneration = player is SubtitlePcmCaptureSource ? (player as SubtitlePcmCaptureSource).playbackTimelineGeneration : null;
    _audio = player.state.track.audio?.id;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    _tick();
  }

  void stop([String message = 'Delay hold is off']) {
    _timer?.cancel(); _timer = null; _timeline = null; _seek = null; _isCurrent = null;
    _requestAt = null; _lastSeekAt = null; _unavailableAt = null;
    status = message; notifyListeners();
  }

  void _tick() {
    if (!running) return;
    try {
      if (player.disposed || _isCurrent?.call() != true || _audio != player.state.track.audio?.id ||
          _media != null && (player as PlayerMediaSessionIdentity).mediaSessionGeneration != _media) {
        stop('Delay hold stopped: playback, audio or profile changed'); return;
      }
      final timeline = _timeline!(player.currentPosition), now = DateTime.now();
      if (timeline.seekStatus == LiveTvSeekStatus.failed) { stop('Delay hold stopped: the backend seek failed'); return; }
      final seekGeneration = player is SubtitlePcmCaptureSource ? (player as SubtitlePcmCaptureSource).playbackTimelineGeneration : null;
      final ownSeek = _requestAt != null;
      // A native in-place seek keeps play/pause intent. A server DVR seek may
      // reopen a source and temporarily report paused while opening; preserve
      // its existing ownership path until the timeline settles.
      if (ownSeek && _seekKeepsPlaybackState && (!player.state.playing || (player.state.rate - 1).abs() > .001) ||
          !ownSeek && (seekGeneration != _seekGeneration || !player.state.playing || (player.state.rate - 1).abs() > .001 ||
          timeline.seekStatus == LiveTvSeekStatus.pending || timeline.seekStatus == LiveTvSeekStatus.opening)) {
        stop('Delay hold stopped: viewer playback control takes precedence'); return;
      }
      final window = timeline.seekable, edge = timeline.liveEdgeEpoch, playback = timeline.playback;
      final valid = window?.isValid == true && edge != null && edge.isFinite && playback.active &&
          playback.epoch?.isFinite == true &&
          (playback.accuracy == LiveTvTimeAccuracy.confirmed || playback.accuracy == LiveTvTimeAccuracy.estimated) &&
          (timeline.liveEdgeAccuracy == LiveTvTimeAccuracy.confirmed || timeline.liveEdgeAccuracy == LiveTvTimeAccuracy.estimated);
      if (!valid) {
        _unavailableAt ??= now;
        if (now.difference(_unavailableAt!).inSeconds >= 20) { stop('Delay hold stopped: no fresh backend DVR clock'); return; }
        status = 'Waiting for the backend DVR window'; notifyListeners(); return;
      }
      _unavailableAt = null;
      final target = window!.target(edge! - delaySeconds)!;
      final tolerance = math.max(4.0, window.stepSeconds * 2);
      final difference = (playback.epoch! - target).abs();
      if (ownSeek) {
        if (timeline.pendingSeekEpoch != null && (timeline.pendingSeekEpoch! - target).abs() > tolerance + 20) {
          stop('Delay hold stopped: another seek took control'); return;
        }
        if (timeline.seekStatus == LiveTvSeekStatus.idle && difference <= tolerance) {
          _seekGeneration = seekGeneration; _requestAt = null;
        } else if (now.difference(_requestAt!).inSeconds >= 20) {
          stop('Delay hold stopped: the backend did not confirm the requested delay'); return;
        }
        status = 'Waiting for the requested DVR delay'; notifyListeners(); return;
      }
      status = 'Holding ${(edge - target).toStringAsFixed(1)} seconds behind live';
      if (difference > tolerance && (_lastSeekAt == null || now.difference(_lastSeekAt!).inSeconds >= 30)) {
        // Set ownership before invoking a callback that can synchronously seek.
        _requestAt = now; _lastSeekAt = now;
        _seek!(target);
      }
      notifyListeners();
    } catch (_) { stop('Delay hold stopped: this backend no longer exposes a current DVR window'); }
  }
}
