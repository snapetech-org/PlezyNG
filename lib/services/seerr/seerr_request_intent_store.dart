import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/media_kind.dart';
import '../../models/seerr/seerr_request_intent.dart';
import '../../utils/app_logger.dart';
import 'seerr_client.dart';
import 'seerr_exceptions.dart';

/// A cache belonging to one Seerr client/profile. Card reads are coalesced
/// into bounded requests; a mutation invalidates only its typed title. Late
/// responses cannot repopulate the cache after a profile change or mutation.
class SeerrRequestIntentStore extends ChangeNotifier {
  SeerrRequestIntentStore(this.client);
  final SeerrClient client;
  final _states = <String, (SeerrRequestIntent, DateTime)>{};
  final _waiting = <String, Completer<void>>{};
  final _keys = <String, (MediaKind, int)>{};
  final _epochs = <String, int>{};
  Timer? _flushTimer;
  bool _unsupported = false;
  bool _closed = false;

  /// Vanilla Seerr has no batch intent endpoint. Only detail/menu callers
  /// should use its individual title APIs as a fallback; cards stay batched.
  bool get unsupported => _unsupported;

  static String key(MediaKind kind, int id) => '${kind.id}:$id';

  SeerrRequestIntent? peek(MediaKind kind, int id) => _states[key(kind, id)]?.$1;

  Future<void> load(MediaKind kind, int id) {
    if (_closed || _unsupported || (kind != MediaKind.movie && kind != MediaKind.show) || id < 1) return Future.value();
    final identity = key(kind, id);
    final cached = _states[identity];
    if (cached != null && DateTime.now().difference(cached.$2) < const Duration(minutes: 2)) return Future.value();
    if (_waiting[identity] case final pending?) return pending.future;
    final pending = Completer<void>();
    _waiting[identity] = pending;
    _keys[identity] = (kind, id);
    _flushTimer ??= Timer(const Duration(milliseconds: 25), _flush);
    return pending.future;
  }

  void invalidate(MediaKind kind, int id) {
    final identity = key(kind, id);
    _epochs[identity] = (_epochs[identity] ?? 0) + 1;
    _states.remove(identity);
    final pending = _waiting[identity];
    if (pending != null && !_closed) {
      unawaited(pending.future.then((_) => load(kind, id)));
    }
    if (!_closed) notifyListeners();
  }

  void invalidateAll() {
    if (_closed) return;
    final recent = _states.values.toList().reversed.take(40).map((entry) => (entry.$1.kind, entry.$1.tmdbId)).toList();
    for (final identity in _states.keys) {
      _epochs[identity] = (_epochs[identity] ?? 0) + 1;
    }
    _states.clear();
    notifyListeners();
    for (final (kind, id) in recent) {
      unawaited(load(kind, id));
    }
  }

  Future<void> refresh(MediaKind kind, int id) {
    invalidate(kind, id);
    return load(kind, id);
  }

  /// Legacy sheet-only callers never probed this endpoint. A mutation should
  /// refresh a visible title, not initiate a new optional API on an older
  /// server merely because its sheet submitted a request.
  void refreshIfObserved(MediaKind kind, int id) {
    if (_unsupported || (!_states.containsKey(key(kind, id)) && !_waiting.containsKey(key(kind, id)))) return;
    invalidate(kind, id);
    unawaited(load(kind, id));
  }

  void _flush() {
    _flushTimer = null;
    if (_closed || _keys.isEmpty) return;
    final entries = _keys.entries.take(40).toList();
    for (final entry in entries) {
      _keys.remove(entry.key);
    }
    if (_keys.isNotEmpty) _flushTimer = Timer(const Duration(milliseconds: 25), _flush);
    final epochs = {for (final entry in entries) entry.key: _epochs[entry.key] ?? 0};
    unawaited(_fetch(entries, epochs));
  }

  Future<void> _fetch(List<MapEntry<String, (MediaKind, int)>> entries, Map<String, int> epochs) async {
    try {
      final results = await client.getRequestIntents([for (final e in entries) e.value]);
      if (_closed) return;
      for (final result in results) {
        final identity = key(result.kind, result.tmdbId);
        if (epochs[identity] == (_epochs[identity] ?? 0)) {
          _states.remove(identity);
          _states[identity] = (result, DateTime.now());
          if (_states.length > 250) _states.remove(_states.keys.first);
        }
      }
      notifyListeners();
    } on SeerrApiException catch (e) {
      if (e.statusCode == 404) _unsupported = true; // Older Overseerr/Jellyseerr instances.
      if (!_closed && e.statusCode != 404) appLogger.d('Seerr: request intent state unavailable', error: e);
    } catch (e) {
      if (!_closed) appLogger.d('Seerr: request intent state unavailable', error: e);
    } finally {
      for (final entry in entries) {
        _waiting.remove(entry.key)?.complete();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _flushTimer?.cancel();
    for (final pending in _waiting.values) {
      if (!pending.isCompleted) pending.complete();
    }
    _waiting.clear();
    _keys.clear();
    _states.clear();
    super.dispose();
  }
}
