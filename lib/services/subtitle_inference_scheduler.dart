import 'dart:async';
import 'package:flutter/widgets.dart';

enum SubtitleWorkPriority { playback, foreground, readAhead, background }

class _SubtitleWork {
  _SubtitleWork(this.priority, this.sequence, this.current, this.execute, this.cancel);
  final SubtitleWorkPriority priority;
  final int sequence;
  final bool Function() current;
  final Future<void> Function() execute;
  final void Function() cancel;
}

/// One local inference operation at a time across UI, PCM, read-ahead and jobs.
/// Priority is chosen only between native calls; cancellation cannot interrupt
/// a model API that exposes no cancel method. No hardware placement is inferred.
class SubtitleInferenceScheduler with WidgetsBindingObserver {
  SubtitleInferenceScheduler._() { WidgetsBinding.instance.addObserver(this); }
  static final instance = SubtitleInferenceScheduler._();
  final List<_SubtitleWork> _queue = [];
  bool _running = false, _memoryHold = false;
  int _sequence = 0;
  Timer? _memoryTimer;
  bool get busy => _running;
  int get waiting => _queue.length;

  Future<T> run<T>(Future<T> Function() body, {SubtitleWorkPriority priority = SubtitleWorkPriority.foreground,
      bool Function()? isCurrent}) {
    if (_queue.length >= 16) return Future.error(StateError('The local subtitle worker queue is full.'));
    final result = Completer<T>();
    final work = _SubtitleWork(priority, _sequence++, isCurrent ?? () => true, () async {
      try { result.complete(await body()); } catch (error, stack) { result.completeError(error, stack); }
    }, () { if (!result.isCompleted) result.completeError(StateError('The subtitle operation was cancelled before inference.')); });
    _queue.add(work);
    scheduleMicrotask(_drain);
    return result.future;
  }
  void _drain() {
    if (_running) return;
    _queue.sort((a, b) {
      final rank = a.priority.index.compareTo(b.priority.index);
      return rank == 0 ? a.sequence.compareTo(b.sequence) : rank;
    });
    while (_queue.isNotEmpty) {
      final work = _queue.first;
      bool valid;
      try { valid = work.current(); } catch (_) { valid = false; }
      if (!valid) { _queue.removeAt(0); work.cancel(); continue; }
      if (_memoryHold && work.priority.index >= SubtitleWorkPriority.readAhead.index) return;
      _queue.removeAt(0); _running = true;
      unawaited(work.execute().whenComplete(() { _running = false; _drain(); }));
      return;
    }
  }
  @override
  void didHaveMemoryPressure() {
    _memoryHold = true;
    _memoryTimer?.cancel();
    _memoryTimer = Timer(const Duration(seconds: 30), () { _memoryHold = false; _drain(); });
  }
}
