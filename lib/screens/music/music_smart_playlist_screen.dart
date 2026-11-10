import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/library_query.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_playlist.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/music/music_smart_playlist.dart';
import '../../services/plex_client.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../libraries/filters_bottom_sheet.dart';

class MusicSmartPlaylistScreen extends StatefulWidget {
  const MusicSmartPlaylistScreen({super.key, this.playlist});
  final MediaPlaylist? playlist;
  @override
  State<MusicSmartPlaylistScreen> createState() => _MusicSmartPlaylistScreenState();
}

class _MusicSmartPlaylistScreenState extends State<MusicSmartPlaylistScreen> {
  final _title = TextEditingController();
  final _query = TextEditingController(text: 'type=10&sort=random&limit=100');
  late final String? _profile = context.read<ActiveProfileProvider>().activeId;
  String? _libraryKey;
  bool _busy = false;
  String? _error;
  int _revision = 0;
  List<MediaItem> _preview = [];
  PlexClient? _loadedClient;
  Object? _loadedAuthentication;
  String? _loadedScope;

  List<MediaLibrary> get _libraries => context
      .read<LibrariesProvider>()
      .libraries
      .where(
        (library) =>
            library.backend == MediaBackend.plex &&
            library.kind == MediaKind.artist &&
            !library.hidden &&
            !context.read<HiddenLibrariesProvider>().hiddenLibraryKeys.contains(library.globalKey),
      )
      .toList();
  MediaLibrary? get _library => _libraries.where((library) => library.globalKey == _libraryKey).firstOrNull;
  PlexClient? get _client =>
      _library?.serverId == null ? null : context.tryGetPlexClientForServer(ServerId(_library!.serverId!));

  @override
  void initState() {
    super.initState();
    _title.text = widget.playlist?.title ?? '';
    if (widget.playlist != null) {
      _loadExisting();
    }
  }

