import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../utils/media_server_http_client.dart' show AbortController;
import 'music_account_scope.dart';

/// A saved dynamic query, distinct from a materialized server playlist. Filters
/// use the existing library editor/translator; re-opening re-evaluates the rule.
class MusicStation {
  MusicStation({
    required this.id,
    required this.title,
    required this.serverId,
    required this.libraryId,
    this.filters = const [],
    this.sort = 'random',
    this.descending = true,
    this.albums = false,
    this.trackLimit = 100,
    this.durationMinutes = 0,
    this.storageLimitMiB = 0,
    this.refreshHours = 0,
    this.wifiOnly = true,
  }) {
    if ([id, title.trim(), serverId, libraryId].any((s) => s.isEmpty) ||
        trackLimit < 1 ||
        trackLimit > 5000 ||
        durationMinutes < 0 ||
        durationMinutes > 4320 ||
        storageLimitMiB < 0 ||
        storageLimitMiB > 65536 ||
        refreshHours < 0 ||
        refreshHours > 720 ||
        filters.length > 50 ||
        !const [
          'random',
          'title',
          'addedAt',
          'lastViewedAt',
          'viewCount',
          'rating',
          'originallyAvailableAt',
        ].contains(sort)) {
      throw ArgumentError('Invalid station');
    }
  }
  final String id, title, serverId, libraryId, sort;
  final List<LibraryFilter> filters;
  final bool descending, albums, wifiOnly;
  final int trackLimit, durationMinutes, refreshHours, storageLimitMiB;
  int? get storageLimitBytes => storageLimitMiB == 0 ? null : storageLimitMiB * 1024 * 1024;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'serverId': serverId,
    'libraryId': libraryId,
    'filters': filters.map((f) => f.toStorageJson()).toList(),
    'sort': sort,
    'descending': descending,
    'albums': albums,
    'trackLimit': trackLimit,
    'durationMinutes': durationMinutes,
    'storageLimitMiB': storageLimitMiB,
    'refreshHours': refreshHours,
    'wifiOnly': wifiOnly,
  };
  factory MusicStation.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('Unsupported station');
    final raw = json['filters'] as List;
    final filters = raw.map(LibraryFilter.fromStorageJson).toList();
    // A newer exclusion must never be silently discarded into an include-all.
    if (filters.any((f) => f == null)) throw const FormatException('Unsupported station filter');
    return MusicStation(
      id: json['id'] as String,
      title: json['title'] as String,
      serverId: json['serverId'] as String,
      libraryId: json['libraryId'] as String,
      filters: filters.cast<LibraryFilter>(),
      sort: json['sort'] as String,
      descending: json['descending'] as bool,
      albums: json['albums'] as bool,
      trackLimit: json['trackLimit'] as int,
      durationMinutes: json['durationMinutes'] as int,
      storageLimitMiB: (json['storageLimitMiB'] ?? 0) as int,
      refreshHours: json['refreshHours'] as int,
      wifiOnly: json['wifiOnly'] as bool,
    );
  }

  bool acceptsBatch(
    List<MediaItem> tracks, {
    int? storageBudgetBytes,
    Map<String, int>? estimatedBytes,
    Set<String> alreadyOwned = const {},
  }) {
    if (tracks.length > trackLimit) return false;
    final seen = <String>{};
    var duration = 0, bytes = 0;
    final budget = storageBudgetBytes ?? storageLimitBytes;
    for (final track in tracks) {
      if (track.kind != MediaKind.track ||
          track.serverId != serverId ||
          track.libraryId != libraryId ||
          !seen.add(track.globalKey)) {
        return false;
      }
      if (durationMinutes > 0) {
        if (track.durationMs == null || track.durationMs! <= 0) return false;
        duration += track.durationMs!;
        if (duration > durationMinutes * 60000) return false;
      }
      if (budget != null && !alreadyOwned.contains(track.globalKey)) {
        final size = estimatedBytes == null ? musicTrackEstimatedBytes(track) : estimatedBytes[track.globalKey];
        if (size == null || size <= 0) return false;
        bytes += size;
        if (bytes > budget) return false;
      }
    }
    return true;
  }

  Future<List<MediaItem>> materialize(
    MediaServerClient client, {
    AbortController? abort,
    int? storageBudgetBytes,
    Set<String> alreadyOwned = const {},
  }) async {
    if (client.serverId.value != serverId) throw StateError('Station server changed');
    final authentication = client.authenticationSessionId;
    final accountScope = musicAccountScope(client);
    void checkCurrent() {
      abort?.throwIfAborted();
      if (!identical(authentication, client.authenticationSessionId) || accountScope != musicAccountScope(client)) {
        throw StateError('Station authorization changed');
      }
    }

    final result = <MediaItem>[], seen = <String>{}, seenContainers = <String>{};
    var offset = 0, duration = 0, bytes = 0;
    final storageBudget = storageBudgetBytes ?? storageLimitBytes;
    final durationLimit = durationMinutes * 60000;
    // Randomly ordered pages can repeat; bound work and dedupe rather than loop
    // forever on providers that ignore offsets or re-randomize each response.
    for (var pageIndex = 0; pageIndex < 50 && result.length < trackLimit; pageIndex++) {
      checkCurrent();
      final page = await client.fetchLibraryPagedContent(
        libraryId,
        query: LibraryQuery(
          kind: albums ? MediaKind.album : MediaKind.track,
          offset: offset,
          limit: 100,
          filters: filters,
          sort: LibrarySort(
            field: sort,
            direction: descending ? LibrarySortDirection.descending : LibrarySortDirection.ascending,
          ),
        ),
        abort: abort,
      );
      checkCurrent();
      var fresh = false;
      for (final item in page.items) {
        if (item.serverId != serverId ||
            item.libraryId != libraryId ||
            (albums ? item.kind != MediaKind.album : item.kind != MediaKind.track)) {
          continue;
        }
        if (!seenContainers.add(item.globalKey)) continue;
        fresh = true;
        final block = albums ? await client.fetchAlbumTracks(item.id) : [item];
        checkCurrent();
        final tracks = block
            .where(
              (t) =>
                  t.kind == MediaKind.track &&
                  t.serverId == serverId &&
                  t.libraryId == libraryId &&
                  !seen.contains(t.globalKey),
            )
            .toList();
        if (albums) {
          tracks.sort((a, b) {
            final disc = (a.parentIndex ?? 1).compareTo(b.parentIndex ?? 1);
            return disc != 0 ? disc : (a.index ?? 0).compareTo(b.index ?? 0);
          });
        }
        final blockDuration = tracks.fold<int>(0, (total, t) => total + (t.durationMs ?? 0));
        var blockBytes = 0;
        var knownSize = true;
        if (storageBudget != null) {
          for (final track in tracks) {
            if (alreadyOwned.contains(track.globalKey)) continue;
            final size = musicTrackEstimatedBytes(track);
            if (size == null) {
              knownSize = false;
              break;
            }
            blockBytes += size;
          }
        }
        if (!knownSize || storageBudget != null && bytes + blockBytes > storageBudget) continue;
        if (durationLimit > 0 && tracks.any((t) => t.durationMs == null || t.durationMs! <= 0)) continue;
        if (result.length + tracks.length > trackLimit ||
            durationLimit > 0 && duration + blockDuration > durationLimit) {
          if (albums) continue; // Never split an album to satisfy a budget.
          // A later track on this or the next page may still fit the budget.
          continue;
        }
        for (final track in tracks) {
          if (seen.add(track.globalKey)) result.add(track);
        }
        duration += blockDuration;
        bytes += blockBytes;
      }
      offset += page.items.length;
      if (!fresh || page.items.isEmpty || offset >= page.totalCount) break;
    }
    return result;
  }
}

int? musicTrackEstimatedBytes(MediaItem track) {
  final version = track.mediaVersions?.firstOrNull;
  if (version != null && version.parts.isNotEmpty && version.parts.every((part) => (part.sizeBytes ?? 0) > 0)) {
    return version.parts.fold<int>(0, (total, part) => total + part.sizeBytes!);
  }
  final duration = track.durationMs;
  if (duration == null || duration <= 0) return null;
  final bitrate = version?.bitrate;
  return (duration * (bitrate != null && bitrate > 0 ? bitrate : 1536) + 7) ~/ 8;
}
