import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'adapters/podcast_rss_source.dart';
import 'gpodder_client.dart';
import 'podcast_library.dart';
import 'podcast_opml.dart';
import 'source_controller.dart';
import 'source_models.dart';

enum PodcastSyncPhase { disabled, idle, running, complete, failed }

/// Independent gpodder acknowledgments never consume the publication cloud
/// outbox. A network success acknowledges exactly the captured local revision.
final class PodcastSync {
  PodcastSync(this.sources, {required this.onUpdate});
  final SourceController sources;
  final void Function() onUpdate;
  static const configKey = 'podcast-gpodder-config-v1';
  GpodderClient? _client;
  Future<void>? _pass;
  int _generation = 0;
  PodcastSyncPhase phase = PodcastSyncPhase.disabled;
  SourceFailure? failure;
  int conflictCount = 0;
  int pendingCount = 0;

  static String account(GpodderConfig config) =>
      sourceDigest('${config.endpoint}\u0000${config.username}\u0000${config.device}');
  static String _stateKey(GpodderConfig config) => 'podcast-gpodder-state-v1:${account(config)}';
  static String progressHash(PublicationProgress value) =>
      sourceDigest(jsonEncode([value.positionMs ~/ 1000, value.finished]));

  Future<GpodderConfig?> config() async {
    await sources.ready;
    sources.requireSession();
    final epoch = sources.generation;
    final value = await sources.repository.privatePreference(sources.profileId!, configKey);
    sources.requireSession(epoch);
    return value.isEmpty ? null : GpodderConfig.fromJson(value);
  }

  Future<void> configure(GpodderConfig? value) async {
    await sources.ready;
    sources.requireSession();
    final epoch = sources.generation, profile = sources.profileId!;
    cancel();
    if (value == null) {
      await sources.repository.forgetPreference(profile, configKey);
      sources.requireSession(epoch);
      onUpdate();
      return;
    }
    final client = GpodderClient(value, check: () => sources.requireSession(epoch));
    try {
      await client.verifyLogin();
    } finally {
      client.close();
    }
    sources.requireSession(epoch);
    await sources.repository.savePrivatePreference(profile, configKey, value.toJson());
    sources.requireSession(epoch);
    phase = PodcastSyncPhase.idle;
    onUpdate();
  }

  void cancel() {
    _generation++;
    _client?.close();
    _client = null;
    phase = PodcastSyncPhase.disabled;
    failure = null;
    conflictCount = 0;
    pendingCount = 0;
  }

  Future<void> get settled => _pass ?? Future.value();

  Future<void> run() {
    if (_pass != null) {
      return _pass!;
    }
    if (sources.blocked || sources.loading || sources.profileId == null) {
      return Future.value();
    }
    final epoch = sources.generation, generation = _generation;
    return _pass = _run(epoch, generation)
        .catchError((Object error) {
          if (sources.current(epoch) && generation == _generation) {
            phase = PodcastSyncPhase.failed;
            failure = error is SourceException ? error.reason : SourceFailure.unavailable;
            onUpdate();
          }
        })
        .whenComplete(() {
          _pass = null;
        });
  }

  Future<void> _save(String profile, String key, Map<String, dynamic> state, void Function() check) async {
    check();
    if (utf8.encode(jsonEncode(state)).length > 2 * 1024 * 1024) {
      throw const SourceException(SourceFailure.quotaExceeded);
    }
    await sources.repository.savePrivatePreference(profile, key, state);
    check();
  }

  Future<Map<String, FileSource>> _subscriptions(int epoch) async {
    final result = <String, FileSource>{};
    for (final source in List.of(sources.sources).where((s) => s.kind == FileSourceKind.podcastRss)) {
      final credentials = await sources.repository.credentials(source);
      sources.requireSession(epoch);
      if (credentials['feedUrl'] case final url?) {
        result[GpodderClient.validateUrl(url)] = source;
      }
    }
    return result;
  }

  static String _canonical(String url, Map<String, dynamic> aliases) {
    final visited = <String>{};
    for (var i = 0; i < 8; i++) {
      if (!visited.add(url)) {
        throw const SourceException(SourceFailure.invalidData);
      }
      final next = aliases[url];
      if (next is! String || next == url) {
        return url;
      }
      if (next.isEmpty) {
        throw const SourceException(SourceFailure.unsupported);
      }
      url = next;
    }
    throw const SourceException(SourceFailure.invalidData);
  }