  Future<void> _loadExisting() async {
    final playlist = widget.playlist!;
    final client = playlist.serverId == null ? null : context.tryGetPlexClientForServer(ServerId(playlist.serverId!));
    if (client == null) {
      setState(() => _error = t.musicExperience.error);
      return;
    }
    final authentication = client.authenticationSessionId;
    final scope = musicAccountScope(client);
    setState(() => _busy = true);
    try {
      final metadata = await client.fetchPlaylistMetadata(playlist.id);
      if (!mounted ||
          context.read<ActiveProfileProvider>().activeId != _profile ||
          !identical(authentication, client.authenticationSessionId) ||
          scope != musicAccountScope(client) ||
          !identical(client, context.tryGetPlexClientForServer(ServerId(playlist.serverId!)))) {
        return;
      }
      if (metadata == null ||
          !metadata.smart ||
          metadata.smartContent == null ||
          metadata.id != playlist.id ||
          metadata.serverId != playlist.serverId) {
        throw StateError('Smart playlist unavailable');
      }
      final rules = MusicSmartPlaylistRules.fromContent(metadata.smartContent!);
      final libraryKey = '${playlist.serverId}:${rules.libraryId}';
      if (!_libraries.any((library) => library.globalKey == libraryKey)) {
        throw StateError('Smart playlist library unavailable');
      }
      setState(() {
        _loadedClient = client;
        _loadedAuthentication = authentication;
        _loadedScope = scope;
        _libraryKey = libraryKey;
        _query.text = rules.query;
      });
    } catch (_) {
      if (mounted) setState(() => _error = t.musicExperience.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function(PlexClient, MusicSmartPlaylistRules, bool Function()) action) async {
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _error = null;
      _preview = [];
    });
    try {
      final library = _library;
      final client = _client;
      if (client == null || library == null) throw StateError('Select a music library');
      if (widget.playlist != null &&
          (!identical(client, _loadedClient) ||
              !identical(_loadedAuthentication, client.authenticationSessionId) ||
              _loadedScope != musicAccountScope(client))) {
        throw StateError('Smart playlist account changed');
      }
      final authentication = client.authenticationSessionId;
      final scope = musicAccountScope(client);
      final rules = MusicSmartPlaylistRules.fromQuery(libraryId: library.id, query: _query.text);
      bool current() =>
          mounted &&
          revision == _revision &&
          _profile == context.read<ActiveProfileProvider>().activeId &&
          _library?.globalKey == library.globalKey &&
          identical(client, _client) &&
          identical(authentication, client.authenticationSessionId) &&
          scope == musicAccountScope(client);
      if (!current()) return;
      await action(client, rules, current);
    } catch (_) {
      if (mounted && revision == _revision) setState(() => _error = t.musicExperience.error);
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _editFilters() => _run((client, rules, current) async {
    final listing = await client.fetchLibraryFiltersWithValues(rules.libraryId, libraryKind: MediaKind.artist);
    if (!mounted || !current()) return;
    List<LibraryFilter> selected = [];
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(t.musicTools.rules)),
          body: FiltersBottomSheet(
            filters: listing.filters,
            selectedFilters: selected,
            onFiltersChanged: (filters) => selected = filters,
            serverId: client.serverId,
            libraryKey: rules.libraryId,
            cachedValues: listing.cachedValues,
            loadFilterValues: (filter) => client.getFilterValues(filter.key),
          ),
        ),
      ),
    );
    if (!current() || selected.isEmpty) return;
    final added = MusicSmartPlaylistRules.fromFilters(
      libraryId: rules.libraryId,
      filters: selected,
    ).parameters.where((entry) => entry.$1 != 'type').toList();
    final existing = rules.parameters.where((entry) => !const {'type', 'sort', 'limit'}.contains(entry.$1)).toList();
    final combined = MusicSmartPlaylistRules(
      libraryId: rules.libraryId,
      parameters: [
        ...rules.parameters.where((entry) => const {'type', 'sort', 'limit'}.contains(entry.$1)),
        if (existing.isNotEmpty) ...[('push', '1'), ...existing, ('pop', '1'), ('and', '1')],
        ('push', '1'),
        ...added,
        ('pop', '1'),
      ],
    );
    setState(() => _query.text = combined.query);
  });

  Future<void> _save({bool copy = false}) => _run((client, rules, current) async {
    final playlist = await client.saveSmartMusicPlaylist(
      title: _title.text,
      rules: rules,
      playlist: copy ? null : widget.playlist,
      isCurrent: current,
    );
    if (!mounted || !current()) return;
    if (playlist == null) throw StateError('Smart playlist not saved');
    showAppSnackBar(context, t.playlists.created);
    Navigator.of(context).pop();
  });

  @override
  void dispose() {
    _revision++;
    _title.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LibrariesProvider>();
    context.watch<HiddenLibrariesProvider>();
    context.watch<MultiServerProvider>();
    context.watch<ActiveProfileProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(t.playlists.smartPlaylist)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _library?.globalKey,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.navigation.libraries),
            items: [
              for (final library in _libraries) DropdownMenuItem(value: library.globalKey, child: Text(library.title)),
            ],
            onChanged: _busy || widget.playlist != null
                ? null
                : (key) => setState(() {
                    _libraryKey = key;
                    _preview = [];
                  }),
          ),
          TextField(
            controller: _title,
            enabled: !_busy && widget.playlist == null,
            decoration: InputDecoration(labelText: t.metadataEdit.title),
          ),
          TextField(
            controller: _query,
            enabled: !_busy,
            minLines: 3,
            maxLines: 12,
            onChanged: (_) => setState(() => _preview = []),
            decoration: InputDecoration(labelText: t.musicTools.rules),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              TextButton(onPressed: _busy ? null : _editFilters, child: Text(t.musicTools.rules)),
              FilledButton.tonal(
                onPressed: _busy
                    ? null
                    : () => _run((client, rules, current) async {
                        final page = await client.previewSmartMusicPlaylist(rules);
                        if (current()) setState(() => _preview = page.items);
                      }),
                child: Text(t.common.preview),
              ),
              FilledButton(onPressed: _busy ? null : _save, child: Text(t.common.save)),
              if (widget.playlist != null)
                TextButton(onPressed: _busy ? null : () => _save(copy: true), child: Text(t.playlists.create)),
            ],
          ),
          for (final track in _preview)
            ListTile(title: Text(track.displayTitle), subtitle: Text(track.trackArtistTitle ?? '')),
        ],
      ),
    );
  }
}
