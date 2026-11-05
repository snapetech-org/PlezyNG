import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import '../services/connectivity_probe.dart';
import '../services/new_episode_notification_service.dart';
import '../utils/app_logger.dart';
import 'podcast_library.dart';
import 'podcast_metadata.dart';
import 'source_controller.dart';
import 'source_models.dart';

final class PodcastPolicy {
  const PodcastPolicy({this.keepLatest = 0, this.removeFinishedDays = 0, this.notify = false, this.wifiOnly = true});
  final int keepLatest, removeFinishedDays;
  final bool notify, wifiOnly;
  factory PodcastPolicy.fromJson(Map<String, dynamic> value) => PodcastPolicy(
    keepLatest: (sourceInt(value['keepLatest']) ?? 0).clamp(0, 50).toInt(),
    removeFinishedDays: (sourceInt(value['removeFinishedDays']) ?? 0).clamp(0, 365).toInt(),
    notify: value['notify'] == true, wifiOnly: value['wifiOnly'] != false);
  Map<String, dynamic> toJson() => {'keepLatest': keepLatest, 'removeFinishedDays': removeFinishedDays,
    'notify': notify, 'wifiOnly': wifiOnly};
}

/// Foreground feed discovery with durable baselines and per-show download
/// ownership. Existing native download jobs can continue under their own OS
/// scheduler; this worker never promises closed-app feed polling on a TV.
final class PodcastAutomation with WidgetsBindingObserver {
  PodcastAutomation(this.sources, {required this.onUpdate}) {
    try { WidgetsBinding.instance.addObserver(this); _observing = true; } on Object { /* headless source owner */ }
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => unawaited(refresh()));
  }
  final SourceController sources;
  final void Function() onUpdate;
  int revision = 0;
  int lastFailedCount = 0;
  final Set<String> _manualClaims = {};
  bool _manualClaimsOverflow = false;
  Timer? _timer;
  Future<void>? _pass;
  bool _disposed = false, _observing = false, _foreground = true;
  static const _dailyBytes = 512 * 1024 * 1024;
  static String policyKey(String source) => 'podcast-policy-v1:$source';
  static String _stateKey(String source) => 'podcast-automation-v1:$source';

  Future<PodcastPolicy> policy(String source) async {
    sources.requireSession();
    final epoch = sources.generation, profile = sources.profileId!;
    final value = await sources.repository.preference(profile, policyKey(source));
    sources.requireSession(epoch);
    return PodcastPolicy.fromJson(value);
  }
  Future<void> savePolicy(String source, PodcastPolicy policy) async {
    sources.requireSession();
    final epoch = sources.generation, profile = sources.profileId!;
    if (!sources.sources.any((s) => s.id == source && s.kind == FileSourceKind.podcastRss)) {
      throw const SourceException(SourceFailure.unavailable);
    }
    await sources.repository.savePreference(profile, policyKey(source), policy.toJson());
    sources.requireSession(epoch);
    unawaited(refresh(force: true));
  }

  static String _manualKey(String key) => 'podcast-manual-file-v1:${sourceDigest(key)}';
  Future<void> protectManualDownload(SourceEntry entry, PublicationFile file) async {
    sources.requireSession();
    final epoch = sources.generation, profile = sources.profileId!;
    final key = sources.downloads.key(entry.sourceId, file);
    if (_manualClaims.length < 10000) { _manualClaims.add(sourceKey(profile, key)); }
    else { _manualClaimsOverflow = true; }
    await sources.repository.savePreference(profile, _manualKey(key), {'manual': true});
    sources.requireSession(epoch);
  }
  bool _manualClaimed(String profile, String key) => _manualClaimsOverflow || _manualClaims.contains(sourceKey(profile, key));
  Future<bool> _manuallyProtected(String profile, String key) async => _manualClaimed(profile, key) ||
      (await sources.repository.preference(profile, _manualKey(key)))['manual'] == true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) unawaited(refresh());
  }

  Future<void> refresh({bool force = false}) {
    if (_disposed || !_foreground || sources.blocked || sources.loading || sources.profileId == null) return Future.value();
    if (_pass != null) return _pass!;
    final epoch = sources.generation;
    return _pass = _refresh(epoch, force: force).catchError((Object error) {
      if (sources.current(epoch)) appLogger.w('Podcast discovery stopped (${error.runtimeType})');
    }).whenComplete(() {
      _pass = null;
      if (!_disposed && sources.generation != epoch) unawaited(refresh());
    });
  }

  Future<void> _refresh(int epoch, {required bool force}) async {
    final profile = sources.profileId!;
    lastFailedCount = 0;
    void check() {
      sources.requireSession(epoch);
      if (_disposed || !_foreground) throw const SourceException(SourceFailure.cancelled);
    }
    final connection = await ConnectivityProbe.check();
    check();
    final unmetered = connection.contains(ConnectivityResult.wifi) || connection.contains(ConnectivityResult.ethernet);
    // Rotate bounded batches so a large subscription list does not monopolize
    // the network and every show eventually receives a turn.
    final feeds = sources.sources.where((s) => s.kind == FileSourceKind.podcastRss).toList();
    final rotation = await sources.repository.preference(profile, 'podcast-poll-rotation-v1');
    check();
    final start = (sourceInt(rotation['offset']) ?? 0) % (feeds.isEmpty ? 1 : feeds.length);
    for (var i = 0; i < feeds.length && i < 50; i++) {
      check();
      final source = feeds[(start + i) % feeds.length];
      try {
        final rules = await policy(source.id);
        var state = await sources.repository.preference(profile, _stateKey(source.id));
        check();
        final now = DateTime.now();
        final last = sourceInt(state['lastRefresh']) ?? 0;
        if (!force && now.millisecondsSinceEpoch - last < const Duration(minutes: 25).inMilliseconds) continue;
        await sources.browse(source.id);
        check();
        final page = await sources.browse(source.id, parent: 'podcast:episodes');
        check();
        final episodes = page.entries.where((e) => !e.isFolder).toList()..sort((a, b) =>
          (podcastPublishedAt(b)?.millisecondsSinceEpoch ?? 0).compareTo(podcastPublishedAt(a)?.millisecondsSinceEpoch ?? 0));
        final seen = (state['seen'] as List? ?? const []).whereType<String>().toSet();
        final hasBaseline = state.containsKey('seen');
        final fresh = episodes.where((episode) => !seen.contains(episode.id)).toList();
        if (hasBaseline && rules.notify && fresh.isNotEmpty) {
          await NewEpisodeNotificationService.instance.notifyPodcastEpisode(profileId: profile, sourceId: source.id,
            show: source.name, episode: fresh.first.title, isCurrent: () => sources.current(epoch) && !sources.blocked);
        }
        check();
        final managedKeys = sourceMap(state['managed']).values.map((value) => sourceMap(value)['entry']).whereType<String>();
        final progress = await sources.repository.progressForEntries(profile, {...episodes.map((e) => e.key), ...managedKeys});
        final latest = <String, PublicationProgress>{};
        for (final value in progress) {
          if ((latest[value.entryKey]?.updatedAt ?? -1) < value.updatedAt) latest[value.entryKey] = value;
        }
        final candidates = episodes.where((entry) => latest[entry.key]?.finished != true).take(rules.keepLatest).toList();
        final desired = candidates.map((e) => e.key).toSet();
        final managed = <String, dynamic>{...sourceMap(state['managed'])};
        final byKey = {for (final episode in episodes) episode.key: episode};
        for (final record in managed.entries.toList()) {
          check();
          final data = sourceMap(record.value), entryKey = data['entry'] as String?;
          if (entryKey == null) continue;
          final entry = byKey[entryKey];
          if (entry == null && sources.activeProgressKeys.isNotEmpty) continue;
          if (entry != null && sources.activeProgressKeys.contains(PodcastLibrary.seed(entry).key)) continue;
          final currentProgress = latest[entryKey];
          if (currentProgress != null && sources.activeProgressKeys.contains(currentProgress.key)) continue;
          final finishedExpired = rules.removeFinishedDays > 0 && currentProgress?.finished == true &&
              now.millisecondsSinceEpoch - currentProgress!.updatedAt >= Duration(days: rules.removeFinishedDays).inMilliseconds;
          final outside = rules.keepLatest > 0 && !desired.contains(entryKey) && (currentProgress?.fraction ?? 0) == 0;
          if (!finishedExpired && !outside) continue;
          if (await _manuallyProtected(profile, record.key)) { managed.remove(record.key); continue; }
          check();
          final file = PublicationFile.fromJson(sourceMap(data['file']));
          // Only files claimed by this automation journal are eligible. A
          // manual download discovered before claiming is never enrolled.
          await sources.downloads.cancelAndWait(profile, source.id, file);
          check();
          await sources.downloads.remove(profile, source.id, file,
            shouldRemove: () => !_disposed && _foreground && sources.current(epoch) && !sources.blocked &&
                sources.activeProgressKeys.isEmpty && !_manualClaimed(profile, record.key));
          if (await sources.repository.download(profile, record.key) == null) managed.remove(record.key);
        }
        final day = now.toUtc().toIso8601String().substring(0, 10);
        var used = state['day'] == day ? sourceInt(state['bytes']) ?? 0 : 0;
        if (rules.keepLatest > 0 && (!rules.wifiOnly || unmetered)) {
          for (final episode in candidates) {
            check();
            for (final file in episode.files.where((f) => !f.sampleOnly)) {
              final length = file.size;
              if (length == null || length <= 0 || length > _dailyBytes - used) continue;
              if (await sources.downloads.local(profile, source.id, file) != null) continue;
              check();
              final key = sources.downloads.key(source.id, file);
              if (await _manuallyProtected(profile, key)) continue;
              check();
              final existing = await sources.repository.download(profile, key);
              if (existing != null && !managed.containsKey(key)) continue;
              if (!managed.containsKey(key) && managed.length >= 2000) continue;
              managed[key] = {'entry': episode.key, 'file': file.toJson()};
              state = {...state, 'managed': managed};
              await sources.repository.savePreference(profile, _stateKey(source.id), state);
              check();
              try {
                await sources.content(episode, file, automaticPodcast: true);
                used += length;
                check();
                state = {...state, 'managed': managed, 'day': day, 'bytes': used};
                await sources.repository.savePreference(profile, _stateKey(source.id), state);
              } on SourceException catch (error) {
                if (error.reason == SourceFailure.cancelled) rethrow;
                break;
              }
            }
          }
        }
        check();
        await sources.repository.savePreference(profile, _stateKey(source.id), {
          'lastRefresh': now.millisecondsSinceEpoch, 'seen': episodes.map((e) => e.id).take(2000).toList(),
          'managed': managed, 'day': day, 'bytes': used,
        });
      } on SourceException catch (error) {
        if (error.reason == SourceFailure.cancelled) rethrow;
        lastFailedCount++;
        appLogger.w('Podcast discovery could not refresh one show (${error.reason.name})');
      } on Object catch (error) {
        lastFailedCount++;
        appLogger.w('Podcast discovery could not refresh one show (${error.runtimeType})');
      }
    }
    check();
    await sources.repository.savePreference(profile, 'podcast-poll-rotation-v1', {'offset': start + 50});
    check();
    revision++;
    onUpdate();
  }

  Future<void> get settled => _pass ?? Future.value();
  void dispose() {
    _disposed = true; _timer?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
  }
}
