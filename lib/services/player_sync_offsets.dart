import 'dart:async';

import 'package:flutter/foundation.dart';

import '../media/media_item.dart';
import '../mpv/mpv.dart';
import '../mpv/player/player_media_session_identity.dart';
import '../profiles/active_profile_provider.dart';
import '../utils/app_logger.dart';
import '../utils/latest_async_write.dart';
import 'library_sync_correction.dart';
import 'scoped_player_prefs.dart';

/// Shared with manual sync controls: restoration waits for a native write that
/// was already dispatched, then supersedes any queued stale edit.
final Expando<LatestAsyncWrite<String>> playerSyncWrites = Expando<LatestAsyncWrite<String>>();

class LibrarySyncBinding {
  LibrarySyncBinding._(this.owner, this.property, this.key, this.stamp, this.generation, this.profileId);
  final PlayerSyncOffsets owner;
  final String property, key, stamp, profileId;
  final int generation;
  bool get current => owner._bindingCurrent && generation == owner._bindingGeneration &&
      owner._source?.selectionStamp(owner._player) == stamp;
  bool get saved => current && LibrarySyncCorrections.read(profileId, key) != null;
  void checkCurrent() {
    if (!current) throw StateError('The playback copy, profile or selected tracks changed.');
  }
  Future<void> save({int? delayMs, double? rate}) async {
    checkCurrent();
    await LibrarySyncCorrections.write(profileId, key, LibrarySyncValue(
      delayMs: delayMs ?? owner._valueFor(property),
      rate: property == PlayerSyncOffsets.subtitleProperty ? rate ?? owner.subtitleRate : 1,
    ), checkCurrent: checkCurrent);
    if (current) owner._notifyBindings();
  }
  Future<void> forget() async {
    checkCurrent();
    await LibrarySyncCorrections.write(profileId, key, null, checkCurrent: checkCurrent);
    checkCurrent();
    await owner._refreshCorrections(force: true, onlyProperty: property);
    if (current) owner._notifyBindings();
  }
}

/// The audio, primary-subtitle, and secondary-subtitle sync offsets one video
/// [Player] is applying, in milliseconds, plus MPV's primary subtitle timestamp
/// multiplier used for gradual drift correction.
///
/// Both backends keep `audio-delay`/`sub-delay` across an in-place item swap,
/// so the native value outlives the item it was tuned for — and under the
/// "Don't save" scope it is stored nowhere else. This record, not the stored
/// pref, is what the player UI shows and what an item change compares against.
///
/// Attached to the player instance: a new player starts with no delay, and
/// the record goes away with the player.
final class PlayerSyncOffsets extends ChangeNotifier {
  PlayerSyncOffsets._(this._player);

  factory PlayerSyncOffsets.of(Player player) => _byPlayer[player] ??= PlayerSyncOffsets._(player);

  static final Expando<PlayerSyncOffsets> _byPlayer = Expando<PlayerSyncOffsets>('PlayerSyncOffsets');

  static const audioProperty = 'audio-delay';
  static const subtitleProperty = 'sub-delay';
  static const secondarySubtitleProperty = 'secondary-sub-delay';
  static const subtitleRateProperty = 'sub-speed';

  final Player _player;
  int _audioMs = 0;
  int _subtitleMs = 0;
  int _secondarySubtitleMs = 0;
  double _subtitleRate = 1.0;
  LibrarySyncSource? _source;
  MediaItem? _item;
  ActiveProfileProvider? _profiles;
  String? _profileId;
  int? _mediaGeneration;
  int _bindingGeneration = 0;
  String? _selectionStamp;
  final Map<String, String?> _appliedKeys = {};
  bool Function()? _isCurrent;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  bool get _bindingCurrent => _source != null && !_player.disposed && _isCurrent?.call() == true &&
      _profileId != null && _profiles?.activeId == _profileId &&
      (_mediaGeneration == null || (_player is PlayerMediaSessionIdentity &&
        (_player as PlayerMediaSessionIdentity).mediaSessionGeneration == _mediaGeneration));

