import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'power_source_service.dart';

enum SubtitleWorkPriority { playback, foreground, readAhead, background }

/// No model operation began. Background owners may retry, without marking the
/// corresponding audio window complete.
class SubtitleInferenceDeferred implements Exception {
  const SubtitleInferenceDeferred(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

class _SubtitleWork {
  _SubtitleWork(this.priority, this.sequence, this.current, this.execute, this.cancel, this.owner);
  final SubtitleWorkPriority priority;
  final int sequence;
  final bool Function() current;
  final Future<void> Function() execute;
  final void Function(Object) cancel;
  final Object? owner;
  final queuedAt = DateTime.now();
}

class _PlaybackLoad {
  _PlaybackLoad(this.active, this.thermal);
  final bool Function() active;
  final Future<String?> Function() thermal;
}

/// Dispose the runtime before releasing its resident-model slot, including on
/// load failure. Revocation asks the owner to stop at its next safe boundary.
final class SubtitleModelLease {
  SubtitleModelLease._(this._scheduler, this.owner, this._releaseRequested);
  final SubtitleInferenceScheduler _scheduler;
  final Object owner;
  final void Function(String) _releaseRequested;
  bool _released = false, _revoked = false;
  bool get revoked => _revoked;
  void release() {
    if (_released) return;
    _released = true;
    if (identical(_scheduler._resident, this)) _scheduler._resident = null;
    _scheduler._changed();
  }
  void _revoke(String reason) {
    if (_released || _revoked) return;
    _revoked = true;
    _releaseRequested(reason);
  }
}

/// Admission for local subtitle speech inference across players and jobs. Serializes
/// calls and loading, including live models retained between calls. Process RSS
/// is not GPU memory or a measurement of model allocations. Policy applies
/// between native calls; an API without cancellation cannot be interrupted.
class SubtitleInferenceScheduler extends ChangeNotifier with WidgetsBindingObserver {
  SubtitleInferenceScheduler._() {
    WidgetsBinding.instance.addObserver(this);
    _ready = _loadPolicy();
  }
  static final instance = SubtitleInferenceScheduler._();
  static const _preference = 'subtitle_inference_resources_v1';
  final List<_SubtitleWork> _queue = [];
  final Map<Object, _PlaybackLoad> _players = Map.identity();
  late final Future<void> _ready;
  Future<void>? _refreshPending;
  SubtitleModelLease? _resident;
  bool _running = false, _memoryHold = false;
  int _sequence = 0, _activeVideos = 0;
  Timer? _memoryTimer, _pollTimer;
  bool? _externalPower;
  String? _thermal;
  int? _rssBytes;
  bool _readAheadChargingOnly = false, _pauseForMultiview = true;
  int _rssLimitMiB = 0;
  String? _waitingReason;

  bool get busy => _running;
  int get waiting => _queue.length;
  bool get residentModel => _resident != null;
  bool? get externalPower => _externalPower;
  String? get thermalTier => _thermal;
  int? get rssBytes => _rssBytes;
  int get activeVideoPlayers => _activeVideos;
  String? get waitingReason => _waitingReason;
  bool get readAheadChargingOnly => _readAheadChargingOnly;
  bool get pauseForMultiview => _pauseForMultiview;
  int get rssLimitMiB => _rssLimitMiB;

  Future<void> _loadPolicy() async {
    try {
      final text = (await SharedPreferences.getInstance()).getString(_preference);
      final data = text == null ? null : jsonDecode(text);
      if (data is! Map) return;
      _readAheadChargingOnly = data['charging'] == true;
      _pauseForMultiview = data['multiview'] != false;
      final limit = data['rssMiB'];
      _rssLimitMiB = limit is int && limit >= 256 && limit <= 65536 ? limit : 0;
    } catch (_) { /* Unavailable preferences: retain defaults. */ }
  }

  Future<void> configure({required bool readAheadChargingOnly, required bool pauseForMultiview,
      required int rssLimitMiB}) async {
    if (rssLimitMiB != 0 && (rssLimitMiB < 256 || rssLimitMiB > 65536)) {
      throw ArgumentError('The process RSS limit must be 0 (off) or 256–65536 MiB.');
    }
    await _ready;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_preference, jsonEncode({'charging': readAheadChargingOnly,
        'multiview': pauseForMultiview, 'rssMiB': rssLimitMiB}))) {
      throw StateError('Could not save subtitle resource preferences.');
    }
    _readAheadChargingOnly = readAheadChargingOnly;
    _pauseForMultiview = pauseForMultiview;
    _rssLimitMiB = rssLimitMiB;
    await refresh();
    _changed();
  }

  /// Registration is lifecycle-owned and cheap. Poll only during subtitle work.
  void registerPlayer(Object owner, {required bool Function() active, required Future<String?> Function() thermal}) {
    _players[owner] = _PlaybackLoad(active, thermal);
  }
  void unregisterPlayer(Object owner) { _players.remove(owner); }

