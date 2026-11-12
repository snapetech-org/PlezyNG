import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;

import '../../utils/serial_future_queue.dart';

import '../../database/app_database.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../utils/app_logger.dart';
import 'music_playback_service.dart';
import 'music_queue_controller.dart';
import 'music_queue_items.dart';

/// Everything needed to rebuild a parked music session on the next launch:
/// the full queue state plus provenance and the playhead. Volume is excluded —
/// it is already a global preference reapplied to every player.
class MusicSessionSnapshot {
  final MusicQueueState queue;
  final MusicPlayContext? playContext;
  final Duration position;
  final MediaItem? continuationSeed;
  final String? continuationAccount;
  final bool continuationAlbumRadio;
  final double continuationDistance;
  final Set<String> continuationExcluded;

  const MusicSessionSnapshot({
    required this.queue,
    required this.playContext,
    required this.position,
    this.continuationSeed,
    this.continuationAccount,
    this.continuationAlbumRadio = false,
    this.continuationDistance = .25,
    this.continuationExcluded = const {},
  });
}

/// Per-profile persistence for the last music session (#2148).
///
/// Serialization boundary between the snapshot, session header and bounded
/// queue-entry pages. [save] updates changed entries transactionally;
/// [updateProgress] is
/// the cheap cursor/playhead write-through used on track changes, pauses, and
/// the throttled position tick. Decoding is best-effort: any malformed row is
/// discarded as a whole — restore must never produce a half-valid session.
class MusicSessionStore {
  MusicSessionStore({required AppDatabase database, required String profileId, this.queueScratchDirectory})
    : _database = database,
      _profileId = profileId,
      _epoch = database.musicDataEpoch(profileId);

  final Directory? queueScratchDirectory;
  final AppDatabase _database;
  final String _profileId;
  final int _epoch;
  bool get _active => _database.musicDataEpoch(_profileId) == _epoch;
  void _guard() {
    if (!_active) throw StateError('Music profile retired');
  }

  // Serialize saves, progress and clear; an old save must never resurrect a
  // session after stop or overwrite a newer cursor.
  final SerialFutureQueue _writes = SerialFutureQueue();
  static const int pageSize = 256;