  /// Rebound only after a successful media open. A source with insufficient
  /// version/part identity has ordinary scoped timing but no exact-copy save.
  void bindLibrary({required LibrarySyncSource? source, required MediaItem item,
      required ActiveProfileProvider profiles, required bool Function() isCurrent}) {
    unbindLibrary();
    if (source == null) {
      unawaited(applyFor(item).catchError((Object error, StackTrace stack) {
        appLogger.w('Could not restore scoped playback timing', error: error, stackTrace: stack);
      }));
      return;
    }
    _source = source; _item = item; _profiles = profiles; _profileId = profiles.activeId;
    _isCurrent = isCurrent;
    _mediaGeneration = _player is PlayerMediaSessionIdentity
        ? (_player as PlayerMediaSessionIdentity).mediaSessionGeneration : null;
    void refresh(Object? _) => _queueRefresh();
    _subscriptions.add(_player.streams.track.listen(refresh));
    _subscriptions.add(_player.streams.tracks.listen(refresh));
    profiles.addListener(_profileChanged);
    _queueRefresh();
  }

  void unbindLibrary() {
    ++_bindingGeneration;
    _profiles?.removeListener(_profileChanged);
    for (final subscription in _subscriptions) { unawaited(subscription.cancel()); }
    _subscriptions.clear();
    _source = null; _item = null; _profiles = null; _profileId = null;
    _isCurrent = null; _selectionStamp = null;
    _appliedKeys.clear();
  }

  void _profileChanged() {
    // Do not inherit another viewer's saved overrides in an existing player.
    if (_profiles?.activeId == _profileId) return;
    final item = _item;
    unbindLibrary();
    if (item != null && !_player.disposed) {
      unawaited(applyFor(item).catchError((Object error, StackTrace stack) {
        appLogger.w('Could not clear profile-bound playback timing', error: error, stackTrace: stack);
      }));
    }
    notifyListeners();
  }

  LibrarySyncBinding? binding(String property) {
    if (!_bindingCurrent || !const [audioProperty, subtitleProperty, secondarySubtitleProperty].contains(property)) {
      return null;
    }
    final key = _source!.key(_player, property);
    if (key == null) return null;
    return LibrarySyncBinding._(this, property, key, _source!.selectionStamp(_player), _bindingGeneration, _profileId!);
  }

  void _queueRefresh() {
    unawaited(_refreshCorrections().catchError((Object error, StackTrace stack) {
      appLogger.w('Could not restore copy-bound playback timing', error: error, stackTrace: stack);
    }));
  }

  void _notifyBindings() => notifyListeners();

  Future<void> settleEdits(String property) =>
      playerSyncWrites[_player]?.settled(property) ?? Future<void>.value();

  Future<void> _refreshCorrections({bool force = false, String? onlyProperty}) async {
    if (!_bindingCurrent) return;
    final stamp = _source!.selectionStamp(_player);
    if (!force && stamp == _selectionStamp) return;
    _selectionStamp = stamp;
    final generation = _bindingGeneration, item = _item!;
    bool selectionCurrent() => _bindingCurrent && generation == _bindingGeneration &&
        _source!.selectionStamp(_player) == stamp;
    final writes = playerSyncWrites[_player] ??= LatestAsyncWrite<String>();
    final futures = <Future<bool>>[];
    for (final property in [audioProperty, subtitleProperty,
        if (_player.supportsSecondarySubtitles) secondarySubtitleProperty]) {
      if (onlyProperty != null && onlyProperty != property) continue;
      final selected = binding(property);
      if (!force && _appliedKeys.containsKey(property) && _appliedKeys[property] == selected?.key) continue;
      // Track requested keys, including queued restoration. Returning A→B→A
      // must enqueue A even when B has not finished writing its native value.
      _appliedKeys[property] = selected?.key;
      bool current() => _bindingCurrent && generation == _bindingGeneration &&
          _source!.key(_player, property) == selected?.key;
      final value = selected == null ? null : LibrarySyncCorrections.read(_profileId!, selected.key);
      final delay = value?.delayMs ?? ScopedPlayerPrefs.resolve(switch (property) {
        audioProperty => ScopedPlayerPrefs.audioSyncOffset,
        subtitleProperty => ScopedPlayerPrefs.subtitleSyncOffset,
        _ => ScopedPlayerPrefs.secondarySubtitleSyncOffset,
      }, item);
      final rate = value?.rate ?? ScopedPlayerPrefs.resolve(ScopedPlayerPrefs.subtitleSyncRate, item);
      final token = writes.begin(property);
      futures.add(writes.commitIfLatest(property, token, () async {
        if (!current()) return;
        await _apply(property, delay, force: true, isCurrent: current);
        if (current() && property == subtitleProperty && _player.supportsSubtitleStepSync) {
          await _applySubtitleRate(rate, force: true, isCurrent: current);
        }
      }));
    }
    await Future.wait(futures);
    if (selectionCurrent()) notifyListeners();
  }

