import '../../widgets/music/music_server_shelves.dart';
import '../../widgets/music/music_device_picker.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/download_provider.dart';
import '../../services/deep_links/deep_link_service.dart';
import '../../services/music/music_discovery.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_guest_dj.dart';
import '../../services/music/music_library_store.dart';
import '../../services/music/music_nfc_writer.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/music/music_station.dart';
import '../../services/music/music_tracks_loader.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/music/music_anniversary_shelf.dart';
import '../../widgets/music/music_favorites_shelf.dart';
import '../../widgets/music/music_pins_shelf.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/music_read_scope.dart';
import 'music_discovery_screen.dart';
import 'music_driving_screen.dart';
import 'music_prompt_screen.dart';
import 'music_station_screen.dart';
import 'music_audio_screen.dart';
import 'music_history_screen.dart';
import 'music_smart_playlist_screen.dart';
import 'music_reconciliation_screen.dart';
import 'music_shared_playlists_screen.dart';

Future<void> openMusicHome(BuildContext context) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MusicHomeScreen()));

/// A music lens over the existing session, downloads and discovery routes.
/// Shelves are independently ordered/hidden and saved for the active profile.
class MusicHomeScreen extends StatefulWidget {
  const MusicHomeScreen({super.key});
  @override
  State<MusicHomeScreen> createState() => _MusicHomeScreenState();
}

class _MusicHomeScreenState extends State<MusicHomeScreen> {
  late final MusicExperience _experience = context.read<MusicExperience>();
  late Future<void> _loadFuture;
  List<String> _order = [
    'pins',
    'server',
    'recent',
    'favorites',
    'anniversaries',
    'rediscover',
    'charts',
    'recipes',
    'stations',
    'downloads',
  ];
  final Set<String> _hidden = {};
  List<MediaItem> _recent = [], _rediscover = [];
  List<MusicChartEntry> _chart = [];
  List<MusicRecipe> _recipes = [];
  List<MusicStation> _stations = [];
  MusicChartGroup _group = MusicChartGroup.tracks;
  int _days = 30;
  bool _editing = false;
  bool _readingNfc = false;
  static const _nfc = MusicNfcWriter();
  late final Future<bool> _canReadNfc = _nfc.readAvailable;
  int _loadRevision = 0;
  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  Future<void> _readNfc() async {
    final profiles = context.read<ActiveProfileProvider>();
    final store = _experience.store;
    bool current() => mounted && store.active && profiles.activeId == store.profileId;
    if (_readingNfc || !current()) return;
    setState(() => _readingNfc = true);
    try {
      final link = await _nfc.read(prompt: t.musicTools.nfcRead);
      if (link != null && current()) DeepLinkService.instance.receive(link.toString());
    } catch (_) {
      if (mounted && current()) showErrorSnackBar(context, t.musicExperience.error);
    } finally {
      if (mounted) setState(() => _readingNfc = false);
    }
  }

