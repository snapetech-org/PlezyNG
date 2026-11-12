import '../../services/music/music_experience.dart';
import '../../widgets/music/driving_routes_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../widgets/app_icon.dart';
import '../../services/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/music/music_discovery.dart';
import '../../services/music/music_account_scope.dart';
import '../../services/music/music_playback_service.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/music/track_row.dart';

Future<void> openMusicDiscovery(BuildContext context, MediaItem seed) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => MusicDiscoveryScreen(seed: seed)));

/// Seed editor, sonic paths, related tracks and saved recipes all use existing
/// server clients, track menus, download ownership and the one music session.
class MusicDiscoveryScreen extends StatefulWidget {
  const MusicDiscoveryScreen({super.key, required this.seed, this.recipe});
  final MediaItem seed;
  final MusicRecipe? recipe;
  @override
  State<MusicDiscoveryScreen> createState() => _MusicDiscoveryScreenState();
}

class _MusicDiscoveryScreenState extends State<MusicDiscoveryScreen> {
  late final List<MediaItem> _seeds = List.of(widget.recipe?.seeds ?? [widget.seed]);
  final _query = TextEditingController();
  final _name = TextEditingController();
  List<MediaItem> _results = [];
  bool Function()? _resultsCurrent;
  MusicDiscoveryBatch? _preview;
  List<MusicRecipe> _saved = [];
  MusicRecipeKind _kind = MusicRecipeKind.mix;
  int _limit = 100, _pathTracks = 50, _generation = 0;
  double _maxDistance = .25;
  String? _recipeId;
  bool _busy = false;
  bool _recipesLoaded = false;
  String? _error;
  late final ActiveProfileProvider _profile;
  late final String? _profileId;
  late final int _profileGeneration;
  MusicRecipeStore? get _store => _profileId == null ? null : MusicRecipeStore(context.read<AppDatabase>(), _profileId);
  bool get _currentProfile =>
      mounted &&
      identical(context.read<ActiveProfileProvider>(), _profile) &&
      _profile.activeId == _profileId &&
      _profile.identityMutationGeneration == _profileGeneration &&
      !_profile.isBinding &&
      _profile.lastBindingSucceeded;
  MediaServerClient? _discoveryClient(MediaItem item) {
    final id = serverIdOrNull(item.serverId);
    if (!_currentProfile || id == null) return null;
    final servers = context.read<MultiServerProvider?>();
    final hidden = context.read<HiddenLibrariesProvider?>();
    if (servers?.isServerOnline(id) != true ||
        (item.libraryId != null && hidden?.isLibraryHidden('${item.serverId}:${item.libraryId}') == true)) {
      return null;
    }
    final client = context.getMediaClientForItemOrNull(item);
    return client != null && client.backend == item.backend && !client.isOfflineMode ? client : null;
  }

  bool get _validRecipe =>
      _name.text.trim().isNotEmpty &&
      _seeds.isNotEmpty &&
      (_kind != MusicRecipeKind.adventure || (_seeds.length >= 2 && _seeds.every((s) => s.kind == MediaKind.track))) &&
      (_kind != MusicRecipeKind.albumRadio || (_seeds.length == 1 && _seeds.single.kind == MediaKind.album));

