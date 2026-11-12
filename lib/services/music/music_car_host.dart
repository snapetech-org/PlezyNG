import 'music_experience.dart';
import 'music_driving_routes.dart';
import 'music_system_audio_route_monitor.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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
import '../../utils/music_read_scope.dart';
import 'music_tracks_loader.dart';
import '../../utils/media_server_http_client.dart';
import 'music_car_artwork.dart';
import 'music_queue_controller.dart';
import 'music_discovery.dart';
import 'music_playback_service.dart';
import 'music_library_store.dart';
import 'music_station.dart';
import 'music_account_scope.dart';
import 'music_background_frames.dart';
import 'music_offline_bundle.dart';
import 'music_playlist_loader.dart';

/// Profile-scoped native browse/command boundary. Native displays carry opaque
/// references, text and bounded artwork bytes; never media URLs, server tokens or filesystem paths.
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
  final _carArtwork = MusicCarArtwork();
  final _artworkHttp = MediaServerHttpClient();
  final _artworkItems =
      <String, ({MediaItem item, MediaServerClient? client, Object? authentication, String? scope})>{};
  final Map<String, MediaItem> _items = {};
  final _authorizations =
      <String, ({MediaServerClient? client, Object? authentication, String? account, int generation})>{};
  Object? _queueShape;
  String? _catalogShape;
  final List<Listenable> _catalogSources = [];
  bool _catalogPending = false;
  MusicDrivingRoutes? _drivingRoutes;
  MusicSystemAudioRouteMonitor? _routeMonitor;
  bool _bluetoothConnected = false;
  bool _connected = false, _drivingOpen = false;
  Route<void>? _automaticDrivingRoute;
  int _catalogRevision = 0;

  bool get _current =>
      mounted &&
      identical(_owner, _identity) &&
      _profiles.activeId == _profileId &&
      !_profiles.isBinding &&
      _profiles.lastBindingSucceeded;

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
    _profiles.addListener(_drivingOwnerChanged);
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_handle);
    unawaited(_send('ready').then((_) => _publish()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routes = Provider.of<MusicExperience?>(context)?.drivingRoutes;
    if (identical(routes, _drivingRoutes)) return;
    _drivingRoutes?.removeListener(_bluetoothRouteChanged);
    _routeMonitor?.removeListener(_bluetoothRouteChanged);
    _routeMonitor?.dispose();
    _routeMonitor = null;
    _bluetoothConnected = false;
    _drivingRoutes = routes;
    if (routes != null) {
      routes.addListener(_bluetoothRouteChanged);
      _routeMonitor = MusicSystemAudioRouteMonitor(
        current: () => _current && !_profiles.isBinding && _profiles.lastBindingSucceeded,
      )..addListener(_bluetoothRouteChanged);
    }
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
            [
              client.serverId.value,
              client.serverName,
              identityHashCode(client.authenticationSessionId),
              musicAccountScope(client),
            ],
        ],
        context.read<LibrariesProvider?>()?.libraries.map((library) => library.globalKey).toList(),
        context.read<DownloadProvider?>()?.downloadedTracks.map((track) => track.globalKey).toList(),
        hidden,
      ]);
      if (_catalogShape == shape) return;
      _catalogShape = shape;
      _artworkItems.clear();
      _carArtwork.clear();
      unawaited(_send('catalogChanged'));
    });
  }

  void _publish() {
    if (!mounted || !_current) return;
    final queue = _music.queue;
    // Production snapshots change only when occurrences/order change. Status
    // updates must not decode a whole file-backed queue, and duplicate rows
    // must still retire old native positions after a reorder.
    final shape = (
      _music.queueSessionRevision,
      _music.currentIndex,
      queue is MusicQueueView ? queue : jsonEncode(queue.map((item) => item.globalKey).toList()),
    );
    if (_queueShape != shape) {
      _queueShape = shape;
      _catalogRevision++;
    }
    unawaited(
      _send('snapshot', {
        'scope': _itemScope,
        'labels': {
          'play': t.common.play,
          'pause': t.common.pause,
          'previous': t.music.previousTrack,
          'next': t.music.nextTrack,
        },
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
    _drivingRoutes?.removeListener(_bluetoothRouteChanged);
    _profiles.removeListener(_drivingOwnerChanged);
    _routeMonitor?.removeListener(_bluetoothRouteChanged);
    _routeMonitor?.dispose();
    final automatic = _automaticDrivingRoute;
    if (automatic != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        automatic.navigator?.removeRoute(automatic);
      });
    }
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
    _carArtwork.clear();
    _artworkItems.clear();
    _artworkHttp.close();
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
    _rememberArtwork(id, item);
    final client = context.getMediaClientForItemOrNull(item);
    _authorizations[id] = (
      client: client,
      authentication: client?.authenticationSessionId,
      account: client == null ? null : musicAccountScope(client),
      generation: _profiles.identityMutationGeneration,
    );
    return {
      'id': id,
      'title': item.displayTitle,
      'subtitle': item.trackArtistTitle ?? item.albumTitle ?? '',
      'playable': item.kind == MediaKind.track,
      'kind': item.kind.name,
      'artwork': true,
    };
  }

  void _rememberArtwork(String id, MediaItem item) {
    final client = context.getMediaClientForItemOrNull(item);
    if (_artworkItems.length >= 2000 && !_artworkItems.containsKey(id)) {
      _artworkItems.remove(_artworkItems.keys.first);
    }
    _artworkItems[id] = (
      item: item,
      client: client,
      authentication: client?.authenticationSessionId,
      scope: client == null ? null : musicAccountScope(client),
    );
  }

  Map<String, Object?> _queueItem(MediaItem item, int index) {
    final id = 'queue:$_catalogRevision:$index';
    _rememberArtwork(id, item);
    return {
      'id': id,
      'title': item.displayTitle,
      'subtitle': item.trackArtistTitle ?? '',
      'playable': true,
      'artwork': true,
    };
  }

  Future<Uint8List?> _artwork(Map<String, dynamic> args) async {
    final id = args['id'], size = args['size'];
    if (id is! String || id.length > 256 || size is! int || size < 32 || size > 256) return null;
    final owner = _artworkItems[id];
    if (owner == null) return null;
    final item = owner.item, client = owner.client;
    final downloads = context.read<DownloadProvider?>();
    final hidden = context.read<HiddenLibrariesProvider?>();
    await hidden?.ensureInitialized();
    bool current() {
      if (!_current ||
          _artworkItems[id] != owner ||
          hidden?.isLibraryHidden('${item.serverId}:${item.libraryId}') == true) {
        return false;
      }
      if (id.startsWith('queue:')) {
        final parts = id.split(':');
        final index = parts.length == 3 ? int.tryParse(parts[2]) : null;
        if (parts.length != 3 ||
            int.tryParse(parts[1]) != _catalogRevision ||
            index == null ||
            index < 0 ||
            index >= _music.queue.length ||
            _music.queue[index].globalKey != item.globalKey) {
          return false;
        }
      }
      if (client != null) {
        return client.backend == item.backend &&
            _clientCurrent(client, owner.authentication!) &&
            owner.scope == musicAccountScope(client);
      }
      return context.getMediaClientForItemOrNull(item) == null &&
          downloads?.downloadedTracks.any((row) => row.globalKey == item.globalKey && row.backend == item.backend) ==
              true;
    }

    if (!current()) return null;
    final path = item.thumbPath ?? item.parentThumbPath ?? item.grandparentThumbPath;
    if (path == null || path.isEmpty || item.serverId == null) return null;
    return _carArtwork.load(
      id: jsonEncode([id, owner.scope, path]),
      size: size,
      isCurrent: current,
      read: () async {
        if (!current()) return null;
        final local = downloads?.getArtworkLocalPath(ServerId(item.serverId!), path);
        if (local != null && await File(local).exists()) {
          if (!current()) return null;
          final builder = BytesBuilder(copy: false);
          await for (final chunk in File(local).openRead(0, MusicCarArtwork.maxInputBytes + 1)) {
            if (!current()) return null;
            builder.add(chunk);
            if (builder.length > MusicCarArtwork.maxInputBytes) return null;
          }
          return builder.takeBytes();
        }
        if (!current() || client == null || client.isOfflineMode) return null;
        final url = client.thumbnailUrl(path, width: size, height: size);
        if (url.isEmpty) return null;
        return _artworkHttp.getBytes(url, maxBytes: MusicCarArtwork.maxInputBytes, timeout: const Duration(seconds: 6));
      },
    );
  }

  bool _catalogItemCurrent(String id) {
    final owner = _authorizations[id];
    if (!_current || owner == null || owner.generation != _profiles.identityMutationGeneration) return false;
    final client = owner.client;
    return client == null ||
        _clientCurrent(client, owner.authentication!) && owner.account == musicAccountScope(client);
  }

  bool Function() _readClient(MediaServerClient client) {
    final authentication = client.authenticationSessionId, account = musicAccountScope(client);
    final generation = _profiles.identityMutationGeneration;
    return () =>
        _current &&
        generation == _profiles.identityMutationGeneration &&
        _clientCurrent(client, authentication) &&
        account == musicAccountScope(client) &&
        !client.isOfflineMode &&
        context.read<MultiServerProvider>().serverManager.isClientOnline(client.serverId);
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
      case 'transport':
        if (args['scope'] != _itemScope || args['revision'] != _catalogRevision) {
          throw PlatformException(code: 'stale_widget');
        }
        switch (args['command']) {
          case 'play':
            await _music.play();
          case 'pause':
            await _music.pause();
          case 'previous':
            await _music.previous();
          case 'next':
            await _music.next();
          default:
            throw PlatformException(code: 'invalid_transport');
        }
        return null;
      case 'artwork':
        return _artwork(args);
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
          final accountScope = client == null ? null : musicAccountScope(client);
          final downloads = context.read<DownloadProvider>().downloadedTracks;
          final tracks = offline
              ? musicSnapshotTracks(
                  await MusicLibraryStore(
                    context.read<AppDatabase>(),
                    _profileId,
                  ).document('stationSnapshot', station.id),
                  downloads,
                  accountScope: accountScope,
                )
              : await station.materialize(client);

          if (!_current ||
              !_music.isPlayIntentCurrent(intent) ||
              client != null && !_clientCurrent(client, authentication!) ||
              client != null && accountScope != musicAccountScope(client) ||
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
          final hidden = context.read<HiddenLibrariesProvider?>();
          final servers = context.read<MultiServerProvider>();
          await hidden?.ensureInitialized();
          final batch = await MusicDiscovery((item) {
            final server = serverIdOrNull(item.serverId);
            if (!_current ||
                !_music.isPlayIntentCurrent(intent) ||
                server == null ||
                !servers.isServerOnline(server) ||
                (item.libraryId != null && hidden?.isLibraryHidden('$server:${item.libraryId}') == true)) {
              return null;
            }
            return servers.getClientForServer(server);
          }).generate(matching.single);
          if (!batch.isCurrent()) return false;
          final tracks = batch.tracks;
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
          if (!_catalogItemCurrent(id)) return false;
          final client = _authorizations[id]!.client;
          final scope = await MusicReadScope.forItem(
            context,
            item,
            selectedClient: client,
            offline: client == null || client.isOfflineMode,
          );
          bool current() => _catalogItemCurrent(id) && _music.isPlayIntentCurrent(intent) && scope?.current == true;
          if (!current()) return false;
          final playable = scope!.offline
              ? scope.offlineTracks
              : item.kind == MediaKind.track
              ? [item]
              : item.kind == MediaKind.album || item.kind == MediaKind.artist
              ? await fetchMusicTracks(
                  client!,
                  item.id,
                  kind: item.kind,
                  current: current,
                  acceptsItem: scope.ownsTrack,
                )
              : item.kind == MediaKind.playlist
              ? await loadMusicPlaylist(client!, item.id, current: current, acceptsItem: scope.ownsTrack)
              : <MediaItem>[];
          if (!current() || playable.isEmpty) return false;
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
            offline: scope.offline,
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
        if (_connected && !connected) {
          await _music.pause();
          if (!_current) return false;
        }
        if (!connected && !_bluetoothConnected) {
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
        for (var i = start + offset; i < queue.length && i < start + offset + _pageSize; i++) _queueItem(queue[i], i),
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
      final current = _readClient(client);
      final page = await client.fetchPlaylistsPage(playlistType: 'audio', start: offset, size: _pageSize);
      if (!current()) return [];
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
                  'thumbPath': p.displayImagePath,
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
      final current = _readClient(client);
      final page = await client.fetchLibraryPagedContent(
        library.id,
        query: LibraryQuery(
          kind: MediaKind.artist,
          limit: _pageSize,
          offset: offset,
          sort: const LibrarySort(field: 'title', direction: LibrarySortDirection.ascending),
        ),
      );
      if (!current() || hidden.hiddenLibraryKeys.contains(library.globalKey)) {
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
    final client = _authorizations[id]?.client;
    if (client == null || !_catalogItemCurrent(id)) return [];
    if (item.kind == MediaKind.playlist) {
      final page = await client.fetchPlaylistPage(item.id, start: offset, size: _pageSize - 1);
      if (!_catalogItemCurrent(id)) return [];
      return [
        {'id': id, 'title': t.common.play, 'playable': true},
        ...page.items.where((child) => child.kind == MediaKind.track && child.serverId == item.serverId).map(_item),
        if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
          _nextPage(id, offset + page.items.length),
      ];
    }
    final LibraryPage<MediaItem> page;
    if (item.kind == MediaKind.artist) {
      if (client is ArtistAlbumPagingClient) {
        final albumPager = client as ArtistAlbumPagingClient;
        page = await albumPager.fetchArtistAlbumsPage(item, start: offset, size: _pageSize);
      } else {
        final albums = await client.fetchArtistAlbums(item);
        final safeOffset = offset.clamp(0, albums.length).toInt();
        final end = (safeOffset + _pageSize).clamp(0, albums.length).toInt();
        page = LibraryPage(items: albums.sublist(safeOffset, end), totalCount: albums.length, offset: offset);
      }
    } else if (item.kind == MediaKind.album) {
      page = await client.fetchMusicTracksPage(item.id, kind: MediaKind.album, start: offset, size: _pageSize);
    } else {
      final children = await client.fetchAlbumTracks(item.id);
      return _catalogItemCurrent(id) && !hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}')
          ? _page(children.where((child) => child.serverId == item.serverId).map(_item), id, offset)
          : [];
    }
    if (!_catalogItemCurrent(id) || hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}')) return [];
    return [
      ...page.items.where((child) => child.serverId == item.serverId).map(_item),
      if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
        _nextPage(id, offset + page.items.length),
    ];
  }

  Future<List<MediaItem>> _search(String query) async {
    if (query.trim().isEmpty || query.length > 200) return [];
    final result = <String, MediaItem>{};
    final sources = <String, bool Function()>{};
    final generation = _profiles.identityMutationGeneration;
    bool current() => _current && generation == _profiles.identityMutationGeneration;
    final offlineKeys = <String>{};
    final hidden = context.read<HiddenLibrariesProvider>();
    await hidden.ensureInitialized();
    if (!mounted || !current()) return [];
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
      final sourceCurrent = _readClient(client);
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
      if (!mounted || !current()) return [];
      if (!sourceCurrent()) continue;
      for (final item in items) {
        if (item.serverId == client.serverId.value &&
            const [MediaKind.track, MediaKind.album, MediaKind.artist, MediaKind.playlist].contains(item.kind) &&
            !hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}')) {
          result[item.globalKey] = item;
          sources[item.globalKey] = sourceCurrent;
        }
      }
      if (result.length >= 100) break;
    }
    if (!_current) return [];
    return result.values
        .where((item) {
          if (offlineKeys.contains(item.globalKey)) return true;
          final source = sources[item.globalKey];
          return source != null && source() && !hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}');
        })
        .take(100)
        .toList();
  }

  void _drivingOwnerChanged() {
    _routeMonitor?.refresh();
    if (!_current || _profiles.isBinding || !_profiles.lastBindingSucceeded) {
      final automatic = _automaticDrivingRoute;
      if (automatic != null) {
        // Profile notifications may arrive during a provider rebuild. Retire
        // only this host's automatic route after that frame has settled.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          automatic.navigator?.removeRoute(automatic);
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }
    }
  }

  void _bluetoothRouteChanged() {
    final monitor = _routeMonitor, routes = _drivingRoutes;
    if (!_current || monitor == null || routes == null) return;
    if (!monitor.foreground) {
      _bluetoothConnected = false;
      return;
    }
    final selected = monitor.value;
    if (selected == null) return; // Unknown is not a disconnect event.
    final wasConnected = _bluetoothConnected;
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    _bluetoothConnected = routes.matches(platform, selected);
    if (_bluetoothConnected && !wasConnected) _openDrivingIfRequested();
    if (wasConnected && !_bluetoothConnected && !_connected) {
      final route = _automaticDrivingRoute;
      if (route != null) route.navigator?.removeRoute(route);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _connected) _openDrivingIfRequested();
  }

  void _openDrivingIfRequested() {
    if (!mounted ||
        !_current ||
        (!_connected && !_bluetoothConnected) ||
        _profiles.isBinding ||
        !_profiles.lastBindingSucceeded ||
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
