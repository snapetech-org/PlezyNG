import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
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
  late final MusicPlaybackService _music;
  late final String? _profileId;
  late final ActiveProfileProvider _profiles;
  final Map<String, MediaItem> _items = {};
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

  void _publish() {
    if (!mounted || !_current) return;
    unawaited(
      _send('snapshot', {
        'revision': ++_catalogRevision,
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
    if (identical(_owner, _identity)) {
      // The profile may already have changed. Clear the old native catalog
      // even though normal sends are now rejected by the profile guard.
      unawaited(_closeNativeCatalog());
      _channel.setMethodCallHandler(null);
      _owner = null;
    }
    _items.clear();
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
    final id = 'item:${base64Url.encode(utf8.encode(jsonEncode([_profileId, item.serverId, item.id])))}';
    // Bounded lookup table also invalidates stale native rows after a profile switch.
    if (_items.length >= 2000 && !_items.containsKey(id)) _items.remove(_items.keys.first);
    _items[id] = item;
    return {
      'id': id,
      'title': item.displayTitle,
      'subtitle': item.trackArtistTitle ?? item.albumTitle ?? '',
      'playable': item.kind == MediaKind.track,
    };
  }

  Future<Object?> _handle(MethodCall call) async {
    if (!mounted || !_current || _profileId == null) throw PlatformException(code: 'profile_unavailable');
    final args = call.arguments is Map ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
    switch (call.method) {
      case 'browse':
        return _browse(args['id'] as String? ?? 'root');
      case 'search':
        return (await _search(args['query'] as String? ?? '')).map(_item).toList();
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
          await _music.playFromList(
            tracks: tracks,
            playContext: MusicPlayContext(title: matching.single.title, kind: MusicPlayContextKind.mix),
          );
        } else {
          final item = _items[id];
          if (item == null || item.kind != MediaKind.track) throw PlatformException(code: 'stale_item');
          await _music.playFromList(
            tracks: [item],
            playContext: MusicPlayContext(title: item.displayTitle, kind: MusicPlayContextKind.tracks),
          );
        }
        return true;
      case 'playSearch':
        final query = args['query'] as String? ?? '';
        final intent = _music.beginPlayIntent();
        final matches = await _search(query);
        if (!mounted || !_current || !_music.isPlayIntentCurrent(intent)) return false;
        final exact = matches.where((item) => item.displayTitle.toLowerCase() == query.trim().toLowerCase()).toList();
        if (exact.length != 1) throw PlatformException(code: 'ambiguous_search');
        final item = exact.single;
        final client = context.getMediaClientForItemOrNull(item);
        final tracks = item.kind == MediaKind.track
            ? [item]
            : await client?.fetchPlayableDescendants(item.id) ?? <MediaItem>[];
        if (!mounted || !_current || !_music.isPlayIntentCurrent(intent)) return false;
        await _music.playFromList(
          tracks: tracks.where((item) => item.kind == MediaKind.track).toList(),
          playContext: MusicPlayContext(title: item.displayTitle, kind: MusicPlayContextKind.mix),
        );
        return true;
      case 'jump':
        final index = args['index'] as int?;
        if (args['revision'] != _catalogRevision || index == null || index < 0 || index >= _music.queue.length) {
          throw PlatformException(code: 'stale_queue');
        }
        await _music.jumpTo(index);
        return true;
      case 'play':
        await _music.play();
        return true;
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
        if (connected) _openDrivingIfRequested();
        return true;
      default:
        throw MissingPluginException();
    }
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
        _folder('recipes', t.musicExperience.saved),
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
    if (id == 'offline') return _page(context.read<DownloadProvider>().downloadedTracks.map(_item), id, offset);
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
      final page = await client?.fetchLibraryPagedContent(
        library.id,
        query: LibraryQuery(
          kind: MediaKind.artist,
          limit: _pageSize,
          offset: offset,
          sort: const LibrarySort(field: 'title', direction: LibrarySortDirection.ascending),
        ),
      );
      if (!_current || page == null) return [];
      return [
        ...page.items.map(_item),
        if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
          _nextPage(id, offset + page.items.length),
      ];
    }
    final item = _items[id];
    if (item == null) return [];
    final client = context.getMediaClientForItemOrNull(item);
    final children = item.kind == MediaKind.artist
        ? await client?.fetchArtistAlbums(item)
        : await client?.fetchAlbumTracks(item.id);
    return _current ? _page((children ?? []).map(_item), id, offset) : [];
  }

  Future<List<MediaItem>> _search(String query) async {
    if (query.trim().isEmpty || query.length > 200) return [];
    final result = <MediaItem>[];
    final hidden = context.read<HiddenLibrariesProvider>();
    await hidden.ensureInitialized();
    if (!mounted || !_current) return [];
    final clients = context.read<MultiServerProvider>().serverManager.visibleOnlineClients;
    for (final client in clients.values) {
      final excluded = context
          .read<LibrariesProvider>()
          .libraries
          .where((l) => l.serverId == client.serverId.value && hidden.hiddenLibraryKeys.contains(l.globalKey))
          .map((l) => l.id)
          .toSet();
      final items = await client.searchItems(query, limit: 30, excludedLibraryIds: excluded);
      if (!mounted || !_current) return [];
      result.addAll(
        items.where(
          (item) =>
              const [MediaKind.track, MediaKind.album, MediaKind.artist].contains(item.kind) &&
              !excluded.contains(item.libraryId),
        ),
      );
      if (result.length >= 100) break;
    }
    return result.take(100).toList();
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
