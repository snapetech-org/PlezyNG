import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../../utils/serial_future_queue.dart';
import 'music_library_store.dart';
import 'music_playback_service.dart';

/// Counts observed playback, excluding pauses, buffering and seeks. It stores
/// cumulative values against one occurrence UUID so retries cannot add plays.
class MusicListeningRecorder {
  MusicListeningRecorder(this.service, this.store, {DateTime Function()? now, int Function()? monotonicMs})
    : _now = now ?? DateTime.now {
    final clock = Stopwatch()..start();
    _clock = monotonicMs ?? () => clock.elapsedMilliseconds;
    service.addListener(_changed);
    _positionSub = service.positionStream.listen(_position);
    _jumpSub = service.playheadJumpStream.listen((_) => _resetAnchor());
    _changed();
  }
  final MusicPlaybackService service;
  final MusicLibraryStore store;
  final DateTime Function() _now;
  late final int Function() _clock;
  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration?> _jumpSub;
  final SerialFutureQueue _writes = SerialFutureQueue();
  MediaItem? _track;
  String? _id;
  DateTime? _started;
  int _occurrence = -1, _listened = 0, _lastFlush = 0;
  int? _lastPosition, _lastClock;
  bool _wasPlaying = false;

  void _changed() {
    if (_occurrence != service.playbackOccurrenceRevision || _track?.globalKey != service.currentTrack?.globalKey) {
      unawaited(flush(finished: true));
      _occurrence = service.playbackOccurrenceRevision;
      _track = service.currentTrack;
      _id = _track == null ? null : const Uuid().v4();
      _started = _now();
      _listened = 0;
      _lastFlush = 0;
      _resetAnchor();
    }
    if (_wasPlaying != service.isPlaying) {
      _resetAnchor();
      if (!service.isPlaying) unawaited(flush());
      _wasPlaying = service.isPlaying;
    }
  }

  void _resetAnchor() {
    _lastPosition = null;
    _lastClock = null;
  }

  void _position(Duration position) {
    final time = _clock(), ms = position.inMilliseconds;
    if (service.isPlaying && _lastPosition != null && _lastClock != null) {
      final delta = ms - _lastPosition!, elapsed = time - _lastClock!;
      // Sparse/background events count only when progression agrees with the
      // monotonic clock. Large discontinuities never award a listening credit.
      if (delta > 0 && elapsed >= 0 && delta <= elapsed + 1500) {
        _listened += min(delta, elapsed);
      }
    }
    _lastPosition = ms;
    _lastClock = time;
    if (_listened - _lastFlush >= 15000) {
      _lastFlush = _listened;
      unawaited(flush());
    }
  }

  Future<void> flush({bool finished = false}) {
    final track = _track, id = _id, started = _started, listened = _listened;
    if (track == null || id == null || started == null || listened == 0) return Future.value();
    return _writes
        .run(() => store.record(id: id, track: track, startedAt: started, listenedMs: listened, finished: finished))
        .catchError((Object error, StackTrace stack) {
          appLogger.w('Music history write failed', error: error, stackTrace: stack);
        });
  }

  void dispose() {
    service.removeListener(_changed);
    unawaited(_positionSub.cancel());
    unawaited(_jumpSub.cancel());
    unawaited(flush(finished: true));
  }
}
