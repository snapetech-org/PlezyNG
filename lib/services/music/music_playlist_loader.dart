import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import 'music_account_scope.dart';
import 'music_queue_items.dart';

/// Native/voice selection preserves the complete ordered playlist in a bounded
/// metadata window. Duplicate occurrences remain distinct; a retired or invalid
/// page fails before playback ownership changes.
Future<List<MediaItem>> loadMusicPlaylist(
  MediaServerClient client,
  String id, {
  required bool Function() current,
  bool Function(MediaItem)? acceptsItem,
  int maxItems = 100000,
}) async {
  if (maxItems < 1 || maxItems > 100000) throw ArgumentError('Invalid playlist bound');
  final authentication = client.authenticationSessionId, account = musicAccountScope(client);
  void check() {
    if (!current() ||
        !identical(authentication, client.authenticationSessionId) ||
        account != musicAccountScope(client)) {
      throw StateError('Music playlist authorization changed');
    }
  }

  final tracks = MusicQueueItems(spill: true);
  var offset = 0;
  try {
    while (true) {
      check();
      final page = await client.fetchPlaylistPage(id, start: offset, size: 200);
      check();
      if (offset + page.items.length > maxItems || page.totalCount > maxItems) {
        throw StateError('Music playlist exceeds native selection budget');
      }
      if (page.offset != offset ||
          page.items.length > 200 ||
          page.totalCount < offset + page.items.length ||
          page.items.isEmpty && page.totalCount > offset) {
        throw const FormatException('Invalid native music playlist page');
      }
      if (page.items.any(
        (item) =>
            item.kind != MediaKind.track ||
            item.backend != client.backend ||
            item.serverId != client.serverId.value ||
            acceptsItem?.call(item) == false,
      )) {
        throw StateError('Native music playlist contains an unauthorized track');
      }
      tracks.addAll(page.items);
      offset += page.items.length;
      if (page.items.isEmpty || offset >= page.totalCount) return tracks.snapshot();
    }
  } finally {
    tracks.clear();
  }
}