  @override
  void dispose() {
    if (_readingNfc) unawaited(_nfc.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final revision = ++_loadRevision;
    final days = _days, group = _group;
    await _experience.recorder.flush();
    final store = _experience.store;
    final layout = await store.document('home', 'layout');
    final recent = await store.recent(), rediscover = await store.recent(rediscover: true);
    final now = DateTime.now();
    final chart = await store.chart(
      from: days == 0 ? DateTime(1970) : now.subtract(Duration(days: days)),
      until: now,
      group: group,
    );
    final recipes = await MusicRecipeStore(store.database, store.profileId).load();
    final stations = <MusicStation>[];
    for (final row in await store.documents('station')) {
      try {
        stations.add(MusicStation.fromJson(row));
      } on FormatException {
        continue;
      } on ArgumentError {
        continue;
      } on TypeError {
        continue;
      }
    }
    if (!mounted || revision != _loadRevision) return;
    if (layout != null) {
      final order = (layout['order'] as List? ?? []).whereType<String>().where(_order.contains).toSet();
      _order = [...order, ..._order.where((key) => !order.contains(key))];
      _hidden
        ..clear()
        ..addAll((layout['hidden'] as List? ?? []).whereType<String>());
    }
    _recent = recent;
    _rediscover = rediscover;
    _chart = chart;
    _recipes = recipes;
    _stations = stations;
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final future = _load();
    setState(() {
      _loadFuture = future;
    });
    await future;
  }

  Future<void> _saveLayout() =>
      _experience.store.saveDocument('home', 'layout', {'order': _order, 'hidden': _hidden.toList()});
  String _label(String key) => switch (key) {
    'pins' => t.musicTools.pins,
    'server' => t.libraries.tabs.recommended,
    'recent' => t.musicTools.recent,
    'favorites' => t.libraries.filterCategories.favorites,
    'anniversaries' => t.musicTools.anniversaries,
    'rediscover' => t.musicTools.rediscover,
    'charts' => t.musicTools.charts,
    'recipes' => t.musicExperience.saved,
    'stations' => t.musicTools.stations,
    _ => t.musicExperience.local,
  };
  Future<void> _playChart(MusicChartEntry entry, String title) async {
    final group = _group, music = _experience.music;
    final intent = music.beginPlayIntent();
    final seed = entry.item;
    final client = _experience.clientFor(seed);
    final authentication = client?.authenticationSessionId;
    final downloaded = context.read<DownloadProvider>().downloadedTracks;
    final offline = client == null || client.isOfflineMode;
    try {
      late final List<MediaItem> tracks;
      if (group == MusicChartGroup.tracks) {
        tracks = [seed];
      } else if (offline) {
        tracks = downloaded
            .where(
              (item) =>
                  item.serverId == seed.serverId &&
                  (group == MusicChartGroup.albums
                      ? item.parentId == seed.parentId
                      : item.grandparentId == seed.grandparentId),
            )
            .toList();
      } else {
        final online = client;
        final parentId = group == MusicChartGroup.albums ? seed.parentId : seed.grandparentId;
        if (parentId == null || parentId.isEmpty) return;
        final scope = await MusicReadScope.forItem(context, seed, selectedClient: online);
        if (scope == null) return;
        bool current() =>
            mounted &&
            _experience.store.active &&
            music.isPlayIntentCurrent(intent) &&
            identical(online, _experience.clientFor(seed)) &&
            identical(authentication, online.authenticationSessionId) &&
            scope.current;
        final kind = group == MusicChartGroup.albums ? MediaKind.album : MediaKind.artist;
        tracks = await fetchMusicTracks(
          online,
          parentId,
          kind: kind,
          current: current,
          acceptsItem: (item) =>
              scope.ownsTrack(item) &&
              (group == MusicChartGroup.albums ? item.parentId == parentId : item.grandparentId == parentId),
        );
      }
      if (!mounted ||
          !_experience.store.active ||
          !music.isPlayIntentCurrent(intent) ||
          !identical(client, _experience.clientFor(seed)) ||
          !identical(authentication, client?.authenticationSessionId)) {
        return;
      }
      if (tracks.isEmpty) throw StateError('No playable music');
      await music.playFromList(
        tracks: tracks,
        offline: offline,
        playContext: MusicPlayContext(
          title: title,
          kind: group == MusicChartGroup.albums
              ? MusicPlayContextKind.album
              : group == MusicChartGroup.artists
              ? MusicPlayContextKind.artist
              : MusicPlayContextKind.tracks,
        ),
      );
    } catch (_) {
      if (mounted) showAppSnackBar(context, t.musicExperience.error);
    }
  }

  Widget _tracks(List<MediaItem> items, String title, {bool offline = false}) => Column(
    children: [
      if (items.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.noHistory)),
      for (final item in items.take(30))
        ListTile(
          title: Text(item.displayTitle),
          subtitle: Text(item.trackArtistTitle ?? ''),
          leading: const AppIcon(Symbols.music_note_rounded),
          onTap: () => _experience.music.playFromList(
            tracks: items,
            startTrack: item,
            playContext: MusicPlayContext(title: title, kind: MusicPlayContextKind.tracks),
            offline: offline,
          ),
          trailing: IconButton(
            tooltip: t.musicExperience.title,
            icon: const AppIcon(Symbols.explore_rounded),
            onPressed: () => openMusicDiscovery(context, item),
          ),
        ),
    ],
  );