  int get audioMs => _audioMs;
  int get subtitleMs => _subtitleMs;
  int get secondarySubtitleMs => _secondarySubtitleMs;
  double get subtitleRate => _subtitleRate;

  /// Make the player apply [item]'s scope-resolved offsets.
  ///
  /// Every item starts from its own resolved value, so a change made under
  /// "Don't save" stays with the item it was made on instead of following the
  /// player into the next episode (#2449). An offset the player already
  /// applies is reasserted at a source boundary to retire in-flight old edits.
  Future<void> applyFor(MediaItem item) async {
    if (_bindingCurrent && _item?.globalKey == item.globalKey) {
      await _refreshCorrections(force: true);
      return;
    }
    final generation = _bindingGeneration;
    final media = _player is PlayerMediaSessionIdentity
        ? (_player as PlayerMediaSessionIdentity).mediaSessionGeneration : null;
    bool current() => !_player.disposed && generation == _bindingGeneration &&
        (media == null || (_player as PlayerMediaSessionIdentity).mediaSessionGeneration == media);
    final writes = playerSyncWrites[_player] ??= LatestAsyncWrite<String>();
    final futures = <Future<bool>>[];
    for (final property in [audioProperty, subtitleProperty,
        if (_player.supportsSecondarySubtitles) secondarySubtitleProperty]) {
      final token = writes.begin(property);
      futures.add(writes.commitIfLatest(property, token, () async {
        if (!current()) return;
        await _apply(property, ScopedPlayerPrefs.resolve(switch (property) {
          audioProperty => ScopedPlayerPrefs.audioSyncOffset,
          subtitleProperty => ScopedPlayerPrefs.subtitleSyncOffset,
          _ => ScopedPlayerPrefs.secondarySubtitleSyncOffset,
        }, item), force: true, isCurrent: current);
        if (current() && property == subtitleProperty && _player.supportsSubtitleStepSync) {
          await _applySubtitleRate(ScopedPlayerPrefs.resolve(ScopedPlayerPrefs.subtitleSyncRate, item),
            force: true, isCurrent: current);
        }
      }));
    }
    await Future.wait(futures);
  }

  Future<void> _applySubtitleRate(double rate, {bool force = false, bool Function()? isCurrent}) async {
    if (!force && (rate - _subtitleRate).abs() < 0.000001) return;
    await _player.setProperty(subtitleRateProperty, rate.toStringAsFixed(6));
    if (isCurrent?.call() ?? true) recordSubtitleRate(rate);
  }

  /// Record a subtitle timestamp multiplier already written to the player.
  void recordSubtitleRate(double rate) {
    if (!rate.isFinite ||
        rate < ScopedPlayerPrefs.minimumSubtitleSyncRate ||
        rate > ScopedPlayerPrefs.maximumSubtitleSyncRate) {
      throw ArgumentError.value(rate, 'rate', 'outside the supported subtitle sync range');
    }
    if ((_subtitleRate - rate).abs() < 0.000001) return;
    _subtitleRate = rate;
    notifyListeners();
  }

  int _valueFor(String property) => switch (property) {
      audioProperty => _audioMs,
      subtitleProperty => _subtitleMs,
      secondarySubtitleProperty => _secondarySubtitleMs,
      _ => throw ArgumentError.value(property, 'property', 'not a sync offset property'),
    };

  Future<void> _apply(String property, int offsetMs, {bool force = false, bool Function()? isCurrent}) async {
    final applied = _valueFor(property);
    if (!force && offsetMs == applied) return;
    await _player.setProperty(property, (offsetMs / 1000.0).toString());
    if (isCurrent?.call() ?? true) recordApplied(property, offsetMs);
  }

  /// Record an offset the caller has already written to the player.
  void recordApplied(String property, int offsetMs) {
    switch (property) {
      case audioProperty:
        if (_audioMs == offsetMs) return;
        _audioMs = offsetMs;
      case subtitleProperty:
        if (_subtitleMs == offsetMs) return;
        _subtitleMs = offsetMs;
      case secondarySubtitleProperty:
        if (_secondarySubtitleMs == offsetMs) return;
        _secondarySubtitleMs = offsetMs;
      default:
        throw ArgumentError.value(property, 'property', 'not a sync offset property');
    }
    notifyListeners();
  }
}
