import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/playlist_batch_removal.dart';
import 'package:plezy/utils/media_server_http_client.dart';

MediaItem track(int entry, {String id = 'same-song', MediaBackend backend = MediaBackend.plex}) =>
    backend == MediaBackend.plex
    ? PlexMediaItem(id: id, kind: MediaKind.track, serverId: 'srv', playlistItemId: entry)
    : JellyfinMediaItem(
        id: id,
        kind: MediaKind.track,
        serverId: 'srv',
        playlistItemId: '$entry',
        dialect: backend == MediaBackend.emby ? MediaBrowserDialect.emby : MediaBrowserDialect.jellyfin,
      );

MediaPlaylist playlist(MediaBackend backend, {bool smart = false}) =>
    MediaPlaylist(id: '42', title: 'Playlist', playlistType: 'audio', serverId: 'srv', backend: backend, smart: smart);

class _Client implements MediaServerClient {
  _Client(this.backend, this.items);
  @override
  final MediaBackend backend;
  final List<MediaItem> items;
  final starts = <int>[];
  final removals = <String>[];
  @override
  Object authenticationSessionId = Object();
  @override
  bool isOfflineMode = false;
  @override
  ServerId get serverId => ServerId('srv');
  void Function()? onRead;
  Future<bool> Function(MediaItem)? onRemove;

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async => playlist(backend);
  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async {
    final offset = start ?? 0;
    starts.add(offset);
    final result = LibraryPage(
      items: items.skip(offset).take(size ?? 200).toList(),
      totalCount: items.length,
      offset: offset,
    );
    onRead?.call();
    return result;
  }

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) async {
    removals.add(playlistOccurrenceId(item)!);
    final accepted = await onRemove?.call(item) ?? true;
    if (accepted) items.removeWhere((entry) => playlistOccurrenceId(entry) == playlistOccurrenceId(item));
    return accepted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final backend in MediaBackend.values) {
    test('removes only selected occurrences on $backend, preserving repeated songs', () async {
      final client = _Client(backend, List.generate(4, (i) => track(i + 1, backend: backend)));
      final selected = [client.items[1], client.items[3]];
      final result = await removePlaylistOccurrences(
        client: client,
        playlist: playlist(backend),
        selected: selected,
        isCurrent: () => true,
      );
      expect(result.succeeded, isTrue);
      expect(result.removed, selected.map(playlistOccurrenceId).toSet());
      expect(client.items.map(playlistOccurrenceId), [
        playlistOccurrenceId(track(1, backend: backend)),
        playlistOccurrenceId(track(3, backend: backend)),
      ]);
    });
  }

  test('preflight pages before writing and preserves occurrence identity', () async {
    final client = _Client(MediaBackend.plex, List.generate(205, (i) => track(i + 1)));
    final result = await removePlaylistOccurrences(
      client: client,
      playlist: playlist(client.backend),
      selected: client.items.skip(203).toList(),
      isCurrent: () => true,
    );
    expect(result.succeeded, isTrue);
    expect(client.starts, [0, 200]);
    expect(client.removals, ['p:204', 'p:205']);
    expect(client.items.length, 203);
  });

  test('removed or replaced selected entries stop preflight before writes', () async {
    for (final entries in [
      [track(1)],
      [track(2, id: 'replacement')],
      [track(2), track(2)],
    ]) {
      final client = _Client(MediaBackend.plex, entries);
      final result = await removePlaylistOccurrences(
        client: client,
        playlist: playlist(client.backend),
        selected: [track(2)],
        isCurrent: () => true,
      );
      expect(result.succeeded, isFalse);
      expect(client.removals, isEmpty);
    }
  });

  test('missing, repeated and foreign entry identities are rejected locally', () async {
    final client = _Client(MediaBackend.plex, [track(1)]);
    for (final selection in [
      <MediaItem>[],
      [track(1), track(1)],
      [track(1, backend: MediaBackend.jellyfin)],
      [const PlexMediaItem(id: 'song', serverId: 'other', kind: MediaKind.track, playlistItemId: 1)],
      [const PlexMediaItem(id: 'song', serverId: 'srv', kind: MediaKind.track)],
    ]) {
      await expectLater(
        removePlaylistOccurrences(
          client: client,
          playlist: playlist(client.backend),
          selected: selection,
          isCurrent: () => true,
        ),
        throwsArgumentError,
      );
    }
    await expectLater(
      removePlaylistOccurrences(
        client: client,
        playlist: playlist(client.backend, smart: true),
        selected: [track(1)],
        isCurrent: () => true,
      ),
      throwsArgumentError,
    );
    expect(client.starts, isEmpty);
    expect(client.removals, isEmpty);
  });

  test('authentication change during preflight prevents all writes', () async {
    final client = _Client(MediaBackend.plex, [track(1)]);
    client.onRead = () => client.authenticationSessionId = Object();
    final result = await removePlaylistOccurrences(
      client: client,
      playlist: playlist(client.backend),
      selected: [track(1)],
      isCurrent: () => true,
    );
    expect(result.succeeded, isFalse);
    expect(client.removals, isEmpty);
  });

  test('mid-batch account switch stops remaining writes and preserves acknowledged receipt', () async {
    final client = _Client(MediaBackend.plex, [track(1), track(2)]);
    client.onRemove = (_) async {
      client.authenticationSessionId = Object();
      return true;
    };
    final result = await removePlaylistOccurrences(
      client: client,
      playlist: playlist(client.backend),
      selected: List.of(client.items),
      isCurrent: () => true,
    );
    expect(result.succeeded, isFalse);
    expect(result.removed, {'p:1'});
    expect(client.removals, ['p:1']);
  });

  for (final throws in [true, false]) {
    test('uncertain/rejected request throws=$throws stops without automatic retries', () async {
      final client = _Client(MediaBackend.plex, [track(1), track(2), track(3)]);
      client.onRemove = (item) async {
        if (playlistOccurrenceId(item) == 'p:2') {
          if (throws) throw StateError('Connection closed');
          return false;
        }
        return true;
      };
      final result = await removePlaylistOccurrences(
        client: client,
        playlist: playlist(client.backend),
        selected: List.of(client.items),
        isCurrent: () => true,
      );
      expect(result.succeeded, isFalse);
      expect(result.removed, {'p:1'});
      expect(client.removals, ['p:1', 'p:2']);
      expect(client.items.map(playlistOccurrenceId), ['p:2', 'p:3']);
    });
  }

  test('retired route or offline client does not read or write', () async {
    for (final offline in [true, false]) {
      final client = _Client(MediaBackend.plex, [track(1)])..isOfflineMode = offline;
      final result = await removePlaylistOccurrences(
        client: client,
        playlist: playlist(client.backend),
        selected: [track(1)],
        isCurrent: () => offline,
      );
      expect(result.succeeded, isFalse);
      expect(client.starts, isEmpty);
      expect(client.removals, isEmpty);
    }
  });
}
