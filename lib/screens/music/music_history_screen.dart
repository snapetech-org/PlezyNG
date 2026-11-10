import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/companion_remote_provider.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_library_store.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/plex_client.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/music_navigation.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';

typedef _HistorySource = ({MediaLibrary library, PlexClient client, Object authentication});

Iterable<_HistorySource> _serverHistorySources(BuildContext context, {required bool listen}) sync* {
  final servers = Provider.of<MultiServerProvider?>(context, listen: listen);
  final libraries = Provider.of<LibrariesProvider?>(context, listen: listen);
  final hidden = Provider.of<HiddenLibrariesProvider?>(context, listen: listen)?.hiddenLibraryKeys;
  if (servers == null || libraries == null || hidden == null) return;
  final online = servers.onlineServerIds.toSet();
  for (final library in libraries.libraries) {
    final server = library.serverId;
    if (server == null ||
        !online.contains(server) ||
        library.backend != MediaBackend.plex ||
        library.kind != MediaKind.artist ||
        library.hidden ||
        hidden.contains(library.globalKey)) {
      continue;
    }
    final client = servers.getPlexClientForServer(ServerId(server));
    if (client != null && client.supportsMusicServerHistory) {
      yield (library: library, client: client, authentication: client.authenticationSessionId);
    }
  }
}

class MusicHistoryScreen extends StatefulWidget {
  const MusicHistoryScreen({super.key});
  @override
  State<MusicHistoryScreen> createState() => _MusicHistoryScreenState();
}

class _MusicHistoryScreenState extends State<MusicHistoryScreen> {
  late final MusicLibraryStore _store = context.read<MusicExperience>().store;
  StreamSubscription<void>? _changes;
  Timer? _refreshTimer;
  List<MusicHistoryEntry> _entries = [];
  (int, String)? _cursor;
  int _pages = 1;
  bool _refreshPending = false;
  bool _loading = false;
  bool? _failedRefresh;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _changes = _store.historyChanges.listen((_) {
      _refreshTimer ??= Timer(const Duration(milliseconds: 150), () {
        _refreshTimer = null;
        unawaited(_load(refresh: true));
      });
    });
    unawaited(_load(refresh: true));
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    if (_loading) {
      _refreshPending |= refresh;
      return;
    }
    if (!refresh && _cursor == null) return;
    setState(() {
      _loading = true;
      _failedRefresh = null;
    });
    try {
      final page = refresh ? await _store.historyWindow(_pages) : await _store.historyPage(before: _cursor);
      if (!mounted) return;
      setState(() {
        if (!refresh) _pages++;
        _entries = refresh ? page.entries : [..._entries, ...page.entries];
        _cursor = page.cursor;
      });
    } catch (_) {
      if (mounted) setState(() => _failedRefresh = refresh);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_refreshPending) {
          _refreshPending = false;
          unawaited(_load(refresh: true));
        }
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final companion = context.watch<CompanionRemoteProvider?>();
    final profile = context.watch<ActiveProfileProvider?>();
    final sources = profile?.activeId == _store.profileId
        ? _serverHistorySources(context, listen: true).toList()
        : const <_HistorySource>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(t.musicTools.recent),
        actions: [
          if (sources.isNotEmpty)
            PopupMenuButton<_HistorySource>(
              tooltip: t.musicTools.serverHistory,
              icon: const AppIcon(Symbols.dns_rounded),
              itemBuilder: (_) => [
                for (final source in sources)
                  PopupMenuItem(
                    value: source,
                    child: Text('${source.library.title} · ${source.client.serverName ?? t.common.unknown}'),
                  ),
              ],
              onSelected: (source) {
                if (profile?.activeId != _store.profileId || !_store.active) return;
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => _ServerHistoryScreen(source: source, store: _store),
                    ),
                  ),
                );
              },
            ),
          if (companion?.supportsMusicHistory == true)
            IconButton(
              tooltip: '${t.homeLayout.sync}: ${companion!.connectedDevice?.name ?? t.companionRemote.unknownDevice}',
              icon: _syncing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const AppIcon(Symbols.sync_rounded),
              onPressed: _syncing
                  ? null
                  : () async {
                      setState(() => _syncing = true);
                      try {
                        final result = await companion.synchronizeMusicHistory();
                        if (context.mounted && !result) showErrorSnackBar(context, t.musicExperience.error);
                      } finally {
                        if (mounted) setState(() => _syncing = false);
                      }
                    },
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _entries.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) return Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.historyHint));
            if (index > _entries.length) {
              if (_loading) return const Center(child: CircularProgressIndicator());
              if (_failedRefresh case final refresh?) {
                return TextButton(
                  onPressed: () => _load(refresh: refresh),
                  child: Text(t.common.retry),
                );
              }
              if (_cursor != null) return TextButton(onPressed: _load, child: Text(t.fileSources.loadMore));
              return _entries.isEmpty
                  ? Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.noHistory))
                  : const SizedBox.shrink();
            }
            final entry = _entries[index - 1];
            return _HistoryTrackTile(
              key: ValueKey(entry.id),
              item: entry.item,
              date: entry.startedAt,
              onTap: () => playTrackWithAlbumContext(context, entry.item),
            );
          },
        ),
      ),
    );
  }
}

