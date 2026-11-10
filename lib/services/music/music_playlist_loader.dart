import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';

/// Native/voice selection resolves the complete ordered playlist before taking
/// playback ownership. Duplicate occurrences are intentional. A stale account
/// or an implausibly large response fails without replacing the current queue.
Future<List<MediaItem>> loadMusicPlaylist(
  MediaServerClient client,
  String id, {
  required bool Function() current,
  int maxItems = 100000,
}) async {
  if (maxItems < 1 || maxItems > 100000) throw ArgumentError('Invalid playlist bound');
  final authentication = client.authenticationSessionId;
  void check() {
    if (!current() || !identical(authentication, client.authenticationSessionId)) {
      throw StateError('Music playlist authorization changed');
    }
  }

  final tracks = <MediaItem>[];
  var offset = 0;
  while (true) {
    check();
    final page = await client.fetchPlaylistPage(id, start: offset, size: 200);
    check();
    if (offset + page.items.length > maxItems || page.totalCount > maxItems) {
      throw StateError('Music playlist exceeds native selection budget');
    }
    tracks.addAll(page.items.where((item) => item.kind == MediaKind.track && item.serverId == client.serverId.value));
    offset += page.items.length;
    if (page.items.isEmpty || offset >= page.totalCount) return tracks;
  }
}
