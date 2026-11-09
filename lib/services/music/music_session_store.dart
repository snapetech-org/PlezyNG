import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../../utils/serial_future_queue.dart';

import '../../database/app_database.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../utils/app_logger.dart';
import 'music_playback_service.dart';
import 'music_queue_controller.dart';

/// Everything needed to rebuild a parked music session on the next launch:
/// the full queue state plus provenance and the playhead. Volume is excluded —
/// it is already a global preference reapplied to every player.
class MusicSessionSnapshot {
  final MusicQueueState queue;
  final MusicPlayContext? playContext;
  final Duration position;
  final MediaItem? continuationSeed;
  final Set<String> continuationExcluded;

  const MusicSessionSnapshot({
    required this.queue,
    required this.playContext,
    required this.position,
    this.continuationSeed,
    this.continuationExcluded = const {},
  });
}

/// Per-profile persistence for the last music session (#2148).
///
/// Serialization boundary between [MusicSessionSnapshot] and the
/// `MusicSessions` Drift row. [save] rewrites the whole row (queue JSON
/// included) and runs only on queue-shape/mode changes; [updateProgress] is
/// the cheap cursor/playhead write-through used on track changes, pauses, and
/// the throttled position tick. Decoding is best-effort: any malformed row is
/// discarded as a whole — restore must never produce a half-valid session.
class MusicSessionStore {
  MusicSessionStore({required this._database, required this._profileId});

  final AppDatabase _database;
  final String _profileId;

  // Serialize saves, progress and clear; an old save must never resurrect a
  // session after stop or overwrite a newer cursor.
  final SerialFutureQueue _writes = SerialFutureQueue();
  static const int pageSize = 256;

  Future<void> save(MusicSessionSnapshot snapshot) => _writes.run(() async {
    final queue = snapshot.queue;
    if (!MusicQueueController().restoreState(queue)) {
      throw ArgumentError('Invalid music queue snapshot');
    }
    await _database.transaction(() async {
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
                'excluded': snapshot.continuationExcluded.toList(),
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
      await _database.customStatement('DELETE FROM music_queue_entries WHERE profile_id = ?', [_profileId]);
      final playbackPositions = List<int>.filled(queue.items.length, 0);
      for (var i = 0; i < queue.order.length; i++) {
        playbackPositions[queue.order[i]] = i;
      }
      // Bounded encoding batches; never build a multi-megabyte JSON array.
      for (var start = 0; start < queue.items.length; start += pageSize) {
        final end = (start + pageSize).clamp(0, queue.items.length);
        await _database.batch((batch) {
          for (var i = start; i < end; i++) {
            batch.customStatement(
              'INSERT INTO music_queue_entries (profile_id, canonical_index, playback_index, metadata) VALUES (?, ?, ?, ?)',
              [_profileId, i, playbackPositions[i], jsonEncode(queue.items[i].toJson())],
            );
          }
        });
      }
    });
  });

  Future<void> updateProgress({required int cursor, required Duration position}) => _writes.run(
    () => _database.updateMusicSessionProgress(
      profileId: _profileId,
      cursor: cursor,
      positionMs: position.inMilliseconds.clamp(0, 1 << 62),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  Future<MusicSessionSnapshot?> load() async {
    await _writes.settled;
    return _database.transaction(() async {
      final row = await _database.getMusicSession(_profileId);
      if (row == null) return null;
      try {
        final payload = jsonDecode(row.queueJson);
        final items = <MediaItem>[];
        final order = <int>[];
        MediaItem? continuationSeed;
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
              continuationSeed = seed;
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
          items: items,
          order: order,
          cursor: row.cursor,
          shuffled: row.shuffled,
          repeatMode: repeatMode,
        );
        if (!MusicQueueController().restoreState(queue)) return null;
        return MusicSessionSnapshot(
          queue: queue,
          continuationSeed: continuationSeed,
          continuationExcluded: Set.unmodifiable(continuationExcluded),
          playContext: row.contextTitle != null && contextKind != null
              ? MusicPlayContext(title: row.contextTitle!, kind: contextKind)
              : null,
          position: Duration(milliseconds: row.positionMs < 0 ? 0 : row.positionMs),
        );
      } catch (e, st) {
        appLogger.w('Discarding malformed persisted music session', error: e, stackTrace: st);
        return null;
      }
    });
  }

  Future<void> clear() => _writes.run(() => _database.deleteMusicSessionForProfile(_profileId));

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
