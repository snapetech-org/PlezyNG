import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import 'music_queue_items.dart';
import '../../utils/media_server_http_client.dart' show AbortController;

/// Read a complete logical album/artist queue without retaining every decoded
/// row. The caller pins the account, visibility and play intent for each page.
Future<List<MediaItem>> fetchMusicTracks(
  MediaServerClient client,
  String parentId, {
  required MediaKind kind,
  String? libraryId,
  required bool Function() current,
  required bool Function(MediaItem) acceptsItem,
  int pageSize = 200,
  AbortController? abort,
}) async {
  if (kind != MediaKind.album && kind != MediaKind.artist || pageSize < 1 || pageSize > 1000) {
    throw ArgumentError('Invalid music page request');
  }
  final buffer = MusicQueueItems(spill: true);
  try {
    await drainPages<MediaItem>(
      (start, size) async {
        if (!current()) throw StateError('Music source retired');
        final page = await client.fetchMusicTracksPage(
          parentId,
          kind: kind,
          libraryId: libraryId,
          start: start,
          size: size,
          abort: abort,
        );
        if (!current()) throw StateError('Music source retired');
        if (page.offset != start ||
            page.items.length > size ||
            page.totalCount < start + page.items.length ||
            page.items.isEmpty && page.totalCount > start) {
          throw const FormatException('Invalid music page bounds');
        }
        if (page.items.any((item) => !acceptsItem(item))) {
          throw StateError('Music page contains an unauthorized track');
        }
        return page;
      },
      pageSize: pageSize,
      accumulator: buffer,
    );
    return buffer.snapshot();
  } finally {
    buffer.clear();
  }
}