  Future<SourceEntry?> _remoteEntry(
    String profile,
    String id,
    Map<String, dynamic> action,
    Map<String, dynamic> aliases,
    void Function() check,
  ) async {
    final direct = await sources.repository.podcastEntryBySyncIdentity(profile, id);
    check();
    if (direct != null) {
      return direct;
    }
    List<String> alternatives(String url) => [
      url,
      ...aliases.keys.where((candidate) => _canonical(candidate, aliases) == _canonical(url, aliases)).take(3),
    ];
    final matches = <String, SourceEntry>{};
    for (final feed in alternatives(action['podcast'] as String)) {
      for (final episode in alternatives(action['episode'] as String)) {
        final entry = await sources.repository.podcastEntryBySyncIdentity(profile, podcastSyncIdentity(feed, episode));
        check();
        if (entry != null) {
          matches[entry.key] = entry;
        }
      }
    }
    return matches.length == 1 ? matches.values.single : null;
  }

  Future<void> _run(int epoch, int generation) async {
    void check() {
      sources.requireSession(epoch);
      if (generation != _generation) {
        throw const SourceException(SourceFailure.cancelled);
      }
    }

    final configuration = await config();
    check();
    if (configuration == null) {
      phase = PodcastSyncPhase.disabled;
      onUpdate();
      return;
    }
    final profile = sources.profileId!, identity = account(configuration), key = _stateKey(configuration);
    final state = await sources.repository.privatePreference(profile, key);
    check();
    final aliases = sourceMap(state['aliases']);
    final conflicts = sourceMap(state['conflicts']);
    final pending = sourceMap(state['pending']);
    final pendingRemovals = (state['pendingRemovals'] as List? ?? const []).whereType<String>().toSet();
    var subscriptionSince = sourceInt(state['subscriptionSince']) ?? 0;
    var actionSince = sourceInt(state['actionSince']) ?? 0;
    phase = PodcastSyncPhase.running;
    failure = null;
    onUpdate();
    final client = GpodderClient(configuration, check: check);
    _client = client;
    try {
      if (configuration.subscriptions) {
        final local = await _subscriptions(epoch);
        final acknowledged = (state['subscriptions'] as List? ?? const []).whereType<String>().toSet();
        final add = local.keys.toSet().difference(acknowledged);
        final remove = acknowledged.difference(local.keys.toSet());
        final changes = await client.subscriptionChanges(subscriptionSince);
        check();
        final accepted = {...acknowledged};
        String localUrl(String remote) {
          final matches = {...local.keys, ...acknowledged}.where((url) => _canonical(url, aliases) == remote).toList();
          return matches.length == 1 ? matches.single : remote;
        }

        for (final remoteUrl in changes.add) {
          final url = localUrl(remoteUrl);
          if (remove.contains(url)) {
            continue;
          }
          if (!local.containsKey(url) && Uri.parse(url).scheme != 'https') {
            // Keep unsupported imports durable for review; never fetch an
            // insecure feed just because a remote account supplied its URL.
            pending['subscription:${sourceDigest(url)}'] = {'subscription': url};
            continue;
          }
          if (!local.containsKey(url)) {
            await sources.importPodcastSubscriptions([
              PodcastSubscription(title: Uri.parse(url).host, url: Uri.parse(url)),
            ], expectedGeneration: epoch);
            check();
          }
          accepted.add(url);
        }
        pendingRemovals.addAll(changes.remove.map(localUrl).where((url) => !add.contains(url)));
        for (final url in pendingRemovals.toList()) {
          check();
          if (sources.activeProgressKeys.isNotEmpty) {
            continue;
          }
          final source = local[url];
          if (source != null && sources.sources.any((s) => s.id == source.id)) {
            await sources.remove(source);
            check();
          }
          accepted.remove(url);
          pendingRemovals.remove(url);
        }
        if (add.isNotEmpty || remove.isNotEmpty) {
          final added = add.map((url) => _canonical(url, aliases)).toSet();
          final removed = remove.map((url) => _canonical(url, aliases)).toSet();
          final unchanged = added.intersection(removed);
          added.removeAll(unchanged);
          removed.removeAll(unchanged);
          final additions = added.toList(), removals = removed.toList();
          for (var offset = 0; offset < additions.length; offset += 100) {
            aliases.addAll(
              await client.publishSubscriptions(add: additions.skip(offset).take(100).toList(), remove: const []),
            );
            check();
          }
          for (var offset = 0; offset < removals.length; offset += 100) {
            aliases.addAll(
              await client.publishSubscriptions(add: const [], remove: removals.skip(offset).take(100).toList()),
            );
            check();
          }
          accepted.addAll(add);
          accepted.removeAll(remove);
        }
        state['subscriptions'] = accepted.toList();
        // Use the GET cursor, never the later POST cursor: a concurrent
        // remote change between those requests must still be fetched.
        subscriptionSince = changes.timestamp;
      }
      if (configuration.progress) {
        final incoming = await client.episodeActions(actionSince);
        check();
        for (final action in incoming.actions) {
          if (!const {'play', 'new'}.contains(action['action'])) {
            continue;
          }
          final feed = GpodderClient.validateUrl(action['podcast'] as String);
          final episode = GpodderClient.validateUrl(action['episode'] as String);
          final id = podcastSyncIdentity(feed, episode);
          final previous = sourceMap(pending[id]);
          final timestamp = _actionTime(action, incoming.timestamp);
          if (previous.isEmpty || timestamp >= _actionTime(previous, incoming.timestamp)) {
            pending[id] = {...action, '_received': incoming.timestamp};
          }
        }
        if (pending.length > 5000 || conflicts.length > 2000 || aliases.length > 5000) {
          throw const SourceException(SourceFailure.quotaExceeded);
        }
        for (final record in pending.entries.toList()) {
          check();
          final action = sourceMap(record.value);
          if (action.containsKey('subscription')) {
            continue;
          }
          final entry = await _remoteEntry(profile, record.key, action, aliases, check);
          if (entry == null) {
            continue;
          }
          final seed = PodcastLibrary.seed(entry, session: 'gpodder:${configuration.device}');
          final local = await sources.repository.progress(profile, seed.key) ?? seed;
          check();
          if (sources.activeProgressKeys.contains(local.key)) {
            continue;
          }
          final next = _fromAction(local, entry, action);
          final ack = await sources.repository.podcastSyncAck(profile, identity, local.key);
          check();
          if (progressHash(local) == progressHash(next)) {
            await sources.repository.acknowledgePodcastSync(profile, identity, local, progressHash(local));
            conflicts.remove(local.key);
          } else if (local.revision > 0 && (ack == null || progressHash(local) != ack.hash)) {
            conflicts[local.key] = {
              'entry': entry.key,
              'key': local.key,
              'localRevision': local.revision,
              'remote': next.toJson(),
              'remoteHash': progressHash(next),
            };
          } else {
            final saved = await sources.repository.saveProgress(profile, next, kind: 'gpodder-import');
            await sources.repository.acknowledgePodcastSync(profile, identity, saved, progressHash(saved));
            conflicts.remove(local.key);
          }
          pending.remove(record.key);
        }
        var after = sourceInt(state['outboundAfter']) ?? 0;
        final changed = await sources.repository.podcastSyncChanges(profile, identity, after: after);
        if (changed.isEmpty) {
          after = 0;
        }
        final actions = <Map<String, dynamic>>[];
        final sent = <PublicationProgress>[];
        for (final row in changed) {
          after = row.row;
          check();
          final value = row.progress;
          if (conflicts.containsKey(value.key) ||
              sources.activeProgressKeys.contains(value.key) ||
              row.entry.unavailable) {
            continue;
          }
          if (value.key != PodcastLibrary.seed(row.entry).key) {
            continue;
          }
          final ack = await sources.repository.podcastSyncAck(profile, identity, value.key);
          check();
          if (ack?.hash == progressHash(value)) {
            await sources.repository.acknowledgePodcastSync(profile, identity, value, progressHash(value));
            continue;
          }
          final adapter = sources.adapter(row.entry.sourceId);
          if (adapter is! PodcastRssSourceAdapter) {
            continue;
          }
          final file = row.entry.files.firstOrNull;
          if (file == null) {
            continue;
          }
          final location = await adapter.syncIdentity(file);
          check();
          if (location == null) {
            continue;
          }
          final total = (file.durationMs ?? 0) ~/ 1000;
          final reset = !value.finished && value.positionMs == 0;
          if (!reset && total <= 0) {
            continue;
          }
          actions.add({
            'podcast': _canonical(location.feed.toString(), aliases),
            'episode': _canonical(location.episode.toString(), aliases),
            'device': configuration.device,
            'action': reset ? 'new' : 'play',
            'timestamp': DateTime.fromMillisecondsSinceEpoch(value.updatedAt, isUtc: true).toIso8601String(),
            if (!reset) ...{
              'started': 0,
              'position': value.finished ? total : (value.positionMs ~/ 1000).clamp(0, total),
              'total': total,
            },
          });
          sent.add(value);
        }
        for (var offset = 0; offset < actions.length; offset += 100) {
          final end = (offset + 100).clamp(0, actions.length).toInt();
          aliases.addAll(await client.publishActions(actions.sublist(offset, end)));
          check();
          for (final value in sent.sublist(offset, end)) {
            await sources.repository.acknowledgePodcastSync(profile, identity, value, progressHash(value));
          }
        }
        state['outboundAfter'] = after;
        actionSince = incoming.timestamp;
      }
      state.addAll({
        'aliases': aliases,
        'conflicts': conflicts,
        'pending': pending,
        'pendingRemovals': pendingRemovals.toList(),
        'subscriptionSince': subscriptionSince,
        'actionSince': actionSince,
      });
      await _save(profile, key, state, check);
      conflictCount = conflicts.length;
      pendingCount = pending.length + pendingRemovals.length;
      phase = PodcastSyncPhase.complete;
      onUpdate();
    } finally {
      client.close();
      if (identical(_client, client)) {
        _client = null;
      }
    }
  }