  @override
  void initState() {
    super.initState();
    _profile = context.read<ActiveProfileProvider>();
    _profileId = _profile.activeId;
    _profileGeneration = _profile.identityMutationGeneration;
    final recipe = widget.recipe;
    _name.text = recipe?.title ?? widget.seed.displayTitle;
    _kind = recipe?.kind ?? MusicRecipeKind.mix;
    _limit = recipe?.limit ?? 100;
    _pathTracks = recipe?.pathTracks ?? 50;
    _maxDistance = recipe?.maxDistance ?? .25;
    _recipeId = recipe?.id;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_recipesLoaded) {
      _recipesLoaded = true;
      _loadRecipes();
    }
  }

  Future<void> _loadRecipes() async {
    final recipes = await _store?.load() ?? [];
    if (_currentProfile) setState(() => _saved = recipes);
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(int generation) action) async {
    if (!_currentProfile) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(generation);
    } catch (error) {
      if (_currentProfile && generation == _generation) {
        setState(() => _error = error is UnsupportedError ? t.musicExperience.unsupported : t.musicExperience.error);
      }
    } finally {
      if (_currentProfile && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  MusicRecipe _recipe() => MusicRecipe(
    id: _recipeId ??= const Uuid().v4(),
    title: _name.text.trim(),
    kind: _kind,
    seeds: _seeds,
    limit: _limit,
    pathTracks: _pathTracks,
    maxDistance: _maxDistance,
  );

  Future<void> _search() => _run((generation) async {
    if (_query.text.trim().isEmpty || _query.text.length > 200) {
      setState(() => _results = []);
      return;
    }
    final query = _query.text.trim();
    await _loadResults(generation, (client) => client.searchItems(query, limit: 60));
  });

  Future<void> _generate() => _run((generation) async {
    await context.read<HiddenLibrariesProvider?>()?.ensureInitialized();
    if (!_currentProfile || generation != _generation) return;
    final result = await MusicDiscovery(_discoveryClient).generate(_recipe());
    if (!_currentProfile || generation != _generation || !result.isCurrent()) return;
    setState(() {
      _preview = result;
      if (result.tracks.isEmpty) _error = t.musicExperience.empty;
    });
  });

  Future<void> _related() => _run(
    (generation) => _loadResults(generation, (client) async {
      if (client is SonicMusicClient) {
        return (client as SonicMusicClient).sonicallySimilar(widget.seed.id);
      }
      throw UnsupportedError('Sonic analysis is unavailable');
    }),
  );

  Future<void> _loadResults(int generation, Future<List<MediaItem>> Function(MediaServerClient) fetch) async {
    await context.read<HiddenLibrariesProvider?>()?.ensureInitialized();
    if (!_currentProfile || generation != _generation) return;
    final client = _discoveryClient(widget.seed);
    if (client == null) throw StateError('No server');
    final authentication = client.authenticationSessionId;
    final account = musicAccountScope(client);
    bool current() =>
        musicAccountScope(client) == account &&
        identical(client.authenticationSessionId, authentication) &&
        identical(_discoveryClient(widget.seed), client);
    final rows = await fetch(client);
    if (generation != _generation || !current()) return;
    final results = rows
        .where(
          (item) =>
              const [MediaKind.artist, MediaKind.album, MediaKind.track].contains(item.kind) &&
              identical(_discoveryClient(item), client),
        )
        .take(60)
        .toList();
    setState(() {
      _results = results;
      _resultsCurrent = current;
      if (results.isEmpty) _error = t.musicExperience.empty;
    });
  }

  Future<void> _saveRecipe() => _run((_) async {
    await _store?.save(_recipe());
    await _loadRecipes();
  });

  Future<void> _savePlaylist() => _run((_) async {
    final batch = _preview;
    if (batch == null || !batch.isCurrent() || batch.tracks.isEmpty) throw StateError('Preview source changed');
    final tracks = batch.tracks;
    final client = _discoveryClient(tracks.first);
    if (client == null || tracks.any((track) => track.serverId != tracks.first.serverId)) {
      throw StateError('Mixed servers');
    }
    final result = await client.createPlaylist(title: _name.text.trim(), items: tracks);
    if (result == null) throw StateError('Playlist was not created');
    if (mounted && batch.isCurrent()) showAppSnackBar(context, t.musicExperience.ready);
  });

  Future<void> _download() => _run((_) async {
    final batch = _preview;
    if (batch == null || !batch.isCurrent()) throw StateError('Preview source changed');
    final downloads = context.read<DownloadProvider>();
    final groups = <String?, List<MediaItem>>{};
    for (final track in batch.tracks) {
      (groups[track.serverId] ??= []).add(track);
    }
    for (final tracks in groups.values) {
      if (!batch.isCurrent()) return;
      final client = _discoveryClient(tracks.first);
      if (client == null) throw StateError('No server');
      await downloads.queueListDownload(tracks, client, sourceCurrent: batch.isCurrent);
    }
  });

  Future<void> _playPreview({MediaItem? startTrack, bool next = false}) => _run((_) async {
    final batch = _preview;
    if (batch == null || !batch.isCurrent() || batch.tracks.isEmpty) throw StateError('Preview source changed');
    final service = context.read<MusicPlaybackService>();
    if (next) {
      service.addNext(batch.tracks);
    } else if (batch.recipe.kind == MusicRecipeKind.albumRadio) {
      if (service is! MusicAlbumRadioControls) throw UnsupportedError('Album radio is unavailable');
      final outcome = await (service as MusicAlbumRadioControls).playAlbumRadio(
        batch.recipe.seeds.single,
        maxDistance: batch.recipe.maxDistance,
        preview: batch,
        startTrack: startTrack,
      );
      if (outcome == InstantMixOutcome.empty) throw StateError('Album radio is empty');
    } else {
      await service.playFromList(
        tracks: batch.tracks,
        startTrack: startTrack,
        playContext: MusicPlayContext(title: _name.text.trim(), kind: MusicPlayContextKind.mix),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final strings = t.musicExperience;
    context.watch<ActiveProfileProvider>();
    context.watch<MultiServerProvider?>();
    context.watch<HiddenLibrariesProvider?>();
    if (!_currentProfile) {
      return Scaffold(
        appBar: AppBar(title: Text(strings.title)),
        body: Center(child: Text(strings.error)),
      );
    }
    final service = context.watch<MusicPlaybackService>();
    final discovery = service is MusicDiscoveryControls ? service as MusicDiscoveryControls : null;
    final preview = _preview?.isCurrent() == true ? _preview!.tracks : const <MediaItem>[];
    return Scaffold(
      appBar: AppBar(title: Text(strings.title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SwitchListTile(
            title: Text(strings.autoDriving),
            subtitle: Text(strings.routeHint),
            value: SettingsService.instance.read(SettingsService.musicAutoDriving),
            onChanged: (value) async {
              await SettingsService.instance.write(SettingsService.musicAutoDriving, value);
              if (mounted) setState(() {});
            },
          ),
          if (context.watch<MusicExperience?>() case final experience?)
            MusicDrivingRoutesPicker(
              key: ObjectKey(experience.drivingRoutes),
              routes: experience.drivingRoutes,
              current: () =>
                  _currentProfile &&
                  identical(context.read<MusicExperience?>(), experience) &&
                  !context.read<ActiveProfileProvider>().isBinding &&
                  context.read<ActiveProfileProvider>().lastBindingSucceeded,
            ),
          if (discovery != null) ...[
            SwitchListTile(
              title: Text(strings.continuation),
              value: discovery.continuationEnabled,
              onChanged: discovery.setContinuationEnabled,
              secondary: discovery.continuationLoading
                  ? const CircularProgressIndicator()
                  : const AppIcon(Symbols.radio_rounded),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(onPressed: discovery.shuffleAlbums, child: Text(strings.shuffleAlbums)),
                OutlinedButton(onPressed: discovery.nextAlbum, child: Text(strings.nextAlbum)),
              ],
            ),
          ],
          TextField(
            controller: _name,
            enabled: !_busy,
            maxLength: 200,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: strings.name),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text(strings.mix),
                selected: _kind == MusicRecipeKind.mix,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _kind = MusicRecipeKind.mix;
                        _preview = null;
                      }),
              ),
              ChoiceChip(
                label: Text(strings.adventure),
                selected: _kind == MusicRecipeKind.adventure,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _kind = MusicRecipeKind.adventure;
                        _preview = null;
                      }),
              ),
              if (_kind == MusicRecipeKind.albumRadio || (_seeds.length == 1 && _seeds.single.kind == MediaKind.album))
                ChoiceChip(
                  label: Text(t.musicTools.albumRadio),
                  selected: _kind == MusicRecipeKind.albumRadio,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() {
                          _kind = MusicRecipeKind.albumRadio;
                          _limit = 500;
                          _preview = null;
                        }),
                ),
              ActionChip(label: Text(strings.related), onPressed: _busy ? null : _related),
            ],
          ),
          for (var i = 0; i < _seeds.length; i++)
            ListTile(
              leading: Text('${i + 1}'),
              title: Text(_seeds[i].displayTitle),
              subtitle: Text(_seeds[i].trackArtistTitle ?? _seeds[i].serverName ?? ''),
              trailing: PopupMenuButton<String>(
                enabled: !_busy,
                icon: const AppIcon(Symbols.more_vert_rounded),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'up', enabled: i > 0, child: Text(t.fileSources.moveUp)),
                  PopupMenuItem(value: 'down', enabled: i + 1 < _seeds.length, child: Text(t.fileSources.moveDown)),
                  PopupMenuItem(value: 'remove', child: Text(strings.remove)),
                ],
                onSelected: (action) => setState(() {
                  final seed = _seeds.removeAt(i);
                  if (action != 'remove') _seeds.insert(action == 'up' ? i - 1 : i + 1, seed);
                  _preview = null;
                }),
              ),
            ),
          TextField(
            controller: _query,
            enabled: !_busy,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: strings.search,
              suffixIcon: IconButton(
                tooltip: strings.search,
                icon: const AppIcon(Symbols.search_rounded),
                onPressed: _busy ? null : _search,
              ),
            ),
          ),
          for (final item
              in _resultsCurrent?.call() == true
                  ? _results.where(
                      (item) =>
                          _discoveryClient(item) != null &&
                          (_kind != MusicRecipeKind.albumRadio || item.kind == MediaKind.album),
                    )
                  : const <MediaItem>[])
            ListTile(
              title: Text(item.displayTitle),
              subtitle: Text(item.trackArtistTitle ?? item.serverName ?? ''),
              trailing: const AppIcon(Symbols.add_rounded),
              onTap: _busy || _seeds.length >= 20
                  ? null
                  : () {
                      if (_resultsCurrent?.call() != true || _discoveryClient(item) == null) return;
                      setState(() {
                        if (_kind == MusicRecipeKind.albumRadio) {
                          if (item.kind != MediaKind.album) return;
                          _seeds.clear();
                        }
                        _seeds.add(item);
                        _results = [];
                        _preview = null;
                      });
                    },
            ),
          DropdownButtonFormField<int>(
            key: ValueKey('limit/$_recipeId/$_limit'),
            initialValue: _limit,
            decoration: InputDecoration(labelText: strings.trackLimit),
            items: ({
              25,
              50,
              100,
              200,
              500,
              _limit,
            }.toList()..sort()).map((limit) => DropdownMenuItem(value: limit, child: Text('$limit'))).toList(),
            onChanged: _busy
                ? null
                : (n) => setState(() {
                    _limit = n!;
                    _preview = null;
                  }),
          ),
          if (_kind == MusicRecipeKind.adventure) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey('pathTracks/$_recipeId/$_pathTracks'),
              initialValue: _pathTracks,
              decoration: InputDecoration(labelText: t.musicTools.pathTracks),
              items: ({
                2,
                5,
                10,
                25,
                50,
                100,
                200,
                500,
                _pathTracks,
              }.toList()..sort()).map((n) => DropdownMenuItem(value: n, child: Text('$n'))).toList(),
              onChanged: _busy
                  ? null
                  : (n) => setState(() {
                      _pathTracks = n!;
                      _preview = null;
                    }),
            ),
          ],
          if (_kind != MusicRecipeKind.mix) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<double>(
              key: ValueKey('maxDistance/$_recipeId/$_maxDistance'),
              initialValue: _maxDistance,
              decoration: InputDecoration(labelText: t.musicTools.sonicDistance),
              items: ({
                0.0,
                .05,
                .1,
                .15,
                .2,
                .25,
                .4,
                .5,
                .75,
                1.0,
                _maxDistance,
              }.toList()..sort()).map((n) => DropdownMenuItem(value: n, child: Text(n.toStringAsFixed(2)))).toList(),
              onChanged: _busy
                  ? null
                  : (n) => setState(() {
                      _maxDistance = n!;
                      _preview = null;
                    }),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: _busy || !_validRecipe ? null : _generate, child: Text(strings.generate)),
              OutlinedButton(
                onPressed: _busy || !_validRecipe || _store == null ? null : _saveRecipe,
                child: Text(strings.saveRecipe),
              ),
              if (preview.isNotEmpty) ...[
                FilledButton(onPressed: _busy ? null : _playPreview, child: Text(strings.play)),
                OutlinedButton(onPressed: _busy ? null : () => _playPreview(next: true), child: Text(strings.next)),
                OutlinedButton(onPressed: _busy ? null : _savePlaylist, child: Text(strings.savePlaylist)),
                OutlinedButton(onPressed: _busy ? null : _download, child: Text(strings.download)),
              ],
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          for (final track in preview)
            TrackRow(
              item: track,
              onTap: () {
                if (!_busy) _playPreview(startTrack: track);
              },
            ),
          if (_saved.isNotEmpty) ...[
            const Divider(),
            Text(strings.saved, style: Theme.of(context).textTheme.titleLarge),
            for (final recipe in _saved)
              ListTile(
                title: Text(recipe.title),
                subtitle: Text('${recipe.seeds.length} · ${recipe.limit}'),
                onTap: _busy
                    ? null
                    : () => setState(() {
                        _recipeId = recipe.id;
                        _name.text = recipe.title;
                        _seeds
                          ..clear()
                          ..addAll(recipe.seeds);
                        _kind = recipe.kind;
                        _limit = recipe.limit;
                        _pathTracks = recipe.pathTracks;
                        _maxDistance = recipe.maxDistance;
                        _preview = null;
                      }),
                trailing: IconButton(
                  tooltip: strings.remove,
                  icon: const AppIcon(Symbols.delete_rounded),
                  onPressed: _busy
                      ? null
                      : () => _run((_) async {
                          await _store?.delete(recipe.id);
                          await _loadRecipes();
                        }),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