class _ServerHistoryScreen extends StatefulWidget {
  const _ServerHistoryScreen({required this.source, required this.store});

  final _HistorySource source;
  final MusicLibraryStore store;

  @override
  State<_ServerHistoryScreen> createState() => _ServerHistoryScreenState();
}

class _ServerHistoryScreenState extends State<_ServerHistoryScreen> {
  final Map<String, PlexMusicHistoryEntry> _entries = {};
  final _abort = AbortController();
  int? _next = 0;
  bool _loading = false;
  bool? _failedRefresh;

  bool _current({bool listen = false}) =>
      mounted &&
      widget.store.active &&
      Provider.of<ActiveProfileProvider?>(context, listen: listen)?.activeId == widget.store.profileId &&
      identical(widget.source.authentication, widget.source.client.authenticationSessionId) &&
      _serverHistorySources(context, listen: listen).any(
        (source) =>
            source.library.globalKey == widget.source.library.globalKey &&
            identical(source.client, widget.source.client),
      );

  @override
  void initState() {
    super.initState();
    unawaited(_load(refresh: true));
  }

  Future<void> _load({bool refresh = false}) async {
    final start = refresh ? 0 : _next;
    if (_loading || start == null || !_current()) return;
    setState(() {
      _loading = true;
      _failedRefresh = null;
    });
    try {
      final page = await widget.source.client.fetchMusicServerHistory(
        libraryId: widget.source.library.id,
        start: start,
        abort: _abort,
      );
      if (!_current()) return;
      setState(() {
        if (refresh) _entries.clear();
        for (final entry in page.entries) {
          _entries.putIfAbsent(entry.id, () => entry);
        }
        _next = page.nextStart;
      });
    } catch (_) {
      if (_current()) setState(() => _failedRefresh = refresh);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(PlexMusicHistoryEntry entry) async {
    if (!_current()) return;
    final music = context.read<MusicPlaybackService>();
    final intent = music.beginPlayIntent();
    bool current() => _current() && music.isPlayIntentCurrent(intent);
    try {
      final item = await widget.source.client.fetchItem(entry.item.id);
      if (!mounted || !current()) return;
      if (item == null ||
          item.kind != MediaKind.track ||
          item.id != entry.item.id ||
          item.serverId != entry.item.serverId ||
          item.libraryId != entry.item.libraryId) {
        throw StateError('History item no longer belongs to this library');
      }
      await playTracks(
        context,
        tracks: [item],
        playContext: MusicPlayContext(title: item.displayTitle, kind: MusicPlayContextKind.tracks),
      );
    } catch (_) {
      if (mounted && current()) showErrorSnackBar(context, t.musicExperience.error);
    }
  }

  @override
  void dispose() {
    _abort.abort();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current(listen: true);
    final entries = _entries.values.toList();
    return Scaffold(
      appBar: AppBar(title: Text(t.musicTools.serverHistory)),
      body: !current
          ? Center(child: Text(t.musicExperience.error))
          : RefreshIndicator(
              onRefresh: () => _load(refresh: true),
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: entries.length + 2,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ListTile(
                      title: Text(widget.source.library.title),
                      subtitle: Text(widget.source.client.serverName ?? t.common.unknown),
                    );
                  }
                  if (index <= entries.length) {
                    final entry = entries[index - 1];
                    return _HistoryTrackTile(
                      key: ValueKey(entry.id),
                      item: entry.item,
                      date: entry.playedAt,
                      onTap: () => _play(entry),
                    );
                  }
                  if (_loading) return const Center(child: CircularProgressIndicator());
                  if (_failedRefresh case final refresh?) {
                    return TextButton(
                      onPressed: () => _load(refresh: refresh),
                      child: Text(t.common.retry),
                    );
                  }
                  if (_next != null) return TextButton(onPressed: _load, child: Text(t.fileSources.loadMore));
                  return entries.isEmpty
                      ? Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.noHistory))
                      : const SizedBox.shrink();
                },
              ),
            ),
    );
  }
}

class _HistoryTrackTile extends StatelessWidget {
  const _HistoryTrackTile({super.key, required this.item, required this.date, required this.onTap});

  final MediaItem item;
  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final local = date.toLocal();
    final format = MaterialLocalizations.of(context);
    return ListTile(
      title: Text(item.displayTitle),
      subtitle: Text(
        '${item.trackArtistTitle ?? ''}\n${format.formatFullDate(local)} ${format.formatTimeOfDay(TimeOfDay.fromDateTime(local))}',
      ),
      isThreeLine: true,
      onTap: onTap,
    );
  }
}