  Future<void> refresh() => _refreshPending ??= _refresh().whenComplete(() => _refreshPending = null);
  Future<void> _refresh() async {
    await _ready;
    _externalPower = await PowerSourceService.isConnected().timeout(const Duration(seconds: 2), onTimeout: () => null);
    try { _rssBytes = ProcessInfo.currentRss; } catch (_) { _rssBytes = null; }
    var active = 0;
    final probes = <Future<String?>>[];
    for (final entry in _players.entries.toList(growable: false)) {
      bool playing;
      try { playing = entry.value.active(); } catch (_) { playing = false; }
      if (playing) active++;
      // Thermal state is device-wide. Bound calls even with many panes.
      if (probes.length < 8) probes.add(() async {
        try { return await entry.value.thermal().timeout(const Duration(seconds: 2)); } catch (_) { return null; }
      }());
    }
    const tiers = ['unknown', 'none', 'nominal', 'light', 'fair', 'moderate', 'serious', 'severe', 'critical', 'emergency', 'shutdown'];
    String? worst;
    for (final tier in await Future.wait(probes)) {
      if (tier != null && tiers.contains(tier) && tier != 'unknown' &&
          (worst == null || tiers.indexOf(tier) > tiers.indexOf(worst))) worst = tier;
    }
    _thermal = worst;
    _activeVideos = active;
    final pressure = _hardHold;
    if (pressure != null) _resident?._revoke(pressure);
    _changed();
  }

  String? get _hardHold {
    if (const {'serious','severe','critical','emergency','shutdown'}.contains(_thermal)) return 'Waiting for the device to cool down ($_thermal).';
    if (_rssLimitMiB > 0 && _rssBytes != null && _rssBytes! >= _rssLimitMiB * 1024 * 1024) {
      return 'The process is above the configured $_rssLimitMiB MiB RSS limit.';
    }
    return null;
  }

  String? _hold(_SubtitleWork work) {
    if (_resident != null && !identical(work.owner, _resident!.owner)) return 'A live subtitle model is resident. Stop live captions to run another local model.';
    if (_resident?.revoked == true && identical(work.owner, _resident!.owner)) return 'The live model is releasing resources.';
    final hard = _hardHold;
    if (hard != null) return hard;
    if (_memoryHold) return 'Waiting after an OS memory-pressure event.';
    if (work.priority.index >= SubtitleWorkPriority.readAhead.index) {
      if (_thermal == 'moderate') return 'Waiting for lower device thermal pressure.';
      if (_pauseForMultiview && _activeVideos > 1) return 'Waiting while multiple video players are active.';
      if (work.priority == SubtitleWorkPriority.readAhead && _readAheadChargingOnly && _externalPower != true) {
        return 'Read-ahead is waiting for confirmed external power.';
      }
    }
    return null;
  }

  Future<SubtitleModelLease> reserveModel(Object owner, {required bool Function() isCurrent,
      required void Function(String) onReleaseRequested}) => run(() async {
    if (_resident != null) throw StateError('A local subtitle model is already resident.');
    final lease = SubtitleModelLease._(this, owner, onReleaseRequested);
    _resident = lease;
    return lease;
  }, priority: SubtitleWorkPriority.playback, isCurrent: isCurrent, modelOwner: owner);

  Future<T> run<T>(Future<T> Function() body, {SubtitleWorkPriority priority = SubtitleWorkPriority.foreground,
      bool Function()? isCurrent, Object? modelOwner}) async {
    // All callers await the same initial observation before queue admission.
    await refresh();
    if (_queue.length >= 16) throw StateError('The local subtitle worker queue is full.');
    final result = Completer<T>();
    final work = _SubtitleWork(priority, _sequence++, isCurrent ?? () => true, () async {
      try { result.complete(await body()); } catch (error, stack) { result.completeError(error, stack); }
    }, (error) { if (!result.isCompleted) result.completeError(error); }, modelOwner);
    _queue.add(work);
    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) { _drain(); unawaited(refresh()); });
    _changed();
    return result.future;
  }

  void _changed() {
    scheduleMicrotask(_drain);
    notifyListeners();
    if (!_running && _queue.isEmpty && _resident == null) { _pollTimer?.cancel(); _pollTimer = null; }
  }

  void _drain() {
    _queue.sort((a, b) {
      final rank = a.priority.index.compareTo(b.priority.index);
      return rank == 0 ? a.sequence.compareTo(b.sequence) : rank;
    });
    _waitingReason = null;
    // Sweep stale owners even during a long native call, so cancellation does
    // not wait on somebody else's inference. Skip held work to serve the owner.
    for (final work in _queue.toList(growable: false)) {
      bool valid;
      try { valid = work.current(); } catch (_) { valid = false; }
      if (!valid) {
        _queue.remove(work); work.cancel(StateError('The subtitle operation was cancelled before inference.')); continue;
      }
      final reason = _hold(work);
      if (reason != null) {
        _waitingReason ??= reason;
        if (work.priority.index <= SubtitleWorkPriority.foreground.index ||
            DateTime.now().difference(work.queuedAt) >= const Duration(seconds: 30)) {
          _queue.remove(work); work.cancel(SubtitleInferenceDeferred(reason));
        }
        continue;
      }
      if (_running) continue;
      _queue.remove(work); _running = true;
      unawaited(work.execute().whenComplete(() { _running = false; _changed(); }));
      break;
    }
    if (!_running && _queue.isEmpty && _resident == null) { _pollTimer?.cancel(); _pollTimer = null; }
  }

  @override
  void didHaveMemoryPressure() {
    _memoryHold = true;
    _resident?._revoke('The OS requested memory relief; live subtitle inference is stopping.');
    _memoryTimer?.cancel();
    _memoryTimer = Timer(const Duration(seconds: 30), () { _memoryHold = false; _changed(); });
    _changed();
  }
}
