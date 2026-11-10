import 'dart:convert';

import 'package:drift/drift.dart' show Variable, TableUpdate, TableUpdateQuery;

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

class MusicHistoryEntry {
  const MusicHistoryEntry({
    required this.id,
    required this.item,
    required this.startedAt,
    required this.listenedMs,
    required this.finished,
    this.account,
  });
  final String id;
  final MediaItem item;
  final DateTime startedAt;
  final int listenedMs;
  final bool finished;
  final String? account;
  (int, String) get cursor => (startedAt.millisecondsSinceEpoch, id);
}

class MusicHistoryPage {
  const MusicHistoryPage(this.entries, this.cursor);
  final List<MusicHistoryEntry> entries;
  final (int, String)? cursor;
}

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

  Stream<void> get historyChanges => database.tableUpdates(TableUpdateQuery.onTableName('music_listens')).map((_) {});

  Future<MusicHistoryPage> historyPage({int limit = 50, (int, String)? before}) async {
    if (limit < 1 || limit > 100) throw ArgumentError('Invalid history page size');
    if (!active) return const MusicHistoryPage([], null);
    final rows = await database
        .customSelect(
          'SELECT id, metadata, started_at, listened_ms, finished FROM music_listens '
          'WHERE profile_id=? AND qualified=1 '
          '${before == null ? '' : 'AND (started_at < ? OR (started_at = ? AND id < ?)) '}'
          'ORDER BY started_at DESC, id DESC LIMIT ?',
          variables: [
            Variable(profileId),
            if (before != null) ...[Variable(before.$1), Variable(before.$1), Variable(before.$2)],
            Variable(limit + 1),
          ],
        )
        .get();
    if (!active) return const MusicHistoryPage([], null);
    final entries = rows
        .take(limit)
        .map(
          (row) => MusicHistoryEntry(
            id: row.read<String>('id'),
            item: MediaItem.fromJson(jsonDecode(row.read<String>('metadata'))),
            startedAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('started_at'), isUtc: true),
            listenedMs: row.read<int>('listened_ms'),
            finished: row.read<int>('finished') != 0,
          ),
        )
        .toList();
    return MusicHistoryPage(entries, rows.length > limit ? entries.last.cursor : null);
  }

  Future<MusicHistoryPage> historySyncPage({int limit = 8, (int, String)? before, Set<String>? accounts}) async {
    if (limit < 1 || limit > 8) throw ArgumentError('Invalid history sync page size');
    if (!active) return const MusicHistoryPage([], null);
    if (accounts?.isEmpty == true) return const MusicHistoryPage([], null);
    final rows = await database
        .customSelect(
          'SELECT h.id, h.metadata, h.started_at, h.listened_ms, h.finished, d.document '
          'FROM music_listens h JOIN music_documents d ON d.profile_id=h.profile_id AND d.id=h.id AND d.kind=? '
          'WHERE h.profile_id=? '
          '${accounts == null ? '' : 'AND json_extract(d.document, \'\$.account\') IN (${List.filled(accounts.length, '?').join(',')}) '}'
          '${before == null ? '' : 'AND (h.started_at < ? OR (h.started_at = ? AND h.id < ?)) '}'
          'ORDER BY h.started_at DESC, h.id DESC LIMIT ?',
          variables: [
            Variable('historyOwner'),
            Variable(profileId),
            if (accounts != null) ...accounts.map(Variable.new),
            if (before != null) ...[Variable(before.$1), Variable(before.$1), Variable(before.$2)],
            Variable(limit + 1),
          ],
        )
        .get();
    if (!active) return const MusicHistoryPage([], null);
    final entries = <MusicHistoryEntry>[];
    for (final row in rows.take(limit)) {
      final owner = jsonDecode(row.read<String>('document'));
      final account = owner is Map ? owner['account'] : null;
      if (account is! String) continue;
      entries.add(
        MusicHistoryEntry(
          id: row.read<String>('id'),
          item: MediaItem.fromJson(jsonDecode(row.read<String>('metadata'))),
          startedAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('started_at'), isUtc: true),
          listenedMs: row.read<int>('listened_ms'),
          finished: row.read<int>('finished') != 0,
          account: account,
        ),
      );
    }
    final last = rows.isEmpty ? null : rows.take(limit).last;
    return MusicHistoryPage(
      entries,
      rows.length > limit && last != null ? (last.read<int>('started_at'), last.read<String>('id')) : null,
    );
  }

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

  Future<Map<String, dynamic>?> pendingStationSnapshot(String id) async {
    final pending = await document('stationPending', id);
    if (pending != null) return pending;
    final legacy = await document('stationSnapshot', id);
    return legacy?['pending'] == true ? legacy : null;
  }

  Future<void> completeStationSnapshot(String id, Map<String, dynamic> snapshot) async {
    await database.transaction(() async {
      if (!active) return;
      await saveDocument('stationSnapshot', id, {...snapshot, 'pending': false});
      await deleteDocument('stationPending', id);
      await pruneStationSnapshots();
    });
  }

  Future<void> pruneStationSnapshots({int maxSnapshots = 64, int maxBytes = 64 * 1024 * 1024}) async {
    if (maxSnapshots < 1 || maxBytes < 1) throw ArgumentError('Invalid snapshot quota');
    if (!active) return;
    await database.transaction(() async {
      (int, String)? cursor;
      do {
        final page = await documentPage('stationSnapshot', limit: 100, after: cursor);
        if (!active) return;
        for (final snapshot in page.entries) {
          final id = snapshot['id'];
          if (snapshot['pending'] != true || id is! String || id.isEmpty) continue;
          if (await document('stationPending', id) == null) await saveDocument('stationPending', id, snapshot);
          await deleteDocument('stationSnapshot', id);
        }
        cursor = page.cursor;
      } while (cursor != null);
      final rows = await database
          .customSelect(
            'SELECT id, LENGTH(CAST(document AS BLOB)) AS bytes FROM music_documents '
            'WHERE profile_id=? AND kind=? ORDER BY updated_at DESC, id DESC',
            variables: [Variable(profileId), Variable('stationSnapshot')],
          )
          .get();
      if (!active) return;
      var retained = 0, bytes = 0;
      for (final row in rows) {
        final size = row.read<int>('bytes');
        if (retained >= maxSnapshots || bytes + size > maxBytes) {
          await deleteDocument('stationSnapshot', row.read<String>('id'));
        } else {
          retained++;
          bytes += size;
        }
      }
    });
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

  /// Stable keyset traversal for pending writes. The cursor advances over raw
  /// rows, including corrupt documents, while acknowledgements delete rows.
  Future<({List<Map<String, dynamic>> entries, (int, String)? cursor})> documentPage(
    String kind, {
    int limit = 500,
    (int, String)? after,
  }) async {
    if (!active) return (entries: <Map<String, dynamic>>[], cursor: null);
    if (limit < 1 || limit > 500) throw ArgumentError('Invalid page');
    final rows = await database
        .customSelect(
          'SELECT id, updated_at, document FROM music_documents '
          'WHERE profile_id=? AND kind=? '
          '${after == null ? '' : 'AND (updated_at < ? OR (updated_at = ? AND id < ?)) '} '
          'ORDER BY updated_at DESC, id DESC LIMIT ?',
          variables: [
            Variable(profileId),
            Variable(kind),
            if (after != null) ...[Variable(after.$1), Variable(after.$1), Variable(after.$2)],
            Variable(limit),
          ],
        )
        .get();
    final entries = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        entries.add(jsonDecode(row.read<String>('document')) as Map<String, dynamic>);
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    final last = rows.lastOrNull;
    return (
      entries: entries,
      cursor: last == null || rows.length < limit ? null : (last.read<int>('updated_at'), last.read<String>('id')),
    );
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
    String? account,
    bool Function()? current,
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
    await database.transaction(() async {
      if (!active || current?.call() == false) return;
      final existing = await database
          .customSelect(
            'SELECT track_key, started_at FROM music_listens WHERE profile_id=? AND id=?',
            variables: [Variable(profileId), Variable(id)],
          )
          .getSingleOrNull();
      final owner = await document('historyOwner', id);
      if (!active || current?.call() == false) return;
      if ((existing != null &&
              (existing.read<String>('track_key') != item.globalKey ||
                  existing.read<int>('started_at') != startedAt.toUtc().millisecondsSinceEpoch)) ||
          (owner != null && owner['account'] != account)) {
        throw StateError('Listening occurrence identity conflict');
      }
      if (account != null) {
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(account)) throw ArgumentError('Invalid history account');
        await saveDocument('historyOwner', id, {'account': account});
      }
      if (!active || current?.call() == false) return;
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
      database.notifyUpdates({const TableUpdate('music_listens')});
    });
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

  Future<void> clearHistory() async {
    if (!active) return;
    await database.transaction(() async {
      await database.customStatement('DELETE FROM music_listens WHERE profile_id=?', [profileId]);
      await database.customStatement('DELETE FROM music_documents WHERE profile_id=? AND kind=?', [
        profileId,
        'historyOwner',
      ]);
    });
    database.notifyUpdates({const TableUpdate('music_listens')});
  }
}