  static int _actionTime(Map<String, dynamic> action, int received) {
    final timestamp = action['timestamp'];
    if (timestamp == null) {
      return (sourceInt(action['_received']) ?? received) * 1000;
    }
    if (timestamp is! String) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final time = DateTime.tryParse(RegExp(r'(?:Z|[+-]\d{2}:\d{2})$').hasMatch(timestamp) ? timestamp : '${timestamp}Z');
    if (time == null || time.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5)))) {
      throw const SourceException(SourceFailure.invalidData);
    }
    return time.millisecondsSinceEpoch;
  }

  static PublicationProgress _fromAction(PublicationProgress current, SourceEntry entry, Map<String, dynamic> action) {
    final reset = action['action'] == 'new';
    final position = reset ? 0 : sourceInt(action['position']);
    final total = sourceInt(action['total']) ?? 0;
    if (position == null || position < 0 || position > 7 * 24 * 3600 || total > 7 * 24 * 3600 || total < 0) {
      throw const SourceException(SourceFailure.invalidData);
    }
    final duration = entry.files.firstOrNull?.durationMs ?? total * 1000;
    final milliseconds = duration > 0 ? (position * 1000).clamp(0, duration).toInt() : position * 1000;
    return current.copyWith(
      session: const Uuid().v4(),
      positionMs: milliseconds,
      filePositionMs: milliseconds,
      fileIndex: 0,
      fraction: duration > 0 ? (milliseconds / duration).clamp(0.0, 1.0) : 0,
      finished: !reset && total > 0 && position >= total,
    );
  }

  Future<List<Map<String, dynamic>>> conflicts() async {
    final configuration = await config();
    if (configuration == null) {
      return const [];
    }
    final epoch = sources.generation;
    final state = await sources.repository.privatePreference(sources.profileId!, _stateKey(configuration));
    sources.requireSession(epoch);
    return sourceMap(state['conflicts']).values.map(sourceMap).toList();
  }

  Future<void> resolveConflict(
    String key, {
    required bool useRemote,
    required int expectedRevision,
    required String expectedRemoteHash,
  }) async {
    await settled;
    final operation = _resolveConflict(
      key,
      useRemote: useRemote,
      expectedRevision: expectedRevision,
      expectedRemoteHash: expectedRemoteHash,
    );
    _pass = operation;
    try {
      await operation;
    } finally {
      if (identical(_pass, operation)) {
        _pass = null;
      }
    }
  }

  Future<void> _resolveConflict(
    String key, {
    required bool useRemote,
    required int expectedRevision,
    required String expectedRemoteHash,
  }) async {
    final configuration = await config();
    if (configuration == null) {
      throw const SourceException(SourceFailure.authentication);
    }
    final epoch = sources.generation, profile = sources.profileId!;
    final stateKey = _stateKey(configuration),
        state = await sources.repository.privatePreference(profile, _stateKey(configuration));
    final values = sourceMap(state['conflicts']), conflict = sourceMap(values[key]);
    final current = await sources.repository.progress(profile, key);
    sources.requireSession(epoch);
    if (current == null ||
        current.revision != expectedRevision ||
        conflict['remoteHash'] != expectedRemoteHash ||
        sources.activeProgressKeys.contains(key)) {
      throw const SourceException(SourceFailure.conflict);
    }
    if (useRemote) {
      final remote = PublicationProgress.fromJson(sourceMap(conflict['remote']));
      if (remote.key != current.key) {
        throw const SourceException(SourceFailure.invalidData);
      }
      final saved = await sources.repository.saveProgress(
        profile,
        remote.copyWith(revision: current.revision),
        kind: 'gpodder-conflict',
      );
      await sources.repository.acknowledgePodcastSync(profile, account(configuration), saved, progressHash(saved));
    } else {
      await sources.repository.forgetPodcastSyncAck(profile, account(configuration), key);
    }
    values.remove(key);
    state['conflicts'] = values;
    await _save(profile, stateKey, state, () => sources.requireSession(epoch));
    conflictCount = values.length;
    onUpdate();
  }
}