  Widget _shelf(String key) {
    final title = _label(key);
    return Card(
      key: ValueKey(key),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text(title, style: Theme.of(context).textTheme.titleLarge),
            trailing: _editing
                ? Switch(
                    value: !_hidden.contains(key),
                    onChanged: (value) async {
                      setState(() {
                        if (value) {
                          _hidden.remove(key);
                        } else {
                          _hidden.add(key);
                        }
                      });
                      await _saveLayout();
                    },
                  )
                : null,
          ),
          if (_editing && key == 'pins' && !_hidden.contains(key)) const MusicPinsShelf(editing: true),
          if (!_editing && !_hidden.contains(key))
            switch (key) {
              'pins' => MusicPinsShelf(key: ValueKey(_loadRevision)),
              'server' => MusicServerShelves(key: ValueKey(_loadRevision)),
              'recent' => _tracks(_recent, title),
              'favorites' => MusicFavoritesShelf(key: ValueKey(_loadRevision)),
              'anniversaries' => MusicAnniversaryShelf(key: ValueKey(_loadRevision)),
              'rediscover' => _tracks(_rediscover, title),
              'downloads' => _tracks(context.watch<DownloadProvider>().downloadedTracks, title, offline: true),
              'recipes' => Column(
                children: [
                  for (final recipe in _recipes)
                    ListTile(
                      title: Text(recipe.title),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => MusicDiscoveryScreen(seed: recipe.seeds.first, recipe: recipe),
                        ),
                      ),
                    ),
                ],
              ),
              'stations' => Column(
                children: [
                  for (final station in _stations)
                    ListTile(
                      title: Text(station.title),
                      onTap: () => Navigator.of(context)
                          .push<void>(MaterialPageRoute(builder: (_) => MusicStationScreen(station: station)))
                          .then((_) => _refresh()),
                    ),
                ],
              ),
              _ => Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 16,
                      children: [
                        DropdownButton<int>(
                          isExpanded: true,
                          value: _days,
                          items: [
                            for (final days in [7, 30, 365, 0])
                              DropdownMenuItem(
                                value: days,
                                child: Text(days == 0 ? t.common.viewAll : '$days ${t.musicTools.days}'),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              _days = value;
                              _refresh();
                            }
                          },
                        ),
                        DropdownButton<MusicChartGroup>(
                          isExpanded: true,
                          value: _group,
                          items: [
                            DropdownMenuItem(value: MusicChartGroup.tracks, child: Text(t.common.mediaKind.track)),
                            DropdownMenuItem(value: MusicChartGroup.albums, child: Text(t.common.mediaKind.album)),
                            DropdownMenuItem(value: MusicChartGroup.artists, child: Text(t.common.mediaKind.artist)),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              _group = value;
                              _refresh();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  for (var index = 0; index < _chart.length; index++)
                    ListTile(
                      leading: Text('${index + 1}'),
                      title: Text(switch (_group) {
                        MusicChartGroup.tracks => _chart[index].item.displayTitle,
                        MusicChartGroup.albums => _chart[index].item.albumTitle ?? _chart[index].item.displayTitle,
                        MusicChartGroup.artists =>
                          _chart[index].item.trackArtistTitle ?? _chart[index].item.displayTitle,
                      }),
                      subtitle: Text(
                        '${_chart[index].plays} · ${Duration(milliseconds: _chart[index].listenedMs).inMinutes} ${t.musicTools.minutes}',
                      ),
                      onTap: () => _playChart(_chart[index], title),
                    ),
                  if (_chart.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.noHistory)),
                  Padding(padding: const EdgeInsets.all(16), child: Text(t.musicTools.historyHint)),
                ],
              ),
            },
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final experience = context.watch<MusicExperience>();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.musicTools.home),
        actions: [
          const MusicDeviceButton(),
          IconButton(
            tooltip: t.homeLayout.sync,
            icon: const AppIcon(Symbols.sync_rounded),
            onPressed: () =>
                Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MusicReconciliationScreen())),
          ),
          IconButton(
            tooltip: t.musicTools.recent,
            icon: const AppIcon(Symbols.history_rounded),
            onPressed: () =>
                Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MusicHistoryScreen())),
          ),
          IconButton(
            tooltip: t.common.edit,
            icon: const AppIcon(Symbols.edit_rounded),
            onPressed: () => setState(() => _editing = !_editing),
          ),
          IconButton(tooltip: t.common.refresh, icon: const AppIcon(Symbols.refresh_rounded), onPressed: _refresh),
        ],
      ),
      body: FutureBuilder<void>(
        future: _loadFuture,
        builder: (context, snapshot) {
          final header = Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FutureBuilder<bool>(
                      future: _canReadNfc,
                      builder: (_, availability) => availability.data == true
                          ? FilledButton.tonalIcon(
                              icon: const AppIcon(Symbols.nfc_rounded),
                              onPressed: _readingNfc ? null : _readNfc,
                              label: Text(t.musicTools.nfcRead),
                            )
                          : const SizedBox.shrink(),
                    ),
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(
                        context,
                      ).push<void>(MaterialPageRoute(builder: (_) => const MusicSharedPlaylistsScreen())),
                      child: Text(t.musicTools.sharedPlaylists),
                    ),
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(
                        context,
                      ).push<void>(MaterialPageRoute(builder: (_) => const MusicSmartPlaylistScreen())),
                      child: Text(t.playlists.smartPlaylist),
                    ),
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(context)
                          .push<void>(MaterialPageRoute(builder: (_) => const MusicStationScreen()))
                          .then((_) => _refresh()),
                      child: Text(t.musicTools.stations),
                    ),
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(
                        context,
                      ).push<void>(MaterialPageRoute(builder: (_) => const MusicPromptScreen())),
                      child: Text(t.musicTools.prompt),
                    ),
                    FilledButton.tonal(
                      onPressed: () => openMusicDriving(context),
                      child: Text(t.musicExperience.driving),
                    ),
                    FilledButton.tonal(
                      onPressed: () =>
                          Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MusicAudioScreen())),
                      child: Text(t.settings.audio),
                    ),
                  ],
                ),
              ),
              ListTile(
                title: Text(t.musicTools.guestDj),
                subtitle: experience.dj.failure == null
                    ? null
                    : Text(
                        experience.dj.failure == 'unsupported'
                            ? t.musicExperience.unsupported
                            : experience.dj.failure == 'empty'
                            ? t.musicExperience.empty
                            : t.musicExperience.error,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButton<MusicDjMode>(
                  isExpanded: true,
                  value: experience.dj.mode,
                  items: [
                    for (final mode in MusicDjMode.values)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(
                          mode == MusicDjMode.off
                              ? t.common.off
                              : mode == MusicDjMode.friendganger
                              ? 'DJ Friendgänger'
                              : 'DJ ${mode.name[0].toUpperCase()}${mode.name.substring(1)}',
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) experience.dj.select(value);
                  },
                ),
              ),
              if (experience.dj.busy) const LinearProgressIndicator(),
            ],
          );
          if (snapshot.connectionState != ConnectionState.done || snapshot.hasError) {
            return ListView(
              children: [
                header,
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: snapshot.hasError
                      ? TextButton(onPressed: _refresh, child: Text(t.common.retry))
                      : const Center(child: CircularProgressIndicator()),
                ),
              ],
            );
          }
          final keys = _order.where((key) => _editing || !_hidden.contains(key)).toList();
          if (_editing) {
            return ReorderableListView(
              header: header,
              onReorderItem: (from, to) async {
                setState(() => _order.insert(to, _order.removeAt(from)));
                await _saveLayout();
              },
              children: keys.map(_shelf).toList(),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(children: [header, ...keys.map(_shelf)]),
          );
        },
      ),
    );
  }
}
