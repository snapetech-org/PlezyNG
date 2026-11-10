import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../utils/media_server_http_client.dart' show AbortController;
import 'music_library_store.dart';

/// Calendar dates are not instants: a server's release-date UTC suffix must
/// never move an album to the previous day in a western timezone. Incomplete
/// dates, normalized invalid dates and the original release day are excluded.
bool isMusicAnniversary(MediaItem album, DateTime today) {
  if (album.kind != MediaKind.album) return false;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:$|T)').firstMatch(album.originallyAvailableAt ?? '');
  if (match == null) return false;
  final year = int.parse(match[1]!), month = int.parse(match[2]!), day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  return year > 0 &&
      year < today.year &&
      date.year == year &&
      date.month == month &&
      date.day == day &&
      month == today.month &&
      day == today.day;
}

/// Scans the album catalog, not only previously listened/downloaded records.
/// A daily, account-qualified cache avoids repeating the scan on each visit.
/// Pagination that repeats forever or exceeds the work budget fails visibly;
/// partial results are never saved as a complete library index.
class MusicAnniversaries {
  MusicAnniversaries(this.store);
  final MusicLibraryStore store;

  Future<List<MediaItem>> load(
    MediaServerClient client,
    String libraryId, {
    required bool Function() isCurrent,
    DateTime? now,
    int? libraryRevision,
    int contentEpoch = 0,
    AbortController? abort,
  }) async {
    final today = now ?? DateTime.now();
    final day = '${today.year}-${today.month}-${today.day}';
    final key = '${client.serverId.value}:$libraryId';
    final auth = client.authenticationSessionId;
    final scope = client.cacheServerId;
    void check() {
      abort?.throwIfAborted();
      if (!store.active ||
          !isCurrent() ||
          !identical(auth, client.authenticationSessionId) ||
          scope != client.cacheServerId) {
        throw StateError('Music library authorization changed');
      }
    }

    check();
    final cache = await store.document('anniversaries', key);
    check();
    if (cache?['version'] == 1 &&
        cache?['day'] == day &&
        cache?['scope'] == scope &&
        cache?['revision'] == libraryRevision &&
        cache?['epoch'] == contentEpoch) {
      try {
        final items = (cache!['items'] as List)
            .map((row) => MediaItem.fromJson(Map<String, dynamic>.from(row as Map)))
            .toList();
        return items
            .where(
              (album) =>
                  album.serverId == client.serverId.value &&
                  (album.libraryId == null || album.libraryId == libraryId) &&
                  isMusicAnniversary(album, today),
            )
            .toList();
      } on FormatException {
        /* Refresh a corrupt cache. */
      } on TypeError {
        /* Refresh a corrupt cache. */
      }
    }
    if (client.isOfflineMode) return [];
    final albums = <MediaItem>[], seen = <String>{};
    var offset = 0;
    while (true) {
      check();
      if (offset >= 100000) throw StateError('Album scan exceeded its work budget');
      final page = await client
          .fetchLibraryPagedContent(
            libraryId,
            query: LibraryQuery(
              kind: MediaKind.album,
              offset: offset,
              limit: 250,
              sort: const LibrarySort(field: 'title', direction: LibrarySortDirection.ascending),
            ),
            abort: abort,
          )
          .timeout(const Duration(seconds: 20));
      check();
      var fresh = false;
      for (final item in page.items) {
        if (!seen.add(item.globalKey)) continue;
        fresh = true;
        if (item.serverId == client.serverId.value &&
            (item.libraryId == null || item.libraryId == libraryId) &&
            isMusicAnniversary(item, today)) {
          if (albums.length >= 500) throw StateError('Anniversary catalog exceeds its display budget');
          albums.add(musicIdentity(item));
        }
      }
      offset += page.items.length;
      if (offset >= page.totalCount) break;
      if (!fresh || page.items.isEmpty) throw StateError('Album catalog stopped advancing');
    }
    check();
    albums.sort((a, b) => a.displayTitle.compareTo(b.displayTitle));
    await store.saveDocument('anniversaries', key, {
      'version': 1,
      'day': day,
      'scope': scope,
      'revision': libraryRevision,
      'epoch': contentEpoch,
      'items': albums.map((album) => album.toJson()).toList(),
    });
    check();
    return albums;
  }
}
