import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import 'music_account_scope.dart';
import 'music_discovery.dart';

/// Builds finite radio batches without ever admitting a partial album.
/// The owner supplies profile/visibility guards; this also pins the client actor.
Future<List<MediaItem>> buildSonicAlbumRadio({
  required MediaServerClient client,
  required MediaItem seed,
  required bool Function() current,
  required bool Function(MediaItem) acceptsAlbum,
  required bool Function(MediaItem) acceptsTrack,
  int limit = 500,
  double maxDistance = .25,
  Set<String> excludedAlbumIds = const {},
  Set<String> excludedTrackKeys = const {},
}) async {
  if (seed.kind != MediaKind.album ||
      seed.libraryId == null ||
      seed.libraryId!.isEmpty ||
      seed.serverId != client.serverId.value ||
      seed.backend != client.backend ||
      limit < 1 ||
      limit > 500 ||
      !maxDistance.isFinite ||
      maxDistance < 0 ||
      maxDistance > 1) {
    throw ArgumentError('Album radio requires one qualified album and bounded sonic settings');
  }
  if (client is! SonicMusicClient) throw UnsupportedError('Sonic album radio is unavailable');
  final sonic = client as SonicMusicClient;
  final authentication = client.authenticationSessionId;
  final account = musicAccountScope(client);
  void verify() {
    if (!current() ||
        client.isOfflineMode ||
        !identical(client.authenticationSessionId, authentication) ||
        musicAccountScope(client) != account ||
        !acceptsAlbum(seed)) {
      throw StateError('Album radio source changed');
    }
  }

  bool validAlbum(MediaItem album) =>
      album.kind == MediaKind.album &&
      album.serverId == seed.serverId &&
      album.backend == seed.backend &&
      album.libraryId == seed.libraryId &&
      acceptsAlbum(album);
  bool validTrack(MediaItem item, MediaItem album) =>
      item.kind == MediaKind.track &&
      item.serverId == seed.serverId &&
      item.backend == seed.backend &&
      item.libraryId == seed.libraryId &&
      item.parentId == album.id &&
      acceptsTrack(item);

  final result = <MediaItem>[];
  final seen = {...excludedAlbumIds};
  Future<void> addAlbum(MediaItem album, {bool requiredSeed = false}) async {
    verify();
    if (!validAlbum(album) || !seen.add(album.id)) return;
    final tracks = <MediaItem>[];
    int? total;
    var start = 0;
    while (true) {
      verify();
      final remaining = limit - result.length;
      final size = remaining.clamp(1, 200);
      final page = await client.fetchMusicTracksPage(album.id, kind: MediaKind.album, start: start, size: size);
      verify();
      if (!validAlbum(album) ||
          page.offset != start ||
          page.items.length > size ||
          page.totalCount < start + page.items.length ||
          (total != null && total != page.totalCount) ||
          (page.items.isEmpty && page.totalCount > start) ||
          page.items.any((item) => !validTrack(item, album))) {
        throw StateError('Invalid album radio page');
      }
      total ??= page.totalCount;
      if (total > remaining) {
        if (requiredSeed) throw StateError('The seed album exceeds the radio track budget');
        return;
      }
      tracks.addAll(page.items);
      start += page.items.length;
      if (start == total) break;
    }
    if (tracks.map((item) => item.globalKey).toSet().length != tracks.length) {
      throw StateError('Album radio contains duplicate album tracks');
    }
    if (requiredSeed && tracks.isEmpty) throw StateError('The seed album is empty');
    if (tracks.any((track) => excludedTrackKeys.contains(track.globalKey))) return;
    final ordered = tracks.indexed.toList()
      ..sort((a, b) {
        final disc = (a.$2.parentIndex ?? 1).compareTo(b.$2.parentIndex ?? 1);
        if (disc != 0) return disc;
        final track = (a.$2.index ?? 0x7fffffff).compareTo(b.$2.index ?? 0x7fffffff);
        return track != 0 ? track : a.$1.compareTo(b.$1);
      });
    result.addAll(ordered.map((entry) => entry.$2));
  }

  verify();
  await addAlbum(seed, requiredSeed: !excludedAlbumIds.contains(seed.id));
  if (result.length == limit) return result;
  final neighbors = await sonic.sonicallySimilar(seed.id, limit: 50, maxDistance: maxDistance);
  verify();
  if (neighbors.length > 50) throw StateError('Unbounded sonic album response');
  for (final album in neighbors) {
    if (result.length == limit) break;
    await addAlbum(album);
  }
  verify();
  return result;
}
