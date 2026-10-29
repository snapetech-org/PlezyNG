import 'dart:async';

import '../mpv/mpv.dart';
import '../mpv/player/subtitle_live_clock_source.dart';
import '../mpv/player/subtitle_pcm_capture_source.dart';

abstract interface class SubtitleLiveClock {
  Player get player;
  bool get isCurrent;
  int? epochForPosition(int positionMs);
  ({int startMs, int endMs})? get seekableEpochRange;
  void retire();
}

/// Refreshes a media-provided clock only while its source owner remains valid.
/// The bridge and player event stream are asynchronous, so this mapping remains
/// explicitly estimated. Unmatched positions and stale samples hide captions
/// instead of substituting elapsed time or wall-clock now as media time.
class SubtitleBackendLiveClock implements SubtitleLiveClock {
  SubtitleBackendLiveClock._(this.player, this._backend, this._capture, this._ownerCurrent)
      : _media = _capture.mediaSessionGeneration, _offset = player.timelineOffset;

  @override
  final Player player;
  final SubtitleLiveClockSource _backend;
  final SubtitlePcmCaptureSource _capture;
  final bool Function() _ownerCurrent;
  final int _media;
  final Duration _offset;
  final Stopwatch _age = Stopwatch()..start();
  Timer? _timer;
  SubtitleLiveClockSnapshot? _sample;
  int? _nativeGeneration;
  int _sampleAt = 0, _sampleSeek = -1, _samplePlayerPosition = 0;
  double _sampleRate = 1;
  bool _busy = false, _retired = false;

  static Future<SubtitleBackendLiveClock?> open(Player player, bool Function() isCurrent) async {
    if (player is! SubtitleLiveClockSource || player is! SubtitlePcmCaptureSource ||
        player.disposed || !player.canReadSubtitleLiveClock || !player.isLivePlayback || !isCurrent()) return null;
    final clock = SubtitleBackendLiveClock._(player, player, player, isCurrent);
    await clock._refresh();
    if (clock._fresh == null) { clock.retire(); return null; }
    clock._timer = Timer.periodic(const Duration(milliseconds: 500), (_) => unawaited(clock._refresh()));
    return clock;
  }

  @override
  bool get isCurrent {
    if (_retired) return false;
    try {
      if (!player.disposed && _backend.canReadSubtitleLiveClock && _capture.isLivePlayback && _ownerCurrent() &&
          _capture.mediaSessionGeneration == _media && player.timelineOffset == _offset) return true;
    } catch (_) { /* The owner disappeared. */ }
    retire(); return false;
  }

  Future<void> _refresh() async {
    if (_busy || !isCurrent) return;
    _busy = true;
    final requested = _age.elapsedMilliseconds, seek = _capture.playbackTimelineGeneration;
    try {
      final sample = await _backend.readSubtitleLiveClock().timeout(const Duration(milliseconds: 1500));
      if (!isCurrent) return;
      if (sample != null && _nativeGeneration != null && sample.generation != _nativeGeneration) {
        retire(); return;
      }
      final position = player.currentPosition.inMilliseconds;
      final rate = player.state.rate;
      if (sample == null || _age.elapsedMilliseconds - requested > 1000 ||
          seek != _capture.playbackTimelineGeneration || !rate.isFinite || rate <= 0 || rate > 16 ||
          (sample.positionMs + _offset.inMilliseconds - position).abs() > 750 ||
          sample.positionMs < 0 || sample.windowStartEpochMs < 946684800000 ||
          sample.windowStartEpochMs > 7258118400000) {
        _sample = null; return;
      }
      _nativeGeneration ??= sample.generation;
      _sample = sample;
      _sampleAt = _age.elapsedMilliseconds; _sampleSeek = seek;
      _samplePlayerPosition = position; _sampleRate = rate;
    } catch (_) { _sample = null; }
    finally { _busy = false; }
  }

  SubtitleLiveClockSnapshot? get _fresh {
    if (!isCurrent) return null;
    final sample = _sample, elapsed = _age.elapsedMilliseconds - _sampleAt;
    final rate = player.state.rate;
    if (sample == null || elapsed > 2000 || _sampleSeek != _capture.playbackTimelineGeneration ||
        !rate.isFinite || rate <= 0 || rate > 16) return null;
    final delta = player.currentPosition.inMilliseconds - _samplePlayerPosition;
    final maxRate = rate > _sampleRate ? rate : _sampleRate;
    if (delta < -750 || delta > elapsed * maxRate + 750) return null;
    return sample;
  }

  @override
  int? epochForPosition(int positionMs) {
    final sample = _fresh;
    if (sample == null) return null;
    final local = positionMs - _offset.inMilliseconds;
    if (local < 0 || sample.seekableDurationMs != null && local > sample.seekableDurationMs!) return null;
    return sample.windowStartEpochMs + local;
  }

  @override
  ({int startMs, int endMs})? get seekableEpochRange {
    final sample = _fresh, duration = sample?.seekableDurationMs;
    if (sample == null || duration == null || duration <= 0 || duration > 7 * 86400000) return null;
    return (startMs: sample.windowStartEpochMs, endMs: sample.windowStartEpochMs + duration);
  }

  Future<bool> seekEpoch(int epochMs) async {
    final sample = _fresh, range = seekableEpochRange;
    if (sample == null || range == null || epochMs < range.startMs || epochMs >= range.endMs) return false;
    return await _backend.seekSubtitleLiveEpoch(epochMs, generation: sample.generation) && isCurrent;
  }

  @override
  void retire() { _retired = true; _timer?.cancel(); _timer = null; _sample = null; _age.stop(); }
}
