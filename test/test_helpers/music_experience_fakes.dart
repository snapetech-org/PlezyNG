import 'dart:async';

import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/services/music/music_discovery.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import 'media_items.dart';
import 'stub_music_playback_service.dart';

MediaItem musicTrack(
  String id, {
  String server = 's',
  String album = 'album',
  String artist = 'Artist',
  int? durationMs = 60000,
  int? year = 2000,
  int index = 1,
  int disc = 1,
}) => testMediaItem(
  id: id,
  title: id,
  kind: MediaKind.track,
  serverId: server,
  libraryId: 'library',
  parentId: album,
  parentTitle: album,
  grandparentId: 'artist',
  grandparentTitle: artist,
  durationMs: durationMs,
  year: year,
  index: index,
  parentIndex: disc,
);

class ExperienceMusic extends StubMusicPlaybackService {
  List<MediaItem> items = [];
  int cursor = 0, occurrence = 0, session = 1;
  bool playing = true;
  final positions = StreamController<Duration>.broadcast(sync: true);
  final jumps = StreamController<Duration?>.broadcast(sync: true);
  @override
  MediaItem? get currentTrack => items.isEmpty ? null : items[cursor];
  @override
  List<MediaItem> get queue => List.of(items);
  @override
  int get currentIndex => items.isEmpty ? -1 : cursor;
  @override
  int get queueSessionRevision => session;
  @override
  int get playbackOccurrenceRevision => occurrence;
  @override
  MusicPlaybackStatus get status => playing ? MusicPlaybackStatus.playing : MusicPlaybackStatus.paused;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get playheadJumpStream => jumps.stream;
  void changed() => notifyListeners();
  void moveTo(int index) {
    cursor = index;
    occurrence++;
    changed();
  }

  @override
  void addNext(List<MediaItem> tracks) {
    items.insertAll(cursor + 1, tracks);
    changed();
  }

  @override
  void removeAt(int index) {
    items.removeAt(index);
    changed();
  }

  @override
  void dispose() {
    positions.close();
    jumps.close();
    super.dispose();
  }
}

class ExperienceClient implements MediaServerClient, SonicMusicClient, ScopedMediaServerClient {
  @override
  ServerId get serverId => ServerId('s');
  @override
  MediaBackend get backend => MediaBackend.plex;
  @override
  String get serverName => 'Test server';
  @override
  void close() {}
  @override
  Object authenticationSessionId = Object();
  @override
  String scopedServerId = 's/user';
  @override
  bool isOfflineMode = false;
  @override
  ServerCapabilities capabilities = const ServerCapabilities(numericUserRating: true, userFavorites: true);
  List<MediaItem> rows = [];
  Map<String, List<MediaItem>> albums = {};
  List<LibraryQuery> queries = [];
  Future<List<MediaItem>> Function(String)? sonic;
  Future<LibraryPage<MediaItem>> Function(LibraryQuery)? page;
  Future<void> Function()? onRate;
  final List<(String, Object)> mutations = [];
  final List<String> searches = [];
  @override
  Future<List<MediaItem>> sonicallySimilar(String id, {int limit = 100, double maxDistance = 0.25}) =>
      sonic?.call(id) ?? Future.value(rows);
  @override
  Future<List<MediaItem>> sonicPath({required String libraryId, required String startId, required String endId}) =>
      sonic?.call(startId) ?? Future.value(rows);
  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String id) async => rows;
  @override
  Future<List<MediaItem>> fetchAlbumTracks(String id) async => albums[id] ?? [];
  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    queries.add(query);
    return page == null ? LibraryPage(items: rows, totalCount: rows.length) : await page!(query);
  }

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 50,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    searches.add(query);
    return rows;
  }

  @override
  Future<void> rate(MediaItem item, double rating) async {
    mutations.add((item.globalKey, rating));
    await onRate?.call();
  }

  @override
  Future<void> setFavorite(MediaItem item, bool value) async {
    mutations.add((item.globalKey, value));
    await onRate?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
