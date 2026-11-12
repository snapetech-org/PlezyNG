import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/music/plex_received_playlists.dart';
import '../../services/plex_auth_service.dart';
import '../../services/plex_client.dart';
import '../../widgets/app_icon.dart';
import '../../utils/snackbar_helper.dart';
import '../playlist/playlist_detail_screen.dart';

class MusicSharedPlaylistsScreen extends StatefulWidget {
  const MusicSharedPlaylistsScreen({super.key, this.authFactory});
  final Future<PlexAuthService> Function()? authFactory;
  @override
  State<MusicSharedPlaylistsScreen> createState() => _MusicSharedPlaylistsScreenState();
}

class _Server {
  const _Server(this.client, this.current);
  final PlexClient client;
  final bool Function() current;
}

class _MusicSharedPlaylistsScreenState extends State<MusicSharedPlaylistsScreen> {
  List<_Server> _servers = [];
  List<PlexReceivedPlaylist> _items = [];
  String? _selected, _signature;
  Object _generation = Object();
  PlexAuthService? _auth;
  PlexReceivedPlaylists? _catalog;
  bool _loading = false, _opening = false, _more = false, _failed = false;
  int _offset = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final servers = context.watch<MultiServerProvider?>();
    final profiles = context.watch<ActiveProfileProvider?>();
    final clients =
        servers?.serverManager.visibleOnlineClients.values
            .whereType<PlexClient>()
            .where((client) => !client.isOfflineMode && client.plexAccountToken?.isNotEmpty == true)
            .toList() ??
        <PlexClient>[];
    final signature = [
      identityHashCode(servers),
      identityHashCode(profiles),
      profiles?.activeId,
      profiles?.identityMutationGeneration,
      profiles?.isBinding,
      profiles?.lastBindingSucceeded,
      profiles?.active?.plexAdmin,
      for (final client in clients)
        '${client.serverId}:${identityHashCode(client)}:${identityHashCode(client.authenticationSessionId)}:${musicAccountScope(client)}:${client.plexAccountToken.hashCode}',
    ].join('|');
    if (signature == _signature) return;
    _signature = signature;
    _servers = [];
    final profile = profiles?.activeId, generation = profiles?.identityMutationGeneration;
    final allowed =
        profiles != null &&
        profile != null &&
        !profiles.isBinding &&
        profiles.lastBindingSucceeded &&
        !(profiles.active?.isPlexHome == true && profiles.active?.plexAdmin != true);
    if (allowed && servers != null) {
      for (final client in clients) {
        final server = ServerId(client.serverId.value), token = client.plexAccountToken;
        _servers.add(
          _Server(
            client,
            () =>
                mounted &&
                !servers.isDisposed &&
                identical(context.read<MultiServerProvider?>(), servers) &&
                identical(context.read<ActiveProfileProvider?>(), profiles) &&
                profiles.activeId == profile &&
                profiles.identityMutationGeneration == generation &&
                !profiles.isBinding &&
                profiles.lastBindingSucceeded &&
                !(profiles.active?.isPlexHome == true && profiles.active?.plexAdmin != true) &&
                client.plexAccountToken == token &&
                servers.serverManager.isServerVisible(server) &&
                servers.serverManager.isClientOnline(server) &&
                identical(servers.serverManager.getClient(server), client),
          ),
        );
      }
    }
    if (!_servers.any((server) => server.client.serverId.value == _selected)) {
      _selected = _servers.firstOrNull?.client.serverId.value;
    }
    _start();
  }

  Future<void> _start() async {
    final generation = _generation = Object();
    _auth?.dispose();
    _auth = null;
    _catalog = null;
    final server = _servers.where((server) => server.client.serverId.value == _selected).firstOrNull;
    setState(() {
      _items = [];
      _offset = 0;
      _more = false;
      _failed = false;
      _loading = server != null;
      _opening = false;
    });
    if (server == null) return;
    bool current() => mounted && identical(_generation, generation) && server.current();
    try {
      final auth = await (widget.authFactory?.call() ?? PlexAuthService.create());
      if (!current()) {
        auth.dispose();
        return;
      }
      _auth = auth;
      final catalog = PlexReceivedPlaylists(client: server.client, auth: auth, isCurrent: current);
      await catalog.refresh();
      final page = await catalog.page();
      if (!current()) return;
      setState(() {
        _catalog = catalog;
        _items = page.items;
        _offset = page.nextOffset;
        _more = page.hasMore;
        _failed = page.failed > 0;
      });
    } catch (_) {
      if (current()) setState(() => _failed = true);
    } finally {
      if (mounted && identical(_generation, generation)) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final catalog = _catalog, generation = _generation;
    if (_loading || _opening || catalog == null || !catalog.current || !_more) return;
    setState(() => _loading = true);
    try {
      final page = await catalog.page(offset: _offset);
      if (!mounted || !identical(generation, _generation) || !catalog.current) return;
      setState(() {
        _items = [..._items, ...page.items];
        _offset = page.nextOffset;
        _more = page.hasMore;
        _failed |= page.failed > 0;
      });
    } catch (_) {
      if (mounted && identical(generation, _generation) && catalog.current) setState(() => _failed = true);
    } finally {
      if (mounted && identical(generation, _generation)) setState(() => _loading = false);
    }
  }

  Future<void> _open(PlexReceivedPlaylist entry) async {
    final catalog = _catalog;
    final generation = _generation;
    if (_opening || catalog == null || !entry.current || !catalog.current) return;
    setState(() => _opening = true);
    try {
      final playlist = await catalog.open(entry);
      if (!mounted || !entry.current || !catalog.current) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PlaylistDetailScreen(
            playlist: playlist,
            readOnly: true,
            isSourceCurrent: () => entry.current && catalog.current,
          ),
        ),
      );
    } catch (_) {
      if (mounted && entry.current) showErrorSnackBar(context, t.musicExperience.error);
    } finally {
      if (mounted && identical(_generation, generation)) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _generation = Object();
    _auth?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t.musicTools.sharedPlaylists, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: t.common.refresh,
          icon: const AppIcon(Symbols.refresh_rounded),
          onPressed: _loading || _opening ? null : _start,
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_servers.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey(_signature),
            initialValue: _selected,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.rateSheet.server),
            items: [
              for (final server in _servers)
                DropdownMenuItem(
                  value: server.client.serverId.value,
                  child: Text(
                    server.client.serverName ?? server.client.serverId.value,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _opening
                ? null
                : (id) {
                    if (id == null || id == _selected) return;
                    _selected = id;
                    _start();
                  },
          ),
        if (_loading) const LinearProgressIndicator(),
        if (_failed) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(t.musicExperience.error)),
        if (!_loading && !_failed && _items.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Text(t.musicTools.noHistory)),
        for (final entry in _items.where((entry) => entry.current))
          ListTile(
            key: ValueKey(entry.access.uri),
            title: Text(entry.playlist.title),
            subtitle: Text(entry.access.userName),
            leading: const AppIcon(Symbols.playlist_play_rounded),
            onTap: _opening ? null : () => _open(entry),
          ),
        if (_more) TextButton(onPressed: _loading || _opening ? null : _loadMore, child: Text(t.fileSources.loadMore)),
      ],
    ),
  );
}
