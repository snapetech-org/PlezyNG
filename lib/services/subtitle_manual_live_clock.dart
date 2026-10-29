import '../mpv/mpv.dart';
import '../mpv/player/subtitle_pcm_capture_source.dart';
import 'subtitle_live_clock.dart';

/// An explicit viewer-supplied UTC anchor, never inferred from wall-clock now,
/// playlist duration, decoder startup or a URL. Valid only on the same player
/// timeline, with a bounded lifetime and conservative jump detection.
class SubtitleManualLiveClock implements SubtitleLiveClock {
  SubtitleManualLiveClock._(this.player, this._capture, this._ownerCurrent, this.epochMs)
      : positionMs = player.currentPosition.inMilliseconds,
        _media = _capture.mediaSessionGeneration,
        _seek = _capture.playbackTimelineGeneration,
        _offset = player.timelineOffset,
        _lastPosition = player.currentPosition.inMilliseconds,
        _lastRate = player.state.rate,
        _lastPlaying = player.state.playing;

  @override
  final Player player;
  final SubtitlePcmCaptureSource _capture;
  final bool Function() _ownerCurrent;
  final int epochMs, positionMs, _media, _seek;
  final Duration _offset;
  final Stopwatch _age = Stopwatch()..start();
  int _lastElapsed = 0, _lastPosition;
  double _lastRate;
  bool _lastPlaying, _retired = false;

  static SubtitleManualLiveClock anchor(Player player, DateTime utc, {required int pausedPositionMs,
      required bool Function() isCurrent}) {
    if (player is! SubtitlePcmCaptureSource || !player.isLivePlayback || player.disposed ||
        player.state.playing || player.currentPosition.inMilliseconds != pausedPositionMs || !isCurrent() ||
        !utc.isUtc || utc.year < 2000 || utc.year > 2200) {
      throw StateError('Pause the same live frame and enter its known UTC program time.');
    }
    return SubtitleManualLiveClock._(player, player, isCurrent, utc.millisecondsSinceEpoch);
  }

  @override
  bool get isCurrent {
    if (_retired) return false;
    try {
      final elapsed = _age.elapsedMilliseconds, position = player.currentPosition.inMilliseconds;
      final rate = player.state.rate;
      if (player.disposed || !_ownerCurrent() || !_capture.isLivePlayback ||
          _capture.mediaSessionGeneration != _media || _capture.playbackTimelineGeneration != _seek ||
          player.timelineOffset != _offset || elapsed > 15 * 60 * 1000 ||
          !rate.isFinite || rate <= 0 || rate > 16) {
        retire(); return false;
      }
      final delta = position - _lastPosition;
      final maximumRate = rate > _lastRate ? rate : _lastRate;
      final possibleAdvance = (_lastPlaying || player.state.playing) ? (elapsed - _lastElapsed) * maximumRate : 0;
      if (delta < -500 || delta > possibleAdvance + 1500) { retire(); return false; }
      _lastElapsed = elapsed; _lastPosition = position; _lastRate = rate; _lastPlaying = player.state.playing;
      return true;
    } catch (_) { retire(); return false; }
  }

  @override
  int? epochForPosition(int value) => isCurrent ? epochMs + value - positionMs : null;
  @override
  ({int startMs, int endMs})? get seekableEpochRange => null;
  @override
  void retire() { _retired = true; _age.stop(); }
}
