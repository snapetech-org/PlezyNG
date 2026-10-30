import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

import '../sources/source_controller.dart';
import '../sources/sync/sync_document.dart';
import '../sources/sync/sync_store.dart';
import 'subtitle_cloud_sync.dart';
import 'subtitle_portable_defaults.dart';
import 'subtitle_selection_rules.dart';

enum SubtitleDefaultsSyncState { off, waiting, running, synchronized, conflict, unavailable }

/// Explicitly opted-in synchronization while the app is active. Only saved
/// defaults are imported; current captions and title overrides are untouched.
/// A common baseline, not wall-clock order, decides whether an edit is safe.
class SubtitleDefaultsAutoSync extends ChangeNotifier with WidgetsBindingObserver {
  SubtitleDefaultsAutoSync() {
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => refresh());
  }
  static const _key = 'subtitle-defaults-auto-sync.v1';
  SourceController? _sources;
  Timer? _timer;
  Future<void>? _running;
  bool _disposed = false, _foreground = true, _configuring = false;
  int _epoch = 0;
  String? _owner;
  bool enabled = false;
  SubtitleDefaultsSyncState state = SubtitleDefaultsSyncState.off;

  static String digest(SubtitlePortableDefaults value) => sha256.convert(utf8.encode(
    canonicalSyncJson(jsonDecode(utf8.decode(value.encode()))))).toString();
  static String _destination(String source, String folder, String code) => sha256.convert(
    utf8.encode(canonicalSyncJson([source, folder, code]))).toString();

  void bind(SourceController sources) {
    final owner = '${sources.profileId}:${sources.generation}:${sources.syncConfig?.sourceId}:${sources.syncConfig?.folder}';
    if (identical(sources, _sources) && owner == _owner) return;
    _sources = sources; _owner = owner; _epoch++;
    enabled = false; state = SubtitleDefaultsSyncState.waiting;
    // Proxy-provider updates happen during build. Defer notification and IO.
    scheduleMicrotask(refresh);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (!_foreground) _epoch++;
    else refresh();
  }

  void _status(SubtitleDefaultsSyncState next) {
    if (_disposed) return;
    state = next; notifyListeners();
  }

  void refresh() {
    if (_disposed || !_foreground || _configuring || _sources == null || _running != null) return;
    final startedEpoch = _epoch;
    final future = _synchronize();
    _running = future;
    unawaited(future.whenComplete(() {
      if (identical(_running, future)) _running = null;
      if (!_disposed && _foreground && startedEpoch != _epoch) scheduleMicrotask(refresh);
    }));
  }

  /// A changed pairing or source requires a fresh opt-in. Retire any in-flight
  /// cycle before replacing its journal so it cannot re-enable an old policy.
  Future<void> configure(bool allow, {required String profile}) async {
    if (_configuring) throw StateError('Caption synchronization is already being configured.');
    _configuring = true;
    try {
      _epoch++;
      final running = _running;
      if (running != null) await running;
      final sources = _sources;
      if (_disposed || sources == null || sources.profileId != profile) throw StateError('Profile changed.');
      await sources.ready;
      final epoch = _epoch, generation = sources.generation;
      void check() {
        if (_disposed || epoch != _epoch || sources.profileId != profile || SubtitleSelectionRules.activeProfileId != profile) {
          throw StateError('Caption synchronization changed.');
        }
        sources.requireSession(generation);
      }
      check();
      Map<String, dynamic> value = {'enabled': false};
      if (allow) {
        final config = sources.syncConfig;
        final code = await SubtitleCloudSync.pairedCode(sources.repository, SubtitleCloudSync.defaultsIdentity(profile));
        check();
        if (config == null || code == null || !ProviderSyncStore.supports(sources.adapter(config.sourceId).source.kind)) {
          throw StateError('Pair caption defaults with a supported cloud folder first.');
        }
        value = {'enabled': true, 'destination': _destination(config.sourceId, config.folder, code), 'baseline': null};
      }
      await sources.repository.savePreference(profile, _key, value); check();
      enabled = allow; _status(allow ? SubtitleDefaultsSyncState.waiting : SubtitleDefaultsSyncState.off);
    } finally {
      _configuring = false;
      refresh();
    }
  }

  Future<void> _synchronize() async {
    final sources = _sources!, epoch = _epoch, profile = _sources!.profileId, generation = _sources!.generation;
    if (profile == null) { _status(SubtitleDefaultsSyncState.off); return; }
    void check() {
      if (_disposed || !_foreground || epoch != _epoch || !identical(sources, _sources) || sources.profileId != profile ||
          SubtitleSelectionRules.activeProfileId != profile) throw StateError('Caption synchronization retired.');
      sources.requireSession(generation);
    }
    try {
      await sources.ready; check();
      final journal = await sources.repository.preference(profile, _key); check();
      enabled = journal['enabled'] == true;
      if (!enabled) { _status(SubtitleDefaultsSyncState.off); return; }
      final config = sources.syncConfig, identity = SubtitleCloudSync.defaultsIdentity(profile);
      final code = await SubtitleCloudSync.pairedCode(sources.repository, identity); check();
      if (config == null || code == null || journal['destination'] != _destination(config.sourceId, config.folder, code)) {
        _status(SubtitleDefaultsSyncState.unavailable); return;
      }
      final adapter = sources.adapter(config.sourceId);
      if (!ProviderSyncStore.supports(adapter.source.kind)) { _status(SubtitleDefaultsSyncState.unavailable); return; }
      bool current() { try { check(); return true; } catch (_) { return false; } }
      final service = SubtitleCloudSync(repository: sources.repository, identity: identity, defaults: true,
        store: ProviderSyncStore(adapter, folder: config.folder, check: check), code: code, check: check);
      _status(SubtitleDefaultsSyncState.running);
      final local = SubtitlePortableDefaults.capture(profile, current), localDigest = digest(local);
      final choices = await service.synchronize(); check();
      if (choices.length > 1) { _status(SubtitleDefaultsSyncState.conflict); return; }
      final baseline = journal['baseline'];
      final remote = choices.isEmpty ? null : choices.single;
      if (digest(SubtitlePortableDefaults.capture(profile, current)) != localDigest) {
        _status(SubtitleDefaultsSyncState.waiting); return;
      }
      String accepted;
      if (remote == null || remote.digest == baseline && localDigest != baseline) {
        final published = await service.synchronize(publishDefaults: local); check();
        if (published.length != 1 || published.single.digest != localDigest) {
          _status(SubtitleDefaultsSyncState.conflict); return;
        }
        accepted = localDigest;
      } else if (remote.digest == localDigest) {
        await service.acknowledgeDefaults(remote); check();
        accepted = localDigest;
      } else if (baseline is String && localDigest == baseline) {
        final incoming = await service.downloadDefaults(remote); check();
        if (digest(incoming) != remote.digest) throw const FormatException('Caption preset digest mismatch.');
        // Each existing settings owner compares the saved value when its
        // serialized write actually runs. Concurrent manual changes win.
        await incoming.importLane(0, profile: profile, isCurrent: current, expected: local); check();
        await incoming.importLane(1, profile: profile, isCurrent: current, expected: local); check();
        await incoming.importRoles(profile: profile, isCurrent: current, expected: local); check();
        if (digest(SubtitlePortableDefaults.capture(profile, current)) != remote.digest) {
          _status(SubtitleDefaultsSyncState.conflict); return;
        }
        await service.acknowledgeDefaults(remote); check();
        accepted = remote.digest;
      } else {
        // First pairing with different defaults or concurrent local/remote
        // edits requires the existing preview and explicit conflict choice.
        _status(SubtitleDefaultsSyncState.conflict); return;
      }
      check();
      await sources.repository.updatePreferenceAtomically(profile, _key, (current) {
        check();
        if (canonicalSyncJson(current) != canonicalSyncJson(journal)) throw StateError('Caption synchronization policy changed.');
        return {...journal, 'baseline': accepted};
      }); check();
      _status(SubtitleDefaultsSyncState.synchronized);
    } catch (_) {
      if (!_disposed && epoch == _epoch) _status(SubtitleDefaultsSyncState.unavailable);
    }
  }

  @override
  void dispose() {
    _disposed = true; _epoch++; _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this); super.dispose();
  }
}
