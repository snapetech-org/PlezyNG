import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_server_client.dart';
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
import '../../services/music/music_account_scope.dart';
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
  final _storage = TextEditingController();
  late final MusicExperience _experience = context.read<MusicExperience>();
  late final String _id = widget.station?.id ?? const Uuid().v4();
  String? _libraryKey;
  List<LibraryFilter> _filters = [];
  String _sort = 'random';
  bool _albums = false, _busy = false, _wifiOnly = true, _descending = true, _continuous = false;
  late final ActiveProfileProvider _profile;
  late final int _profileGeneration;
  int _refreshHours = 0;
  bool get _current =>
      mounted &&
      _experience.store.active &&
      identical(context.read<MusicExperience>(), _experience) &&
      identical(context.read<ActiveProfileProvider>(), _profile) &&
      _profile.activeId == _experience.store.profileId &&
      _profile.identityMutationGeneration == _profileGeneration &&
      !_profile.isBinding &&
      _profile.lastBindingSucceeded;
  String? _error;
  List<MediaItem> _preview = [];
  MusicStationBatch? _previewBatch;
  MediaServerClient? _previewClient;
  Object? _previewAuthentication;
  String? _previewAccountScope;
  bool _previewOffline = false;
  AbortController? _abort;
  int _revision = 0;
  String? _presetTitle;
  @override
  void initState() {
    super.initState();
    _profile = context.read<ActiveProfileProvider>();
    _profileGeneration = _profile.identityMutationGeneration;
    final rule = widget.station;
    _title.text = rule?.title ?? '';
    _limit.text = '${rule?.trackLimit ?? 100}';
    _minutes.text = '${rule?.durationMinutes ?? 0}';
    _storage.text = '${rule?.storageLimitMiB ?? 0}';
    _libraryKey = rule == null ? null : '${rule.serverId}:${rule.libraryId}';
    _refreshHours = rule?.refreshHours ?? 0;
    _wifiOnly = rule?.wifiOnly ?? true;
    _filters = rule?.filters ?? [];
    _sort = rule?.sort ?? 'random';
    _descending = rule?.descending ?? true;
    _continuous = rule?.continuous ?? false;
    _albums = rule?.albums ?? false;
  }

  @override
  void dispose() {
    _revision++;
    _abort?.abort();
    _title.dispose();
    _limit.dispose();
    _minutes.dispose();
    _storage.dispose();
    super.dispose();
  }

  List<MediaLibrary> get _libraries {
    final hidden = context.read<HiddenLibrariesProvider>();
    return context
        .read<LibrariesProvider>()
        .libraries
        .where(
          (l) =>
              l.kind == MediaKind.artist &&
              l.serverId != null &&
              !l.hidden &&
              !hidden.hiddenLibraryKeys.contains(l.globalKey),
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
      continuous: _continuous,
      serverId: library.serverId!,
      libraryId: library.id,
      filters: _filters,
      sort: _sort,
      descending: _descending,
      albums: _albums,
      refreshHours: _refreshHours,
      wifiOnly: _wifiOnly,
      trackLimit: int.parse(_limit.text),
      durationMinutes: int.parse(_minutes.text),
      storageLimitMiB: int.parse(_storage.text),
    );
  }

  Future<void> _run(Future<void> Function(int revision) action) async {
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_current) throw StateError('Station editor profile changed');
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
    if (client == null || client.isOfflineMode) return;
    final plex = context.tryGetPlexClientForServer(ServerId(library.serverId!));
    final authentication = client.authenticationSessionId;
    final scope = musicAccountScope(client);
    final kind = _albums ? MediaKind.album : MediaKind.track;
    bool current() =>
        _current &&
        revision == _revision &&
        _library?.globalKey == library.globalKey &&
        !client.isOfflineMode &&
        identical(context.tryGetMediaClientForServer(ServerId(library.serverId!)), client) &&
        identical(client.authenticationSessionId, authentication) &&
        scope == musicAccountScope(client);
    final listing = await client.fetchLibraryFiltersWithValues(library.id, libraryKind: kind);
    if (!mounted || !current()) return;
    List<LibraryFilter>? selected;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: Text(t.musicTools.rules)),
          body: FiltersBottomSheet(
            filters: listing.filters,
            selectedFilters: _filters,
            onFiltersChanged: (value) => selected = value,
            serverId: library.serverId!,
            libraryKey: library.id,
            cachedValues: listing.cachedValues,
            loadFilterValues: (filter) async {
              if (!current() || plex == null) return [];
              final values = await plex.getFilterValues(filter.key);
              return current() ? values : [];
            },
          ),
        ),
      ),
    );
    if (!current() || selected == null) return;
    setState(() {
      _filters = selected!;
      _preview = [];
    });
  });

  String _presetLabel(MusicStationPreset preset) => switch (preset) {
    MusicStationPreset.shuffledTracks => '${t.common.shuffle} · ${t.libraries.groupings.tracks}',
    MusicStationPreset.shuffledAlbums => t.musicExperience.shuffleAlbums,
    MusicStationPreset.leastPlayed => '${t.libraries.sortLabels.playCount} ↑',
    MusicStationPreset.oldestReleases => '${t.libraries.sortLabels.releaseDate} ↑',
  };

  void _applyPreset(MusicStationPreset preset) {
    setState(() {
      final label = _presetLabel(preset);
      if (_title.text.trim().isEmpty || _title.text == _presetTitle) _title.text = label;
      _presetTitle = label;
      if (_albums != preset.albums) _filters = [];
      _albums = preset.albums;
      _sort = preset.sort;
      _descending = preset.descending;
      _preview = [];
    });
  }

  Future<void> _generate() => _run((revision) async {
    setState(() {
      _preview = [];
      _previewBatch = null;
      _previewClient = null;
      _previewAuthentication = null;
      _previewAccountScope = null;
      _previewOffline = false;
    });
    final station = _station();
    final client = context.tryGetMediaClientForServer(ServerId(station.serverId));
    if (client == null || client.isOfflineMode) {
      final downloads = context.read<DownloadProvider>().downloadedTracks;
      final snapshot = await _experience.store.document('stationSnapshot', station.id);
      if (mounted && revision == _revision && _current) {
        setState(() {
          _previewOffline = true;
          _preview = musicSnapshotTracks(
            snapshot,
            downloads,
            accountScope: client == null ? null : musicAccountScope(client),
          ).where((track) => track.serverId == station.serverId && track.libraryId == station.libraryId).toList();
        });
      }
      return;
    }
    final authentication = client.authenticationSessionId;
    final accountScope = musicAccountScope(client);
    _abort?.abort();
    final abort = _abort = AbortController();
    final batch = await station.preview(
      client,
      abort: abort,
      current: () =>
          _current &&
          _library?.serverId == station.serverId &&
          _library?.id == station.libraryId &&
          identical(
            client,
            _experience.clientFor(
              MediaItem(
                id: station.id,
                backend: client.backend,
                kind: MediaKind.track,
                serverId: station.serverId,
                libraryId: station.libraryId,
              ),
            ),
          ),
    );
    final items = batch.tracks;
    if (!mounted ||
        revision != _revision ||
        !_current ||
        !identical(client, context.tryGetMediaClientForServer(ServerId(station.serverId))) ||
        !identical(authentication, client.authenticationSessionId) ||
        accountScope != musicAccountScope(client)) {
      return;
    }
    setState(() {
      _preview = items;
      _previewBatch = batch;
      _previewClient = client;
      _previewAuthentication = authentication;
      _previewAccountScope = accountScope;
    });
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
  bool get _previewSourceCurrent {
    final client = _previewClient;
    return _current &&
        _library != null &&
        !_previewOffline &&
        _preview.isNotEmpty &&
        _previewBatch?.isCurrent() == true &&
        client != null &&
        !client.isOfflineMode &&
        identical(client, _experience.clientFor(_preview.first)) &&
        identical(_previewAuthentication, client.authenticationSessionId) &&
        _previewAccountScope == musicAccountScope(client);
  }

  Future<void> _playPreview({MediaItem? startTrack}) => _run((_) async {
    if (!_current || _library == null) throw StateError('Station preview source changed');
    final candidates = _previewOffline
        ? musicSnapshotTracks({
            'version': 1,
            'tracks': _preview.map((track) => musicIdentity(track).toJson()).toList(),
          }, context.read<DownloadProvider>().downloadedTracks)
        : _previewSourceCurrent
        ? List<MediaItem>.of(_preview)
        : <MediaItem>[];
    final library = _library!;
    final tracks = candidates
        .where((track) => track.serverId == library.serverId && track.libraryId == library.id)
        .toList();
    if (tracks.isEmpty || startTrack != null && !tracks.any((track) => track.globalKey == startTrack.globalKey)) {
      throw StateError('Station preview is no longer playable');
    }
    if (!_previewOffline && _continuous) {
      final batch = _previewBatch;
      final music = _experience.music;
      if (batch == null || !batch.matches(_station()) || music is! MusicStationRadioControls) {
        throw StateError('Station radio preview changed');
      }
      final outcome = await (music as MusicStationRadioControls).playStationRadio(batch, startTrack: startTrack);
      if (outcome == InstantMixOutcome.empty) throw StateError('Station radio is empty');
      return;
    }
    await _experience.music.playFromList(
      tracks: tracks,
      startTrack: startTrack,
      offline: _previewOffline,
      playContext: MusicPlayContext(title: _title.text, kind: MusicPlayContextKind.mix),
    );
  });

  Future<void> _download() => _run((_) async {
    if (_preview.isEmpty) return;
    final tracks = List<MediaItem>.of(_preview);
    final client = _previewClient;
    bool sourceCurrent() => _previewSourceCurrent;
    if (!sourceCurrent()) throw StateError('Station preview source changed');
    await context.read<DownloadProvider>().queueListDownload(tracks, client!, sourceCurrent: sourceCurrent);
    if (!sourceCurrent()) return;
    await _experience.store.completeStationSnapshot(_id, {
      'version': 1,
      'id': _id,
      'title': _title.text,
      'accountScope': _previewAccountScope,
      'tracks': tracks.map((t) => musicIdentity(t).toJson()).toList(),
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
          if (widget.station == null)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final preset in MusicStationPreset.values)
                  ActionChip(label: Text(_presetLabel(preset)), onPressed: _busy ? null : () => _applyPreset(preset)),
              ],
            ),
          TextField(
            controller: _title,
            onChanged: (_) => setState(() => _preview = []),
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
            isExpanded: true,
            value: _sort,
            items: [
              DropdownMenuItem(value: 'random', child: Text(t.common.shuffle)),
              DropdownMenuItem(value: 'title', child: Text(t.libraries.sortLabels.title)),
              DropdownMenuItem(value: 'addedAt', child: Text(t.libraries.sortLabels.dateAdded)),
              DropdownMenuItem(value: 'viewCount', child: Text(t.libraries.sortLabels.playCount)),
              DropdownMenuItem(value: 'lastViewedAt', child: Text(t.libraries.sortLabels.datePlayed)),
              DropdownMenuItem(value: 'rating', child: Text(t.libraries.sortLabels.rating)),
              DropdownMenuItem(value: 'originallyAvailableAt', child: Text(t.libraries.sortLabels.releaseDate)),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    if (value != null) _sort = value;
                    _preview = [];
                  }),
          ),
          if (_sort != 'random')
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('0 → 9')),
                ButtonSegment(value: true, label: Text('9 → 0')),
              ],
              selected: {_descending},
              onSelectionChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _descending = value.single;
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
                    _filters = [];
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
          TextField(
            controller: _storage,
            onChanged: (_) => setState(() => _preview = []),
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: t.musicTools.storageBudget),
          ),
          DropdownButtonFormField<int>(
            isExpanded: true,
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
                    _preview = [];
                  }),
          ),
          if (_refreshHours > 0)
            SwitchListTile(
              title: Text(t.settings.downloadOnWifiOnly),
              value: _wifiOnly,
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _wifiOnly = value;
                      _preview = [];
                    }),
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
                          await _experience.store.deleteDocument('stationPending', _id);
                          if (context.mounted) Navigator.of(context).pop();
                        }),
                  child: Text(t.common.delete),
                ),
            ],
          ),
          SwitchListTile(
            title: Text(t.musicTools.continueStation),
            value: _continuous,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _continuous = value;
                    _preview = [];
                  }),
          ),
          if (_preview.isNotEmpty)
            Wrap(
              spacing: 12,
              children: [
                FilledButton(onPressed: _busy ? null : _playPreview, child: Text(t.common.play)),
                OutlinedButton(
                  onPressed: _busy || _previewOffline ? null : _download,
                  child: Text(t.musicExperience.download),
                ),
              ],
            ),
          for (final track in _preview)
            ListTile(
              title: Text(track.displayTitle),
              subtitle: Text(track.trackArtistTitle ?? ''),
              onTap: _busy ? null : () => _playPreview(startTrack: track),
            ),
        ],
      ),
    );
  }
}