  Future<void> save(MusicSessionSnapshot snapshot) => _writes.run(() async {
    if (!_active) return;
    final queue = snapshot.queue;
    if (!snapshot.continuationDistance.isFinite ||
        snapshot.continuationDistance < 0 ||
        snapshot.continuationDistance > 1 ||
        (snapshot.continuationAlbumRadio && snapshot.continuationSeed?.kind != MediaKind.album)) {
      throw ArgumentError('Invalid music continuation');
    }
    if (!queue.isValid) {
      throw ArgumentError('Invalid music queue snapshot');
    }
    await _database.transaction(() async {
      _guard();
      await _database.upsertMusicSession(
        MusicSessionRow(
          profileId: _profileId,
          queueJson: jsonEncode({
            'version': 2,
            'length': queue.items.length,
            if (snapshot.continuationSeed case final seed?)
              'continuation': {
                // Persist identities, never a stream URL or authentication data.
                'seed': MediaItem(
                  id: seed.id,
                  backend: seed.backend,
                  kind: seed.kind,
                  title: seed.title,
                  serverId: seed.serverId,
                  libraryId: seed.libraryId,
                ).toJson(),
                'account': ?snapshot.continuationAccount,
                'excluded': snapshot.continuationExcluded.toList(),
                'albumRadio': snapshot.continuationAlbumRadio,
                'distance': snapshot.continuationDistance,
              },
          }),
          orderJson: '[]',
          cursor: queue.cursor,
          shuffled: queue.shuffled,
          repeatMode: _repeatModeId(queue.repeatMode),
          contextTitle: snapshot.playContext?.title,
          contextKind: snapshot.playContext != null ? _contextKindId(snapshot.playContext!.kind) : null,
          positionMs: snapshot.position.inMilliseconds.clamp(0, 1 << 62),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _guard();
      await _writeQueueRows(queue);
    });
  });

  /// Stage only moved playback positions before upserting changed rows. The
  /// negative positions are private to this transaction, so permutation cycles
  /// never collide with the unique playback index seen by committed readers.
  Future<void> _writeQueueRows(MusicQueueState queue) async {
    final shape = await _database
        .customSelect(
          'SELECT COUNT(*) AS n, MIN(canonical_index) AS cmin, MAX(canonical_index) AS cmax, '
          'MIN(playback_index) AS pmin, MAX(playback_index) AS pmax '
          'FROM music_queue_entries WHERE profile_id = ?',
          variables: [Variable(_profileId)],
        )
        .getSingle();
    _guard();
    final count = shape.read<int>('n');
    if (count > 0 &&
        (shape.read<int>('cmin') != 0 ||
            shape.read<int>('cmax') != count - 1 ||
            shape.read<int>('pmin') != 0 ||
            shape.read<int>('pmax') != count - 1)) {
      // An interrupted/corrupt legacy shape has no safe incremental identity.
      await _database.customStatement('DELETE FROM music_queue_entries WHERE profile_id = ?', [_profileId]);
    }
    await _database.customStatement('DELETE FROM music_queue_entries WHERE profile_id = ? AND canonical_index >= ?', [
      _profileId,
      queue.items.length,
    ]);
    final positions = List<int>.filled(queue.items.length, 0);
    for (var i = 0; i < queue.order.length; i++) {
      positions[queue.order[i]] = i;
    }
    for (var start = 0; start < queue.items.length; start += pageSize) {
      _guard();
      final rows = await _database
          .customSelect(
            'SELECT canonical_index, playback_index FROM music_queue_entries '
            'WHERE profile_id = ? AND canonical_index >= ? AND canonical_index < ?',
            variables: [Variable(_profileId), Variable(start), Variable(start + pageSize)],
          )
          .get();
      await _database.batch((batch) {
        for (final row in rows) {
          final canonical = row.read<int>('canonical_index');
          if (row.read<int>('playback_index') != positions[canonical]) {
            batch.customStatement(
              'UPDATE music_queue_entries SET playback_index = ? WHERE profile_id = ? AND canonical_index = ?',
              [-canonical - 1, _profileId, canonical],
            );
          }
        }
      });
    }
    // Encoding remains bounded. Unchanged payloads and positions cause no row
    // update, including repeat/context-only edits and an appended queue tail.
    for (var start = 0; start < queue.items.length; start += pageSize) {
      _guard();
      final end = (start + pageSize).clamp(0, queue.items.length);
      await _database.batch((batch) {
        for (var i = start; i < end; i++) {
          batch.customStatement(
            'INSERT INTO music_queue_entries (profile_id, canonical_index, playback_index, metadata) '
            'VALUES (?, ?, ?, ?) ON CONFLICT (profile_id, canonical_index) DO UPDATE SET '
            'playback_index = excluded.playback_index, metadata = excluded.metadata '
            'WHERE music_queue_entries.playback_index != excluded.playback_index '
            'OR music_queue_entries.metadata != excluded.metadata',
            [_profileId, i, positions[i], jsonEncode(queue.items[i].toJson())],
          );
        }
      });
    }
    _guard();
  }

  Future<void> updateProgress({required int cursor, required Duration position}) => _writes.run(() async {
    if (!_active) return;
    await _database.transaction(() async {
      _guard();
      await _database.updateMusicSessionProgress(
        profileId: _profileId,
        cursor: cursor,
        positionMs: position.inMilliseconds.clamp(0, 1 << 62),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _guard();
    });
  });

  Future<MusicSessionSnapshot?> load() async {
    await _writes.settled;
    if (!_active) return null;
    return _database.transaction(() async {
      final row = await _database.getMusicSession(_profileId);
      if (row == null || !_active) return null;
      final items = MusicQueueItems(spill: true, scratchRoot: queueScratchDirectory);
      try {
        final payload = jsonDecode(row.queueJson);
        final order = <int>[];
        MediaItem? continuationSeed;
        String? continuationAccount;
        var continuationAlbumRadio = false;
        var continuationDistance = .25;
        var continuationExcluded = <String>{};
        if (payload is List) {
          // Read v1 rows until their next save; upgrading never loses the old session.
          items.addAll(payload.map((json) => MediaItem.fromJson(json as Map<String, dynamic>)));
          order.addAll((jsonDecode(row.orderJson) as List).cast<int>());
        } else if (payload is Map && payload['version'] == 2) {
          if (payload['continuation'] case final Map continuation) {
            final seed = MediaItem.fromJson(Map<String, dynamic>.from(continuation['seed'] as Map));
            if (seed.serverId != null &&
                const [MediaKind.track, MediaKind.album, MediaKind.artist].contains(seed.kind)) {
              final radio = continuation['albumRadio'];
              final distance = continuation['distance'];
              if (radio != null && radio is! bool ||
                  distance != null && (distance is! num || !distance.isFinite || distance < 0 || distance > 1) ||
                  radio == true && seed.kind != MediaKind.album) {
                throw const FormatException('Invalid persisted music continuation');
              }
              continuationAlbumRadio = radio == true;
              continuationDistance = distance == null ? .25 : (distance as num).toDouble();
              continuationSeed = seed;
              final account = continuation['account'];
              if (account is String && account.isNotEmpty && account.length <= 1024) continuationAccount = account;
              continuationExcluded = (continuation['excluded'] as List).cast<String>().toSet();
            }
          }
          final length = payload['length'] as int;
          if (length <= 0) return null;
          final count = await _database
              .customSelect(
                'SELECT COUNT(*) AS n FROM music_queue_entries WHERE profile_id = ?',
                variables: [Variable<String>(_profileId)],
              )
              .getSingle();
          if (count.read<int>('n') != length) return null;
          order.addAll(List<int>.filled(length, -1));
          for (var start = 0; start < length; start += pageSize) {
            final rows = await _database
                .customSelect(
                  'SELECT canonical_index, playback_index, metadata FROM music_queue_entries '
                  'WHERE profile_id = ? AND canonical_index >= ? ORDER BY canonical_index LIMIT ?',
                  variables: [Variable<String>(_profileId), Variable<int>(start), Variable<int>(pageSize)],
                )
                .get();
            for (final entry in rows) {
              final canonical = entry.read<int>('canonical_index');
              final playback = entry.read<int>('playback_index');
              if (canonical != items.length || playback < 0 || playback >= length || order[playback] != -1) {
                return null;
              }
              items.add(MediaItem.fromJson(jsonDecode(entry.read<String>('metadata')) as Map<String, dynamic>));
              order[playback] = canonical;
            }
          }
          if (items.length != length) return null;
        } else {
          return null;
        }
        final repeatMode = _repeatModeFromId(row.repeatMode);
        if (repeatMode == null) return null;
        final contextKind = row.contextKind != null ? _contextKindFromId(row.contextKind!) : null;
        final queue = MusicQueueState(
          items: items.snapshot(),
          order: order,
          cursor: row.cursor,
          shuffled: row.shuffled,
          repeatMode: repeatMode,
        );
        if (!queue.isValid) return null;
        if (!_active) return null;
        return MusicSessionSnapshot(
          queue: queue,
          continuationSeed: continuationSeed,
          continuationAccount: continuationAccount,
          continuationAlbumRadio: continuationAlbumRadio,
          continuationDistance: continuationDistance,
          continuationExcluded: Set.unmodifiable(continuationExcluded),
          playContext: row.contextTitle != null && contextKind != null
              ? MusicPlayContext(title: row.contextTitle!, kind: contextKind)
              : null,
          position: Duration(milliseconds: row.positionMs < 0 ? 0 : row.positionMs),
        );
      } catch (e, st) {
        appLogger.w('Discarding malformed persisted music session', error: e, stackTrace: st);
        return null;
      } finally {
        items.clear();
      }
    });
  }

  Future<void> clear() => _writes.run(() async {
    if (!_active) return;
    await _database.transaction(() async {
      _guard();
      await _database.deleteMusicSessionForProfile(_profileId);
      _guard();
    });
  });

  /// Stable persisted ids — never the enum `.name`, which a rename would
  /// corrupt (same policy as [OfflineActionType.id]).
  static String _repeatModeId(MusicRepeatMode mode) => switch (mode) {
    MusicRepeatMode.off => 'off',
    MusicRepeatMode.all => 'all',
    MusicRepeatMode.one => 'one',
  };

  static MusicRepeatMode? _repeatModeFromId(String id) => switch (id) {
    'off' => MusicRepeatMode.off,
    'all' => MusicRepeatMode.all,
    'one' => MusicRepeatMode.one,
    _ => null,
  };

  static String _contextKindId(MusicPlayContextKind kind) => switch (kind) {
    MusicPlayContextKind.album => 'album',
    MusicPlayContextKind.artist => 'artist',
    MusicPlayContextKind.playlist => 'playlist',
    MusicPlayContextKind.mix => 'mix',
    MusicPlayContextKind.tracks => 'tracks',
  };

  static MusicPlayContextKind? _contextKindFromId(String id) => switch (id) {
    'album' => MusicPlayContextKind.album,
    'artist' => MusicPlayContextKind.artist,
    'playlist' => MusicPlayContextKind.playlist,
    'mix' => MusicPlayContextKind.mix,
    'tracks' => MusicPlayContextKind.tracks,
    _ => null,
  };
}
