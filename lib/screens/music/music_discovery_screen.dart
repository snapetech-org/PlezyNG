import 'package:material_symbols_icons/symbols.dart';
import '../../widgets/app_icon.dart';
import '../../services/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/download_provider.dart';
import '../../services/music/music_discovery.dart';
import '../../services/music/music_playback_service.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/music/track_row.dart';

Future<void> openMusicDiscovery(BuildContext context, MediaItem seed) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => MusicDiscoveryScreen(seed: seed)));

/// Seed editor, sonic paths, related tracks and saved recipes all use existing
/// server clients, track menus, download ownership and the one music session.
class MusicDiscoveryScreen extends StatefulWidget {
  const MusicDiscoveryScreen({super.key, required this.seed});
  final MediaItem seed;
  @override
  State<MusicDiscoveryScreen> createState() => _MusicDiscoveryScreenState();
}

class _MusicDiscoveryScreenState extends State<MusicDiscoveryScreen> {
  late final List<MediaItem> _seeds = [widget.seed];
  final _query = TextEditingController();
  final _name = TextEditingController();
  List<MediaItem> _results = [], _preview = [];
  List<MusicRecipe> _saved = [];
  MusicRecipeKind _kind = MusicRecipeKind.mix;
  int _limit = 100, _generation = 0;
  String? _recipeId;
  bool _busy = false;
  bool _recipesLoaded = false;
  String? _error;
  late final String? _profileId = context.read<ActiveProfileProvider>().activeId;
  MusicRecipeStore? get _store => _profileId == null ? null : MusicRecipeStore(context.read<AppDatabase>(), _profileId);
  bool get _currentProfile => mounted && context.read<ActiveProfileProvider>().activeId == _profileId;
  bool get _validRecipe =>
      _name.text.trim().isNotEmpty &&
      _seeds.isNotEmpty &&
      (_kind != MusicRecipeKind.adventure || (_seeds.length >= 2 && _seeds.every((s) => s.kind == MediaKind.track)));

  @override
  void initState() {
    super.initState();
    _name.text = widget.seed.displayTitle;
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
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(generation);
    } catch (_) {
      if (_currentProfile && generation == _generation) {
        setState(() => _error = t.musicExperience.error);
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
  );

  Future<void> _search() => _run((generation) async {
    if (_query.text.trim().isEmpty || _query.text.length > 200) {
      setState(() => _results = []);
      return;
    }
    final client = context.getMediaClientForItemOrNull(widget.seed);
    if (client == null) throw StateError('No server');
    final results = await client.searchItems(_query.text.trim(), limit: 60);
    if (!mounted || !_currentProfile || generation != _generation) return;
    setState(
      () => _results = results
          .where((item) => const [MediaKind.artist, MediaKind.album, MediaKind.track].contains(item.kind))
          .toList(),
    );
  });

  Future<void> _generate() => _run((generation) async {
    final discovery = MusicDiscovery(
      (item) => mounted && _currentProfile ? context.getMediaClientForItemOrNull(item) : null,
    );
    final result = await discovery.generate(_recipe());
    if (!mounted || !_currentProfile || generation != _generation) return;
    setState(() {
      _preview = result;
      if (result.isEmpty) _error = t.musicExperience.empty;
    });
  });

  Future<void> _related() => _run((generation) async {
    final client = context.getMediaClientForItemOrNull(widget.seed);
    if (client is! SonicMusicClient) {
      setState(() => _error = t.musicExperience.unsupported);
      return;
    }
    final result = await (client as SonicMusicClient).sonicallySimilar(widget.seed.id);
    if (!mounted || !_currentProfile || generation != _generation) return;
    setState(() {
      _results = result;
      if (result.isEmpty) _error = t.musicExperience.empty;
    });
  });

  Future<void> _saveRecipe() => _run((_) async {
    await _store?.save(_recipe());
    await _loadRecipes();
  });

  Future<void> _savePlaylist() => _run((_) async {
    final client = context.getMediaClientForItemOrNull(_preview.first);
    if (client == null || _preview.any((t) => t.serverId != _preview.first.serverId)) {
      throw StateError('Mixed servers');
    }
    final result = await client.createPlaylist(title: _name.text.trim(), items: _preview);
    if (result == null) throw StateError('Playlist was not created');
    if (mounted && _currentProfile) showAppSnackBar(context, t.musicExperience.ready);
  });

  Future<void> _download() => _run((_) async {
    final downloads = context.read<DownloadProvider>();
    final groups = <String?, List<MediaItem>>{};
    for (final track in _preview) {
      (groups[track.serverId] ??= []).add(track);
    }
    for (final tracks in groups.values) {
      if (!mounted || !_currentProfile) return;
      final client = context.getMediaClientForItemOrNull(tracks.first);
      if (client == null) throw StateError('No server');
      await downloads.queueListDownload(tracks, client);
    }
  });

  @override
  Widget build(BuildContext context) {
    final strings = t.musicExperience;
    final service = context.watch<MusicPlaybackService>();
    final discovery = service is MusicDiscoveryControls ? service as MusicDiscoveryControls : null;
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
                        _preview = [];
                      }),
              ),
              ChoiceChip(
                label: Text(strings.adventure),
                selected: _kind == MusicRecipeKind.adventure,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _kind = MusicRecipeKind.adventure;
                        _preview = [];
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
                  _preview = [];
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
          for (final item in _results)
            ListTile(
              title: Text(item.displayTitle),
              subtitle: Text(item.trackArtistTitle ?? item.serverName ?? ''),
              trailing: const AppIcon(Symbols.add_rounded),
              onTap: _busy || _seeds.length >= 20
                  ? null
                  : () => setState(() {
                      _seeds.add(item);
                      _results = [];
                      _preview = [];
                    }),
            ),
          DropdownButtonFormField<int>(
            initialValue: _limit,
            decoration: InputDecoration(labelText: strings.trackLimit),
            items: [25, 50, 100, 200, 500].map((n) => DropdownMenuItem(value: n, child: Text('$n'))).toList(),
            onChanged: _busy
                ? null
                : (n) => setState(() {
                    _limit = n!;
                    _preview = [];
                  }),
          ),
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
              if (_preview.isNotEmpty) ...[
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => service.playFromList(
                          tracks: _preview,
                          playContext: MusicPlayContext(title: _name.text.trim(), kind: MusicPlayContextKind.mix),
                        ),
                  child: Text(strings.play),
                ),
                OutlinedButton(onPressed: _busy ? null : () => service.addNext(_preview), child: Text(strings.next)),
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
          for (var i = 0; i < _preview.length; i++)
            TrackRow(
              item: _preview[i],
              onTap: () => service.playFromList(
                tracks: _preview,
                startTrack: _preview[i],
                playContext: MusicPlayContext(title: _name.text.trim(), kind: MusicPlayContextKind.mix),
              ),
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
                        _preview = [];
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
