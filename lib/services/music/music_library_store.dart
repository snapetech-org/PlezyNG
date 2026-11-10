import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../../database/app_database.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';

/// A deliberately credential-free history record. Raw server payloads, artwork
/// URLs and stream locations never enter listening history or exported links.
MediaItem musicIdentity(MediaItem item) => MediaItem.fromJson({
  'backend': item.backend.name,
  'id': item.id,
  'kind': item.kind.name,
  'title': item.title,
  'originalTitle': item.originalTitle,
  'updatedAt': item.updatedAt,
  'serverId': item.serverId,
  'libraryId': item.libraryId,
  'parentId': item.parentId,
  'parentTitle': item.parentTitle,
  'grandparentId': item.grandparentId,
  'grandparentTitle': item.grandparentTitle,
  'durationMs': item.durationMs,
  'year': item.year,
  'originallyAvailableAt': item.originallyAvailableAt,
  'genres': item.genres,
  'index': item.index,
  'parentIndex': item.parentIndex,
});

enum MusicChartGroup { tracks, albums, artists }

class MusicChartEntry {
  const MusicChartEntry({required this.item, required this.plays, required this.listenedMs});
  final MediaItem item;
  final int plays;
  final int listenedMs;
}

/// Per-profile local history and small versioned feature documents. SQL reads
/// are bounded; aggregations execute in SQLite rather than loading all events.
class MusicLibraryStore {
  MusicLibraryStore(this.database, this.profileId) : _epoch = database.musicDataEpoch(profileId);
  final AppDatabase database;
  final String profileId;
  final int _epoch;
  bool get active => database.musicDataEpoch(profileId) == _epoch;

  Future<void> saveDocument(String kind, String id, Map<String, dynamic> value) {
    if (!active) return Future.value();
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > 2 * 1024 * 1024 || kind.isEmpty || id.isEmpty) {
      throw ArgumentError('Invalid music document');
    }
    return database.customStatement(
      'INSERT INTO music_documents VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(profile_id, kind, id) DO UPDATE SET document=excluded.document, updated_at=excluded.updated_at',
      [profileId, kind, id, encoded, DateTime.now().millisecondsSinceEpoch],
    );
  }

  Future<Map<String, dynamic>?> document(String kind, String id) async {
    if (!active) return null;
    final row = await database
        .customSelect(
          'SELECT document FROM music_documents WHERE profile_id=? AND kind=? AND id=?',
          variables: [Variable(profileId), Variable(kind), Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    try {
      return jsonDecode(row.read<String>('document')) as Map<String, dynamic>;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> documents(String kind, {int limit = 100, int offset = 0}) async {
    if (!active) return [];
    if (limit < 1 || limit > 500 || offset < 0) throw ArgumentError('Invalid page');
    final rows = await database
        .customSelect(
          'SELECT document FROM music_documents WHERE profile_id=? AND kind=? ORDER BY updated_at DESC LIMIT ? OFFSET ?',
          variables: [Variable(profileId), Variable(kind), Variable(limit), Variable(offset)],
        )
        .get();
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        result.add(jsonDecode(row.read<String>('document')) as Map<String, dynamic>);
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return result;
  }

  Future<void> deleteDocument(String kind, String id) => !active
      ? Future.value()
      : database.customStatement('DELETE FROM music_documents WHERE profile_id=? AND kind=? AND id=?', [
          profileId,
          kind,
          id,
        ]);

  Future<void> record({
    required String id,
    required MediaItem track,
    required DateTime startedAt,
    required int listenedMs,
    required bool finished,
  }) async {
    if (!active) return;
    if (track.kind != MediaKind.track || track.serverId == null || listenedMs < 0) {
      throw ArgumentError('Invalid listen');
    }
    final duration = track.durationMs;
    // This app's explicit counting rule: actual listening >= half the track or
    // four minutes. Unknown-duration streams need four minutes. Seeking is not
    // listening; the recorder measures progression, not the final playhead.
    final threshold = duration != null && duration > 0 ? (duration ~/ 2).clamp(1, 240000) : 240000;
    final item = musicIdentity(track);
    await database.customStatement(
      '''
      INSERT INTO music_listens VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(profile_id, id) DO UPDATE SET
        listened_ms=MAX(listened_ms, excluded.listened_ms),
        qualified=MAX(qualified, excluded.qualified), finished=MAX(finished, excluded.finished)
    ''',
      [
        profileId,
        id,
        item.globalKey,
        '${item.serverId}:${item.grandparentId ?? item.trackArtistTitle ?? item.id}',
        '${item.serverId}:${item.parentId ?? item.id}',
        jsonEncode(item.toJson()),
        startedAt.toUtc().millisecondsSinceEpoch,
        listenedMs,
        listenedMs >= threshold ? 1 : 0,
        finished ? 1 : 0,
      ],
    );
  }

  Future<List<MusicChartEntry>> chart({
    required DateTime from,
    required DateTime until,
    MusicChartGroup group = MusicChartGroup.tracks,
    int limit = 50,
  }) async {
    if (!active) return [];
    if (!until.isAfter(from) || limit < 1 || limit > 500) throw ArgumentError('Invalid chart period');
    final column = switch (group) {
      MusicChartGroup.tracks => 'track_key',
      MusicChartGroup.albums => 'album_key',
      MusicChartGroup.artists => 'artist_key',
    };
    final rows = await database
        .customSelect(
          '''
      SELECT metadata, COUNT(*) AS plays, SUM(listened_ms) AS listened_ms
      FROM music_listens WHERE profile_id=? AND started_at>=? AND started_at<? AND qualified=1
      GROUP BY $column ORDER BY plays DESC, listened_ms DESC, $column LIMIT ?
    ''',
          variables: [
            Variable(profileId),
            Variable(from.toUtc().millisecondsSinceEpoch),
            Variable(until.toUtc().millisecondsSinceEpoch),
            Variable(limit),
          ],
        )
        .get();
    return rows
        .map(
          (row) => MusicChartEntry(
            item: MediaItem.fromJson(jsonDecode(row.read<String>('metadata'))),
            plays: row.read<int>('plays'),
            listenedMs: row.read<int>('listened_ms'),
          ),
        )
        .toList();
  }

  Future<List<MediaItem>> recent({int limit = 50, bool rediscover = false, DateTime? now}) async {
    if (!active) return [];
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 90)).millisecondsSinceEpoch;
    final rows = await database
        .customSelect(
          '''
      SELECT metadata, MAX(started_at) AS last_play FROM music_listens WHERE profile_id=? AND qualified=1
      GROUP BY track_key ${rediscover ? 'HAVING MAX(started_at) < ?' : ''}
      ORDER BY last_play ${rediscover ? 'ASC' : 'DESC'} LIMIT ?
    ''',
          variables: [Variable(profileId), if (rediscover) Variable(cutoff), Variable(limit.clamp(1, 500))],
        )
        .get();
    return rows.map((row) => MediaItem.fromJson(jsonDecode(row.read<String>('metadata')))).toList();
  }

  Future<void> clearHistory() =>
      !active ? Future.value() : database.customStatement('DELETE FROM music_listens WHERE profile_id=?', [profileId]);
}
