import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../providers/download_provider.dart';
import '../../profiles/active_profile_provider.dart';
import '../../utils/content_utils.dart';
import '../../services/sync_rule_executor.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_library_store.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/music/music_station.dart';
import '../../services/music/music_offline_bundle.dart';
import '../../utils/media_server_http_client.dart' show AbortController;
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../libraries/filters_bottom_sheet.dart';

class MusicStationScreen extends StatefulWidget {
  const MusicStationScreen({super.key, this.station});
  final MusicStation? station;
  @override
  State<MusicStationScreen> createState() => _MusicStationScreenState();
}

class _MusicStationScreenState extends State<MusicStationScreen> {
  final _title = TextEditingController(), _limit = TextEditingController(), _minutes = TextEditingController();
  late final MusicExperience _experience = context.read<MusicExperience>();
  late final String _id = widget.station?.id ?? const Uuid().v4();
  String? _libraryKey;
  List<LibraryFilter> _filters = [];
  String _sort = 'random';
  bool _albums = false, _busy = false, _wifiOnly = true;
  int _refreshHours = 0;
  bool get _current => mounted && context.read<ActiveProfileProvider>().activeId == _experience.store.profileId;
  String? _error;
  List<MediaItem> _preview = [];
  AbortController? _abort;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    final rule = widget.station;
    _title.text = rule?.title ?? '';
    _limit.text = '${rule?.trackLimit ?? 100}';
    _minutes.text = '${rule?.durationMinutes ?? 0}';
    _libraryKey = rule == null ? null : '${rule.serverId}:${rule.libraryId}';
    _refreshHours = rule?.refreshHours ?? 0;
    _wifiOnly = rule?.wifiOnly ?? true;
    _filters = rule?.filters ?? [];
    _sort = rule?.sort ?? 'random';
    _albums = rule?.albums ?? false;
  }

  @override
  void dispose() {
    _revision++;
    _abort?.abort();
    _title.dispose();
    _limit.dispose();
    _minutes.dispose();
    super.dispose();
  }

  List<MediaLibrary> get _libraries {
    final hidden = context.read<HiddenLibrariesProvider>();
    return context
        .read<LibrariesProvider>()
        .libraries
        .where(
          (l) => l.kind == MediaKind.artist && l.serverId != null && !hidden.hiddenLibraryKeys.contains(l.globalKey),
        )
        .toList();
  }

  MediaLibrary? get _library => _libraries.where((l) => l.globalKey == _libraryKey).firstOrNull;
  MusicStation _station() {
    final library = _library;
    if (library == null) throw StateError('Select a library');
    return MusicStation(
      id: _id,
      title: _title.text.trim(),
      serverId: library.serverId!,
      libraryId: library.id,
      filters: _filters,
      sort: _sort,
      albums: _albums,
      refreshHours: _refreshHours,
      wifiOnly: _wifiOnly,
      trackLimit: int.parse(_limit.text),
      durationMinutes: int.parse(_minutes.text),
    );
  }

  Future<void> _run(Future<void> Function(int revision) action) async {
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(revision);
    } catch (_) {
      if (mounted && revision == _revision) setState(() => _error = t.musicExperience.error);
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _editFilters() => _run((revision) async {
    final library = _library;
    if (library == null) return;
    final client = context.tryGetMediaClientForServer(ServerId(library.serverId!));
    if (client == null) return;
    final plex = context.tryGetPlexClientForServer(ServerId(library.serverId!));
    final listing = await client.fetchLibraryFiltersWithValues(library.id, libraryKind: MediaKind.artist);
    if (!mounted || revision != _revision) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: Text(t.musicTools.rules)),
          body: FiltersBottomSheet(
            filters: listing.filters,
            selectedFilters: _filters,
            onFiltersChanged: (value) {
              _filters = value;
              _preview = [];
            },
            serverId: library.serverId!,
            libraryKey: library.id,
            cachedValues: listing.cachedValues,
            loadFilterValues: (filter) async => plex?.getFilterValues(filter.key) ?? [],
          ),
        ),
      ),
    );
  });
  Future<void> _generate() => _run((revision) async {
    final station = _station();
    final client = context.tryGetMediaClientForServer(ServerId(station.serverId));
    if (client == null || client.isOfflineMode) {
      final downloads = context.read<DownloadProvider>().downloadedTracks;
      final snapshot = await _experience.store.document('stationSnapshot', station.id);
      if (mounted && revision == _revision && _current) {
        setState(() => _preview = musicSnapshotTracks(snapshot, downloads));
      }
      return;
    }
    final authentication = client.authenticationSessionId;
    _abort?.abort();
    final abort = _abort = AbortController();
    final items = await station.materialize(client, abort: abort);
    if (!mounted ||
        revision != _revision ||
        !_current ||
        !identical(client, context.tryGetMediaClientForServer(ServerId(station.serverId))) ||
        !identical(authentication, client.authenticationSessionId)) {
      return;
    }
    setState(() => _preview = items);
  });
  Future<void> _save() => _run((_) async {
    final station = _station(), downloads = context.read<DownloadProvider>();
    await _experience.store.saveDocument('station', station.id, station.toJson());
    if (!_current) return;
    // Reuse Downloads' network scheduling, profile ownership and cleanup links.
    // A station refresh tops up downloads; it never silently deletes copies.
    final oldRules = downloads.syncRules.values
        .where(
          (rule) =>
              rule.targetType == ContentTypes.musicStation &&
              rule.ratingKey == station.id &&
              (rule.serverId != station.serverId || station.refreshHours == 0),
        )
        .toList();
    for (final rule in oldRules) {
      if (!_current) return;
      await downloads.deleteSyncRule(rule.globalKey);
    }
    if (!_current) return;
    if (station.refreshHours > 0) {
      await downloads.createSyncRule(
        serverId: ServerId(station.serverId),
        ratingKey: station.id,
        targetType: ContentTypes.musicStation,
        episodeCount: station.trackLimit,
        downloadFilter: SyncRuleFilter.all,
        downloadLinksInitialized: true,
      );
    }
    if (mounted && _current) showAppSnackBar(context, t.musicExperience.ready);
  });
  Future<void> _download() => _run((_) async {
    final client = _experience.clientFor(_preview.first);
    if (client == null) throw StateError('Server unavailable');
    await context.read<DownloadProvider>().queueListDownload(_preview, client);
    await _experience.store.saveDocument('stationSnapshot', _id, {
      'version': 1,
      'id': _id,
      'title': _title.text,
      'tracks': _preview.map((t) => musicIdentity(t).toJson()).toList(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (mounted) showAppSnackBar(context, t.musicExperience.ready);
  });

  @override
  Widget build(BuildContext context) {
    context.watch<LibrariesProvider>();
    context.watch<HiddenLibrariesProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(t.musicTools.stations)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _title,
            enabled: !_busy,
            decoration: InputDecoration(labelText: t.musicExperience.saveRecipe),
          ),
          DropdownButton<String>(
            isExpanded: true,
            value: _library?.globalKey,
            hint: Text(t.musicExperience.source),
            items: [
              for (final library in _libraries)
                DropdownMenuItem(
                  value: library.globalKey,
                  child: Text('${library.title} · ${library.serverName ?? library.serverId}'),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _libraryKey = value;
                    _filters = [];
                    _preview = [];
                  }),
          ),
          OutlinedButton(
            onPressed: _busy || _library == null ? null : _editFilters,
            child: Text('${t.musicTools.rules} (${_filters.length})'),
          ),
          DropdownButton<String>(
            value: _sort,
            items: [
              DropdownMenuItem(value: 'random', child: Text(t.common.shuffle)),
              DropdownMenuItem(value: 'title', child: Text(t.common.mediaKind.track)),
              DropdownMenuItem(value: 'addedAt', child: Text(t.musicTools.recent)),
              DropdownMenuItem(value: 'viewCount', child: Text(t.musicTools.charts)),
              DropdownMenuItem(value: 'lastViewedAt', child: Text(t.musicTools.rediscover)),
              DropdownMenuItem(value: 'rating', child: Text(t.libraries.sortLabels.rating)),
              DropdownMenuItem(value: 'originallyAvailableAt', child: Text(t.libraries.filterCategories.year)),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    if (value != null) _sort = value;
                    _preview = [];
                  }),
          ),
          SwitchListTile(
            title: Text(t.musicTools.albumBlocks),
            value: _albums,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                    _albums = v;
                    _preview = [];
                  }),
          ),
          TextField(
            controller: _limit,
            onChanged: (_) => setState(() => _preview = []),
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: t.musicExperience.trackLimit),
          ),
          TextField(
            controller: _minutes,
            onChanged: (_) => setState(() => _preview = []),
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: '${t.musicTools.minutes} (0–4320)'),
          ),
          DropdownButtonFormField<int>(
            initialValue: _refreshHours,
            decoration: InputDecoration(labelText: '${t.common.refresh} · ${t.navigation.downloads}'),
            items: [
              for (final hours in {0, 6, 12, 24, 48, 168, _refreshHours})
                DropdownMenuItem(
                  value: hours,
                  child: Text(hours == 0 ? t.common.off : '${hours * 60} ${t.musicTools.minutes}'),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    if (value != null) _refreshHours = value;
                  }),
          ),
          if (_refreshHours > 0)
            SwitchListTile(
              title: Text(t.settings.downloadOnWifiOnly),
              value: _wifiOnly,
              onChanged: _busy ? null : (value) => setState(() => _wifiOnly = value),
            ),
          if (_error != null) Text(_error!),
          if (_busy) const LinearProgressIndicator(),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(onPressed: _busy ? null : _generate, child: Text(t.common.preview)),
              FilledButton.tonal(onPressed: _busy ? null : _save, child: Text(t.common.save)),
              if (widget.station != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run((_) async {
                          final downloads = context.read<DownloadProvider>();
                          for (final rule
                              in downloads.syncRules.values
                                  .where(
                                    (rule) => rule.targetType == ContentTypes.musicStation && rule.ratingKey == _id,
                                  )
                                  .toList()) {
                            if (!_current) return;
                            await downloads.deleteSyncRule(rule.globalKey);
                          }
                          await _experience.store.deleteDocument('station', _id);
                          await _experience.store.deleteDocument('stationSnapshot', _id);
                          if (context.mounted) Navigator.of(context).pop();
                        }),
                  child: Text(t.common.delete),
                ),
            ],
          ),
          if (_preview.isNotEmpty)
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: () => _experience.music.playFromList(
                    tracks: _preview,
                    playContext: MusicPlayContext(title: _title.text, kind: MusicPlayContextKind.mix),
                  ),
                  child: Text(t.common.play),
                ),
                OutlinedButton(onPressed: _busy ? null : _download, child: Text(t.musicExperience.download)),
              ],
            ),
          for (final track in _preview)
            ListTile(
              title: Text(track.displayTitle),
              subtitle: Text(track.trackArtistTitle ?? ''),
              onTap: () => _experience.music.playFromList(
                tracks: _preview,
                startTrack: track,
                playContext: MusicPlayContext(title: _title.text, kind: MusicPlayContextKind.mix),
              ),
            ),
        ],
      ),
    );
  }
}
