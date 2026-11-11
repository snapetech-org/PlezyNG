import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_playlist.dart';
import '../media/media_server_client.dart';
import 'music/music_account_scope.dart';

/// Entry identity is independent of media identity: two copies of a song can
/// be selected and removed separately. Missing entry IDs never fall back.
String? playlistOccurrenceId(MediaItem item) => switch (item) {
  PlexMediaItem(:final playlistItemId?) when playlistItemId > 0 => 'p:$playlistItemId',
  JellyfinMediaItem(:final playlistItemId?) when playlistItemId.isNotEmpty => 'j:$playlistItemId',
  _ => null,
};

class PlaylistBatchRemovalResult {
  PlaylistBatchRemovalResult(Set<String> removed, this.error) : removed = Set.unmodifiable(removed);
  final Set<String> removed;
  final Object? error;
  bool get succeeded => error == null;
}

/// Removes explicitly selected occurrences, serially. Preflight uses current
/// server entries, not media IDs or stale array positions. A failed/uncertain
/// write stops the batch; callers reload before offering a user-driven retry.
Future<PlaylistBatchRemovalResult> removePlaylistOccurrences({
  required MediaServerClient client,
  required MediaPlaylist playlist,
  required List<MediaItem> selected,
  required bool Function() isCurrent,
}) async {
  if (playlist.smart ||
      playlist.playlistType != 'audio' ||
      playlist.serverId != client.serverId ||
      playlist.backend != client.backend ||
      !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(playlist.id) ||
      selected.isEmpty) {
    throw ArgumentError('Invalid playlist removal');
  }
  final ids = <String, MediaItem>{};
  for (final item in selected) {
    final id = playlistOccurrenceId(item);
    if (id == null ||
        item.backend != playlist.backend ||
        item.serverId != playlist.serverId ||
        item.kind != MediaKind.track ||
        ids.containsKey(id)) {
      throw ArgumentError('Invalid playlist occurrence');
    }
    ids[id] = item;
  }
  final authentication = client.authenticationSessionId;
  final scope = musicAccountScope(client);
  void requireCurrent() {
    if (!isCurrent() ||
        client.isOfflineMode ||
        !identical(authentication, client.authenticationSessionId) ||
        scope != musicAccountScope(client)) {
      throw StateError('Playlist source changed');
    }
  }

  final removed = <String>{};
  try {
    requireCurrent();
    final metadata = await client.fetchPlaylistMetadata(playlist.id);
    requireCurrent();
    if (metadata == null ||
        metadata.id != playlist.id ||
        metadata.serverId != playlist.serverId ||
        metadata.backend != playlist.backend ||
        metadata.smart ||
        metadata.playlistType != 'audio') {
      throw StateError('Playlist is no longer editable');
    }
    final entries = <String, MediaItem>{};
    var offset = 0;
    // Keep only selected entries; preflight does not retain a second queue.
    while (true) {
      requireCurrent();
      final page = await client.fetchPlaylistPage(playlist.id, start: offset, size: 200);
      requireCurrent();
      for (final item in page.items) {
        final id = playlistOccurrenceId(item);
        if (id == null || !ids.containsKey(id)) continue;
        if (entries.containsKey(id) ||
            item.id != ids[id]!.id ||
            item.backend != playlist.backend ||
            item.serverId != playlist.serverId ||
            item.kind != MediaKind.track) {
          throw StateError('Playlist occurrence changed');
        }
        entries[id] = item;
      }
      offset += page.items.length;
      if (page.items.isEmpty || offset >= page.totalCount) break;
    }
    requireCurrent();
    if (entries.length != ids.length) throw StateError('Selected playlist entries changed');
    for (final id in ids.keys) {
      requireCurrent();
      if (!await client.removeFromPlaylist(playlistId: playlist.id, item: entries[id]!)) {
        throw StateError('Playlist removal rejected');
      }
      removed.add(id);
      requireCurrent();
    }
    return PlaylistBatchRemovalResult(removed, null);
  } catch (error) {
    return PlaylistBatchRemovalResult(removed, error);
  }
}
