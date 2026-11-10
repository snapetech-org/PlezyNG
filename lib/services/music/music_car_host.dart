import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../screens/music/music_driving_screen.dart';
import '../../services/settings_service.dart';
import '../../utils/provider_extensions.dart';
import 'music_discovery.dart';
import 'music_playback_service.dart';
import 'music_library_store.dart';
import 'music_station.dart';
import 'music_background_frames.dart';
import 'music_offline_bundle.dart';
import 'music_playlist_loader.dart';

/// Profile-scoped native browse/command boundary. Native displays carry opaque
/// references and text; never media URLs, server tokens or filesystem paths.
class MusicCarHost extends StatefulWidget {
  const MusicCarHost({super.key, required this.navigatorKey, required this.child});
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  @override
  State<MusicCarHost> createState() => _MusicCarHostState();
}

class _MusicCarHostState extends State<MusicCarHost> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.pleazyng/music_car');
  static Object? _owner;
  final Object _identity = Object();
  final String _itemScope = const Uuid().v4();
  int _itemSequence = 0;
  late final MusicPlaybackService _music;
  late final String? _profileId;
  late final ActiveProfileProvider _profiles;
  final Map<String, MediaItem> _items = {};
  final Map<String, Object?> _authorizations = {};
  String? _queueShape, _catalogShape;
  final List<Listenable> _catalogSources = [];
  bool _catalogPending = false;
  bool _connected = false, _drivingOpen = false;
  Route<void>? _automaticDrivingRoute;
  int _catalogRevision = 0;

  bool get _current => mounted && identical(_owner, _identity) && _profiles.activeId == _profileId;

  @override
  void initState() {
    super.initState();
    _owner = _identity;
    _profiles = context.read<ActiveProfileProvider>();
    _profileId = _profiles.activeId;
    _music = context.read<MusicPlaybackService>()..addListener(_publish);
    for (final source in [
      context.read<MultiServerProvider?>(),
      context.read<LibrariesProvider?>(),
      context.read<DownloadProvider?>(),
      context.read<HiddenLibrariesProvider?>(),
    ].whereType<Listenable>()) {
      _catalogSources.add(source);
      source.addListener(_catalogChanged);
    }
    _catalogChanged();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_handle);
    unawaited(_send('ready').then((_) => _publish()));
  }

  Future<void> _send(String method, [Object? arguments]) async {
    if (!mounted || !_current) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      /* No car surface on this platform. */
    } on PlatformException {
      /* Native host can reconnect without affecting audio. */
    }
  }

  void _catalogChanged() {
    if (_catalogPending || !_current) return;
    _catalogPending = true;
    scheduleMicrotask(() {
      _catalogPending = false;
      if (!_current) return;
      final clients = context.read<MultiServerProvider?>()?.serverManager.visibleOnlineClients.values;
      final hidden = context.read<HiddenLibrariesProvider?>()?.hiddenLibraryKeys.toList() ?? <String>[];
      hidden.sort();
      final shape = jsonEncode([
        [
          for (final client in clients ?? <MediaServerClient>[])
            [client.serverId.value, client.serverName, identityHashCode(client.authenticationSessionId)],
        ],
        context.read<LibrariesProvider?>()?.libraries.map((library) => library.globalKey).toList(),
        context.read<DownloadProvider?>()?.downloadedTracks.map((track) => track.globalKey).toList(),
        hidden,
      ]);
      if (_catalogShape == shape) return;
      _catalogShape = shape;
      unawaited(_send('catalogChanged'));
    });
  }

  void _publish() {
    if (!mounted || !_current) return;
    final shape = jsonEncode([
      _music.queueSessionRevision,
      _music.currentIndex,
      _music.queue.map((item) => item.globalKey).toList(),
    ]);
    if (_queueShape != shape) {
      _queueShape = shape;
      _catalogRevision++;
    }
    unawaited(
      _send('snapshot', {
        'revision': _catalogRevision,
        'playing': _music.isPlaying,
        'index': _music.currentIndex,
        'title': _music.currentTrack?.displayTitle,
        'artist': _music.currentTrack?.trackArtistTitle,
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _music.removeListener(_publish);
    for (final source in _catalogSources) {
      source.removeListener(_catalogChanged);
    }
    _catalogSources.clear();
    if (identical(_owner, _identity)) {
      // The profile may already have changed. Clear the old native catalog
      // even though normal sends are now rejected by the profile guard.
      unawaited(_closeNativeCatalog());
      _channel.setMethodCallHandler(null);
      _owner = null;
      MusicBackgroundFrames.carConnected = false;
    }
    _items.clear();
    _authorizations.clear();
    super.dispose();
  }

  Future<void> _closeNativeCatalog() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on MissingPluginException {
      // No native car surface.
    } on PlatformException {
      // A detached native host has no catalog to clear.
    }
  }

  Map<String, Object?> _folder(String id, String title) => {'id': id, 'title': title, 'playable': false};
  Map<String, Object?> _item(MediaItem item) {
    final id = 'item:$_itemScope:${++_itemSequence}';
    // Bounded lookup table also invalidates stale native rows after a profile switch.
    if (_items.length >= 2000 && !_items.containsKey(id)) {
      final first = _items.keys.first;
      _items.remove(first);
      _authorizations.remove(first);
    }
    _items[id] = item;
    _authorizations[id] = context.getMediaClientForItemOrNull(item)?.authenticationSessionId;
    return {
      'id': id,
      'title': item.displayTitle,
      'subtitle': item.trackArtistTitle ?? item.albumTitle ?? '',
      'playable': item.kind == MediaKind.track,
      'kind': item.kind.name,
    };
  }

  bool _clientCurrent(MediaServerClient client, Object authentication) {
    if (!_current) return false;
    final manager = context.read<MultiServerProvider>().serverManager;
    return manager.isServerVisible(client.serverId) &&
        identical(manager.getClient(client.serverId), client) &&
        identical(authentication, client.authenticationSessionId);
  }

  Future<Object?> _handle(MethodCall call) async {
    if (!mounted || !_current || _profileId == null) throw PlatformException(code: 'profile_unavailable');
    final args = call.arguments is Map ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
    switch (call.method) {
      case 'browse':
        return _browse(args['id'] as String? ?? 'root');
      case 'search':
        final results = await _search(args['query'] as String? ?? '');
        return _current ? results.map(_item).toList() : [];
      case 'resolveVoice':
        final title = (args['query'] as String? ?? '').trim().toLowerCase();
        final artist = (args['artist'] as String? ?? '').trim().toLowerCase();
        final album = (args['album'] as String? ?? '').trim().toLowerCase();
        final kind = args['kind'] as String?;
        final results = await _search(args['query'] as String? ?? '');
        if (!mounted || !_current) return [];
        final resolved = results
            .where(
              (item) =>
                  item.displayTitle.trim().toLowerCase() == title &&
                  (artist.isEmpty ||
                      (item.trackArtistTitle ?? item.albumArtistTitle ?? '').trim().toLowerCase() == artist) &&
                  (album.isEmpty || (item.albumTitle ?? '').trim().toLowerCase() == album) &&
                  (kind == null || item.kind.name == kind),
            )
            .take(10)
            .map(_item)
            .toList();
        if (artist.isEmpty && album.isEmpty && (kind == null || kind == 'station' || kind == 'playlist')) {
          final store = MusicLibraryStore(context.read<AppDatabase>(), _profileId);
          final stations = await store.documents('station');
          final recipes = await MusicRecipeStore(store.database, _profileId).load();
          if (!_current) return [];
          resolved.addAll(
            stations
                .where(
                  (row) =>
                      row['id'] is String &&
                      row['title'] is String &&
                      (row['title'] as String).trim().toLowerCase() == title,
                )
                .map(
                  (row) => {'id': 'station:${row['id']}', 'title': row['title'], 'kind': 'station', 'playable': true},
                ),
          );
          resolved.addAll(
            recipes
                .where((recipe) => recipe.title.trim().toLowerCase() == title)
                .map(
                  (recipe) => {
                    'id': 'recipe:${recipe.id}',
                    'title': recipe.title,
                    'kind': 'playlist',
                    'playable': true,
                  },
                ),
          );
        }
        return resolved.take(10).toList();
      case 'playItem':
        final id = args['id'] as String? ?? '';
        if (id.startsWith('queue:')) {
          final parts = id.split(':');
          if (parts.length != 3 || int.tryParse(parts[1]) != _catalogRevision) {
            throw PlatformException(code: 'stale_queue');
          }
          final index = int.tryParse(parts[2]);
          if (index == null || index < 0 || index >= _music.queue.length) throw PlatformException(code: 'stale_queue');
          await _music.jumpTo(index);
        } else if (id.startsWith('station:')) {
          final intent = _music.beginPlayIntent();
          final row = await MusicLibraryStore(
            context.read<AppDatabase>(),
            _profileId,
          ).document('station', id.substring(8));
          if (!mounted || !_current || row == null) return false;
          final station = MusicStation.fromJson(row);
          final hidden = context.read<HiddenLibrariesProvider>();
          await hidden.ensureInitialized();
          if (!mounted || !_current || hidden.hiddenLibraryKeys.contains('${station.serverId}:${station.libraryId}')) {
            return false;
          }
          final client = context.read<MultiServerProvider>().getClientForServer(ServerId(station.serverId));
          final offline = client == null || client.isOfflineMode;
          final authentication = client?.authenticationSessionId;
          final downloads = context.read<DownloadProvider>().downloadedTracks;
          final tracks = offline
              ? musicSnapshotTracks(
                  await MusicLibraryStore(
                    context.read<AppDatabase>(),
                    _profileId,
                  ).document('stationSnapshot', station.id),
                  downloads,
                )
              : await station.materialize(client);

          if (!_current ||
              !_music.isPlayIntentCurrent(intent) ||
              client != null && !_clientCurrent(client, authentication!) ||
              tracks.isEmpty) {
            return false;
          }
          if (_enqueueRequested(tracks, args)) return true;
          await _music.playFromList(
            tracks: tracks,
            playContext: MusicPlayContext(title: station.title, kind: MusicPlayContextKind.mix),
            shuffle: args['shuffle'] == true,
            offline: offline,
          );
        } else if (id.startsWith('recipe:')) {
          final recipes = await MusicRecipeStore(context.read<AppDatabase>(), _profileId).load();
          if (!mounted || !_current) return false;
          final matching = recipes.where((recipe) => recipe.id == id.substring(7)).toList();
          if (matching.length != 1) throw PlatformException(code: 'stale_item');
          final intent = _music.beginPlayIntent();
          final tracks = await MusicDiscovery(
            (item) => context.getMediaClientForItemOrNull(item),
          ).generate(matching.single);
          if (!mounted || !_current || !_music.isPlayIntentCurrent(intent)) return false;
          if (_enqueueRequested(tracks, args)) return true;
          await _music.playFromList(
            tracks: tracks,
            playContext: MusicPlayContext(title: matching.single.title, kind: MusicPlayContextKind.mix),
            shuffle: args['shuffle'] == true,
          );
        } else {
          final item = _items[id];
          if (item == null) throw PlatformException(code: 'stale_item');
          final intent = _music.beginPlayIntent();
          final hidden = context.read<HiddenLibrariesProvider?>();
          await hidden?.ensureInitialized();
          if (!mounted ||
              !_current ||
              !_music.isPlayIntentCurrent(intent) ||
              hidden?.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}') == true) {
            return false;
          }
          final client = context.getMediaClientForItemOrNull(item);
          final authentication = client?.authenticationSessionId;
          if (client != null && !identical(_authorizations[id], authentication)) return false;
          final offlineTracks = context.read<DownloadProvider>().downloadedTracks;
          final downloaded = offlineTracks.where((track) => track.globalKey == item.globalKey).firstOrNull;
          if (client == null && downloaded == null && item.kind == MediaKind.track) return false;
          final tracks = item.kind == MediaKind.track
              ? [downloaded ?? item]
              : item.kind == MediaKind.album
              ? await client?.fetchAlbumTracks(item.id) ?? <MediaItem>[]
              : item.kind == MediaKind.artist
              ? await client?.fetchPlayableDescendants(item.id) ?? <MediaItem>[]
              : item.kind == MediaKind.playlist && client != null
              ? await loadMusicPlaylist(
                  client,
                  item.id,
                  current: () =>
                      _current && _music.isPlayIntentCurrent(intent) && _clientCurrent(client, authentication!),
                )
              : <MediaItem>[];
          if (!_current ||
              !_music.isPlayIntentCurrent(intent) ||
              tracks.isEmpty ||
              client != null && !_clientCurrent(client, authentication!)) {
            return false;
          }
          final playable = tracks
              .where(
                (track) =>
                    track.kind == MediaKind.track &&
                    track.serverId == item.serverId &&
                    hidden?.hiddenLibraryKeys.contains('${track.serverId}:${track.libraryId}') != true,
              )
              .toList();
          if (playable.isEmpty) return false;
          if (args['queue'] == 'next') {
            _music.addNext(playable);
            return true;
          }
          if (args['queue'] == 'later') {
            _music.addToEnd(playable);
            return true;
          }
          await _music.playFromList(
            tracks: playable,
            playContext: MusicPlayContext(
              title: item.displayTitle,
              kind: item.kind == MediaKind.album
                  ? MusicPlayContextKind.album
                  : item.kind == MediaKind.artist
                  ? MusicPlayContextKind.artist
                  : item.kind == MediaKind.playlist
                  ? MusicPlayContextKind.playlist
                  : MusicPlayContextKind.tracks,
            ),
            offline: downloaded != null && (client == null || client.isOfflineMode),
            shuffle: args['shuffle'] == true,
          );
        }
        if (args['repeat'] == 'one') _music.setRepeatMode(MusicRepeatMode.one);
        if (args['repeat'] == 'all') _music.setRepeatMode(MusicRepeatMode.all);
        return _music.isPlaying;
      case 'playSearch':
        final intent = _music.beginPlayIntent();
        final matches = await _handle(MethodCall('resolveVoice', args)) as List;
        if (!mounted || !_current || !_music.isPlayIntentCurrent(intent)) return false;
        if (matches.length != 1) throw PlatformException(code: 'ambiguous_search');
        return _handle(MethodCall('playItem', {...args, 'id': (matches.single as Map)['id']}));
      case 'jump':
        final index = args['index'] as int?;
        if (args['revision'] != _catalogRevision || index == null || index < 0 || index >= _music.queue.length) {
          throw PlatformException(code: 'stale_queue');
        }
        await _music.jumpTo(index);
        return true;
      case 'play':
        await _music.play();
        return _music.isPlaying;
      case 'pause':
        await _music.pause();
        return true;
      case 'next':
        await _music.next();
        return true;
      case 'previous':
        await _music.previous();
        return true;
      case 'connection':
        final connected = args['connected'] == true;
        if (_connected && !connected) await _music.pause();
        if (!connected) {
          final route = _automaticDrivingRoute;
          if (route != null && route.navigator != null) route.navigator!.removeRoute(route);
        }
        _connected = connected;
        MusicBackgroundFrames.carConnected = connected;
        if (connected) _openDrivingIfRequested();
        return true;
      default:
        throw MissingPluginException();
    }
  }

  bool _enqueueRequested(List<MediaItem> tracks, Map<String, dynamic> args) {
    if (args['queue'] == 'next') {
      _music.addNext(tracks);
      return true;
    }
    if (args['queue'] == 'later') {
      _music.addToEnd(tracks);
      return true;
    }
    return false;
  }

  static const _pageSize = 99;

  Map<String, Object?> _nextPage(String id, int offset) =>
      _folder('page:$offset:${base64Url.encode(utf8.encode(id))}', t.fileSources.loadMore);

  List<Map<String, Object?>> _page(Iterable<Map<String, Object?>> rows, String id, int offset) {
    final window = rows.skip(offset).take(_pageSize + 1).toList();
    return [...window.take(_pageSize), if (window.length > _pageSize) _nextPage(id, offset + _pageSize)];
  }

  Future<List<Map<String, Object?>>> _browse(String id) async {
    var offset = 0;
    if (id.startsWith('page:')) {
      final parts = id.split(':');
      if (parts.length != 3) throw PlatformException(code: 'invalid_page');
      offset = int.tryParse(parts[1]) ?? -1;
      if (offset < 0 || offset > 1000000) throw PlatformException(code: 'invalid_page');
      try {
        id = utf8.decode(base64Url.decode(parts[2]));
      } on FormatException {
        throw PlatformException(code: 'invalid_page');
      }
    }
    if (id == 'root') {
      return [
        _folder('queue', t.music.queue),
        _folder('offline', t.navigation.downloads),
        _folder('libraries', t.navigation.libraries),
        _folder('playlists', t.common.mediaKind.playlist),
        _folder('recipes', t.musicExperience.saved),
        _folder('stations', t.musicTools.stations),
        _folder('recent', t.musicTools.recent),
      ];
    }
    if (id == 'queue') {
      final queue = _music.queue;
      final start = _music.currentIndex.clamp(0, queue.length);
      return [
        for (var i = start + offset; i < queue.length && i < start + offset + _pageSize; i++)
          {
            'id': 'queue:$_catalogRevision:$i',
            'title': queue[i].displayTitle,
            'subtitle': queue[i].trackArtistTitle ?? '',
            'playable': true,
          },
        if (start + offset + _pageSize < queue.length) _nextPage(id, offset + _pageSize),
      ];
    }
    if (id == 'playlists') {
      final clients = context.read<MultiServerProvider>().serverManager.visibleOnlineClients.values;
      return _page(
        clients.map(
          (client) => _folder('playlists:${client.serverId.value}', client.serverName ?? client.serverId.value),
        ),
        id,
        offset,
      );
    }
    if (id.startsWith('playlists:')) {
      final client = context.read<MultiServerProvider>().getClientForServer(ServerId(id.substring(10)));
      if (client == null) return [];
      final authentication = client.authenticationSessionId;
      final page = await client.fetchPlaylistsPage(playlistType: 'audio', start: offset, size: _pageSize);
      if (!_current || !_clientCurrent(client, authentication)) return [];
      return [
        ...page.items
            .where((p) => p.playlistType == 'audio' && (p.serverId == null || p.serverId == client.serverId.value))
            .map(
              (p) => _item(
                MediaItem.fromJson({
                  'backend': p.backend.name,
                  'id': p.id,
                  'kind': 'playlist',
                  'title': p.title,
                  'serverId': client.serverId.value,
                }),
              ),
            ),
        if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
          _nextPage(id, offset + page.items.length),
      ];
    }
    if (id == 'offline') return _page(context.read<DownloadProvider>().downloadedTracks.map(_item), id, offset);
    if (id == 'recent') {
      final rows = await MusicLibraryStore(context.read<AppDatabase>(), _profileId!).recent(limit: 100);
      return _current ? _page(rows.map(_item), id, offset) : [];
    }
    if (id == 'stations') {
      final rows = await MusicLibraryStore(context.read<AppDatabase>(), _profileId!).documents('station', limit: 100);
      if (!_current) return [];
      return _page(
        rows
            .where((row) => row['id'] is String && row['title'] is String)
            .map((row) => {'id': 'station:${row['id']}', 'title': row['title'], 'playable': true}),
        id,
        offset,
      );
    }
    if (id == 'recipes') {
      final recipes = await MusicRecipeStore(context.read<AppDatabase>(), _profileId!).load();
      if (!mounted || !_current) return [];
      return _page(
        recipes.map((recipe) => {'id': 'recipe:${recipe.id}', 'title': recipe.title, 'playable': true}),
        id,
        offset,
      );
    }
    final hidden = context.read<HiddenLibrariesProvider>();
    await hidden.ensureInitialized();
    if (!mounted || !_current) return [];
    final libraries = context.read<LibrariesProvider>().libraries.where(
      (library) => library.kind == MediaKind.artist && !hidden.hiddenLibraryKeys.contains(library.globalKey),
    );
    if (id == 'libraries') {
      return _page(libraries.map((library) => _folder('library:${library.globalKey}', library.title)), id, offset);
    }
    if (id.startsWith('library:')) {
      final found = libraries.where((library) => 'library:${library.globalKey}' == id);
      if (found.isEmpty) return [];
      final library = found.first;
      final client = context.read<MultiServerProvider>().getClientForServer(ServerId(library.serverId!));
      if (client == null) return [];
      final authentication = client.authenticationSessionId;
      final page = await client.fetchLibraryPagedContent(
        library.id,
        query: LibraryQuery(
          kind: MediaKind.artist,
          limit: _pageSize,
          offset: offset,
          sort: const LibrarySort(field: 'title', direction: LibrarySortDirection.ascending),
        ),
      );
      if (!_current ||
          !_clientCurrent(client, authentication) ||
          hidden.hiddenLibraryKeys.contains(library.globalKey)) {
        return [];
      }
      return [
        ...page.items.map(_item),
        if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
          _nextPage(id, offset + page.items.length),
      ];
    }
    final item = _items[id];
    if (item == null) return [];
    final client = context.getMediaClientForItemOrNull(item);
    if (client == null || !identical(_authorizations[id], client.authenticationSessionId)) return [];
    final authentication = client.authenticationSessionId;
    if (item.kind == MediaKind.playlist) {
      final page = await client.fetchPlaylistPage(item.id, start: offset, size: _pageSize - 1);
      if (!_current || !_clientCurrent(client, authentication)) return [];
      return [
        {'id': id, 'title': t.common.play, 'playable': true},
        ...page.items.where((child) => child.kind == MediaKind.track && child.serverId == item.serverId).map(_item),
        if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
          _nextPage(id, offset + page.items.length),
      ];
    }
    final children = item.kind == MediaKind.artist
        ? await client.fetchArtistAlbums(item)
        : await client.fetchAlbumTracks(item.id);
    return _current &&
            _clientCurrent(client, authentication) &&
            !hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}')
        ? _page(children.where((child) => child.serverId == item.serverId).map(_item), id, offset)
        : [];
  }

  Future<List<MediaItem>> _search(String query) async {
    if (query.trim().isEmpty || query.length > 200) return [];
    final result = <String, MediaItem>{};
    final sources = <String, (MediaServerClient, Object)>{};
    final offlineKeys = <String>{};
    final hidden = context.read<HiddenLibrariesProvider>();
    await hidden.ensureInitialized();
    if (!mounted || !_current) return [];
    final normalized = query.trim().toLowerCase();
    for (final track in context.read<DownloadProvider>().downloadedTracks) {
      if (track.displayTitle.toLowerCase().contains(normalized) ||
          (track.trackArtistTitle ?? '').toLowerCase().contains(normalized)) {
        result[track.globalKey] = track;
        offlineKeys.add(track.globalKey);
      }
      if (result.length >= 100) break;
    }
    final clients = context.read<MultiServerProvider>().serverManager.visibleOnlineClients;
    for (final client in clients.values) {
      final authentication = client.authenticationSessionId;
      final excluded = context
          .read<LibrariesProvider>()
          .libraries
          .where((l) => l.serverId == client.serverId.value && hidden.hiddenLibraryKeys.contains(l.globalKey))
          .map((l) => l.id)
          .toSet();
      List<MediaItem> items;
      try {
        items = await client.searchItems(query, limit: 30, excludedLibraryIds: excluded);
      } catch (_) {
        // One unreachable server must not hide downloaded/other-server matches.
        continue;
      }
      if (!mounted || !_current) return [];
      if (!_clientCurrent(client, authentication)) continue;
      for (final item in items) {
        if (item.serverId == client.serverId.value &&
            const [MediaKind.track, MediaKind.album, MediaKind.artist, MediaKind.playlist].contains(item.kind) &&
            !hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}')) {
          result[item.globalKey] = item;
          sources[item.globalKey] = (client, authentication);
        }
      }
      if (result.length >= 100) break;
    }
    if (!_current) return [];
    return result.values
        .where((item) {
          if (offlineKeys.contains(item.globalKey)) return true;
          final source = sources[item.globalKey];
          return source != null &&
              _clientCurrent(source.$1, source.$2) &&
              !hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}');
        })
        .take(100)
        .toList();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _connected) _openDrivingIfRequested();
  }

  void _openDrivingIfRequested() {
    if (!mounted ||
        !_current ||
        _drivingOpen ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !(SettingsService.instanceOrNull?.read(SettingsService.musicAutoDriving) ?? false)) {
      return;
    }
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    _drivingOpen = true;
    final route = MaterialPageRoute<void>(builder: (_) => const MusicDrivingScreen());
    _automaticDrivingRoute = route;
    unawaited(
      navigator.push<void>(route).whenComplete(() {
        _drivingOpen = false;
        _automaticDrivingRoute = null;
      }),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
