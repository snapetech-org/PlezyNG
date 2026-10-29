import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import '../../games/romm/romm_controller.dart';
import '../../games/romm/romm_link.dart';
import '../../games/romm/romm_models.dart';
import '../../games/romm/romm_native.dart';
import '../../games/romm/romm_text.dart';
import '../../i18n/presentation_formats.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import 'romm_native_player_screen.dart';
import 'romm_saves_screen.dart';
import 'romm_session_page.dart';
import 'romm_web_player_screen.dart';
import 'romm_web_surface.dart';

class RommDetailScreen extends StatefulWidget {
  const RommDetailScreen({super.key, required this.controller, required this.game});
  final RommController controller;
  final RommGame game;
  @override State<RommDetailScreen> createState() => _RommDetailScreenState();
}
class _RommDetailScreenState extends State<RommDetailScreen> {
  late RommGame _game = widget.game;
  bool _loading = false, _browser = false, _launching = false;
  Set<String> _cores = {};
  String _error = '';
  bool get live => mounted && widget.controller.current && widget.controller.hasConnection(_game.connectionId);
  @override void initState() { super.initState(); unawaited(_refresh()); }
  Future<void> _run(Future<void> Function() work) async {
    if (!live || _loading) return;
    setState(() { _loading = true; _error = ''; });
    try { await work(); }
    catch (error) { if (live) setState(() => _error = error is RommFailure ? error.code : 'romm.connectionFailed'); }
    finally { if (live) setState(() => _loading = false); }
  }
  Future<void> _refresh() => _run(() async {
    _browser = await RommWebSurface.available(); _cores = await RommNative.available();
    final game = await widget.controller.detail(_game);
    await widget.controller.refreshCapabilities(_game.connectionId);
    if (live) setState(() => _game = game);
  });
  Future<void> _play(RommRoute route) async {
    if (!live || !route.available || _launching) return;
    setState(() => _launching = true);
    try {
    if (route.engine != RommEngine.native && widget.controller.capabilities[_game.connectionId]?.fresh != true) {
      await _refresh(); return;
    }
    if (route.engine == RommEngine.native) {
      final resume = await rommDialog<String>(context: context, controller: widget.controller, connectionId: _game.connectionId, builder: (dialog) => SimpleDialog(
        title: Text(rommText(dialog, 'native')), children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(dialog, 'resume'), child: Text(rommText(dialog, 'nativeCloudResume'))),
          SimpleDialogOption(onPressed: () => Navigator.pop(dialog, 'fresh'), child: Text(rommText(dialog, 'startFresh'))),
          for (final save in [..._game.saves, ..._game.states].where((save) =>
            save.userId == widget.controller.connection(_game.connectionId).userId && save.romId == _game.id &&
            save.emulator.startsWith(rommNativeEmulatorPrefix(route.core)) && !save.missing))
            SimpleDialogOption(onPressed: () => Navigator.pop(dialog, '${save.state ? 't' : 's'}:${save.id}'),
              child: Text('${rommText(dialog, save.state ? 'loadState' : 'resume')} · ${isolateDisplayText(save.name)}')),
        ]));
      if (resume == null || !live) return;
      await rommPush<void>(context, widget.controller, RommNativePlayerScreen(controller: widget.controller, game: _game, core: route.core, resume: resume != 'fresh',
        saveId: resume.startsWith('s:') ? int.tryParse(resume.substring(2)) : null,
        stateId: resume.startsWith('t:') ? int.tryParse(resume.substring(2)) : null), connectionId: _game.connectionId);
      if (live) unawaited(_refresh()); return;
    }
    int? stateId, saveId, memoryCardId;
    var multiplayer = false;
    if (route.engine == RommEngine.stream) {
      await _run(() async {
        final api = await widget.controller.client(_game.connectionId);
        final picks = await api.getMap('streaming/states/${_game.id}');
        final ids = rommList(picks['pickable']).map((v) => rommInt(v)).toSet();
        final config = widget.controller.capabilities[_game.connectionId]?.streams.where((c) => c['emulator'] == route.core).firstOrNull;
        final cards = config?['supports_memory_cards'] == true
            ? rommList(await api.json('GET', 'memory-cards', query: {'emulator': route.core})).map(rommMap).toList() : <Map<String, dynamic>>[];
        if (!live) return;
        final result = await rommDialog<bool>(context: context, controller: widget.controller, connectionId: _game.connectionId, builder: (dialog) => StatefulBuilder(builder: (dialog, update) => AlertDialog(
          title: Text(rommText(dialog, 'stream')), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(rommText(dialog, 'compatibilityHelp')),
            DropdownButtonFormField<int>(initialValue: 0, isExpanded: true, decoration: InputDecoration(labelText: rommText(dialog, 'resume')),
              items: [DropdownMenuItem(value: 0, child: Text(rommText(dialog, 'startFresh'))),
                for (final state in _game.states.where((s) => ids.contains(s.id))) DropdownMenuItem(value: state.id, child: Text(isolateDisplayText(state.name), overflow: TextOverflow.ellipsis))],
              onChanged: (value) => update(() => stateId = value == 0 ? null : value)),
            if (config?['supports_save_picker'] == true) DropdownButtonFormField<int>(initialValue: 0, isExpanded: true,
              decoration: InputDecoration(labelText: rommText(dialog, 'saves')),
              items: [DropdownMenuItem(value: 0, child: Text(rommText(dialog, 'automatic'))),
                for (final save in _game.saves.where((s) => s.emulator == route.core)) DropdownMenuItem(value: save.id, child: Text(isolateDisplayText(save.name), overflow: TextOverflow.ellipsis))],
              onChanged: (value) => update(() => saveId = value == 0 ? null : value)),
            if (config?['supports_memory_cards'] == true) DropdownButtonFormField<int>(initialValue: 0, isExpanded: true,
              decoration: InputDecoration(labelText: rommText(dialog, 'memoryCard')),
              items: [DropdownMenuItem(value: 0, child: Text(rommText(dialog, 'automatic'))),
                for (final card in cards) DropdownMenuItem(value: rommInt(card['id']), child: Text(isolateDisplayText(rommString(card['name'], 255)), overflow: TextOverflow.ellipsis))],
              onChanged: (value) => update(() => memoryCardId = value == 0 ? null : value)),
            SwitchListTile(title: Text(rommText(dialog, 'multiplayer')), value: multiplayer, onChanged: (v) => update(() => multiplayer = v)),
          ])), actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(rommText(dialog, 'cancel'))),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(rommText(dialog, 'play')))])));
        if (result != true) throw const RommFailure('romm.cancelled');
      });
      if (!live || _error.isNotEmpty) return;
    }
    if (!live) return;
    await rommPush<void>(context, widget.controller, RommWebPlayerScreen(controller: widget.controller, game: _game, route: route,
      stateId: stateId, saveId: saveId, memoryCardId: memoryCardId, multiplayer: multiplayer), connectionId: _game.connectionId);
    if (live) unawaited(_refresh());
    } finally { if (live) setState(() => _launching = false); }
  }
  Future<void> _download() async {
    RommFile? selected;
    if (_game.files.length > 1) {
      selected = await rommDialog<RommFile>(context: context, controller: widget.controller, connectionId: _game.connectionId, builder: (dialog) => SimpleDialog(title: Text(rommText(dialog, 'chooseFile')),
        children: [for (final file in _game.files) SimpleDialogOption(onPressed: () => Navigator.pop(dialog, file), child: Text(isolateDisplayText(file.name)))]));
      if (selected == null || !live) return;
    }
    await widget.controller.storage.download(_game, selected: selected);
  }
  Future<void> _manual() async {
    final bytes = await (await widget.controller.client(_game.connectionId)).asset(_game.manual, maximum: 64 * 1024 * 1024);
    if (!live) return;
    if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') throw const RommFailure('romm.invalidFile');
    await rommPush<void>(context, widget.controller, Scaffold(appBar: AppBar(title: Text(rommText(context, 'manual'))),
      body: PdfViewer.data(bytes, sourceName: 'romm-${_game.id}.pdf')), connectionId: _game.connectionId);
  }
  Future<void> _join() async {
    final data = await (await widget.controller.client(_game.connectionId)).getMap('streaming/sessions/joinable');
    final rows = rommList(data['sessions']).map(rommMap).toList();
    if (!live) return;
    final selected = await rommDialog<Map<String, dynamic>>(context: context, controller: widget.controller, connectionId: _game.connectionId, builder: (dialog) => SimpleDialog(
      title: Text(rommText(dialog, 'join')), children: [if (rows.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(rommText(dialog, 'noJoinable'))),
        for (final row in rows) SimpleDialogOption(onPressed: () => Navigator.pop(dialog, row), child: Text(isolateDisplayText(rommString(row['rom_name'], 512))))]));
    if (selected == null || !live) return;
    final game = await (await widget.controller.client(_game.connectionId)).game(_game.connectionId, rommInt(selected['rom_id']));
    if (live) await rommPush<void>(context, widget.controller, RommWebPlayerScreen(controller: widget.controller, game: game,
      route: const RommRoute(RommEngine.stream), joinPlatform: rommString(selected['platform'], 128), joinContainer: rommString(selected['container'], 512)), connectionId: _game.connectionId);
  }
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: widget.controller, builder: (context, _) {
    final c = widget.controller, storage = c.storage;
    if (!c.current || !c.hasConnection(_game.connectionId)) return const SizedBox.shrink();
    final routes = c.capabilities[_game.connectionId]?.routes(_game, browserAvailable: _browser, nativeCores: _cores,
      offlineAvailable: storage.available(_game), offlineFileName: rommString(storage.downloads[_game.key]?['name'], 1024)) ?? <RommRoute>[];
    final downloading = storage.progress.containsKey(_game.key), offline = storage.available(_game);
    final achievements = rommList(_game.achievements['achievements']).map(rommMap).toList();
    final earned = rommList(c.achievementProgress[_game.connectionId]?['results']).map(rommMap)
      .where((row) => row['rom_ra_id'] == _game.achievementId).firstOrNull;
    final earnedIds = rommList(earned?['earned_achievements']).map((v) => rommMap(v)['id'].toString()).toSet();
    return FocusedScrollScaffold(title: Text(isolateDisplayText(_game.name)), slivers: [
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FutureBuilder<Uint8List?>(future: c.cover(_game), builder: (context, cover) => cover.data == null ? const SizedBox.shrink()
          : SizedBox(height: 240, child: Image.memory(cover.data!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.sports_esports)))),
        const SizedBox(height: 16), Text(isolateDisplayText(_game.variant), style: Theme.of(context).textTheme.titleMedium),
        if (_game.summary.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(isolateDisplayText(_game.summary))),
        if (_loading) const LinearProgressIndicator(),
        if (_error.isNotEmpty) Text(rommText(context, _error)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh), label: Text(rommText(context, 'refresh'))),
          OutlinedButton.icon(onPressed: () => _run(() => c.favorite(_game)), icon: Icon(c.favorites.contains(_game.key) ? Icons.favorite : Icons.favorite_border), label: Text(rommText(context, 'favorite'))),
          OutlinedButton(onPressed: () => rommPush<void>(context, c, RommSavesScreen(controller: c, game: _game), connectionId: _game.connectionId), child: Text(rommText(context, 'saves'))),
          if (_game.manual.isNotEmpty) OutlinedButton(onPressed: _loading ? null : () => _run(_manual), child: Text(rommText(context, 'manual'))),
          OutlinedButton(onPressed: () async {
            await Clipboard.setData(ClipboardData(text: RommLink.game(c.connection(_game.connectionId), _game).uri.toString()));
            if (live) showSnackBar(context, rommText(context, 'linkCopied'));
          }, child: Text(rommText(context, 'copyLink'))),
          if (_browser) OutlinedButton(onPressed: _loading ? null : () => _run(_join), child: Text(rommText(context, 'join'))),
        ]),
        const SizedBox(height: 16),
        SwitchListTile(title: Text(rommText(context, 'backlogged')), value: _game.userData['backlogged'] == true,
          onChanged: _loading ? null : (value) => _run(() async {
            await (await c.client(_game.connectionId)).setProgress(_game, {'backlogged': value});
            final fresh = await c.detail(_game); if (live) setState(() => _game = fresh);
          })),
        SwitchListTile(title: Text(rommText(context, 'nowPlaying')), value: _game.userData['now_playing'] == true,
          onChanged: _loading ? null : (value) => _run(() async {
            await (await c.client(_game.connectionId)).setProgress(_game, {'now_playing': value});
            final fresh = await c.detail(_game); if (live) setState(() => _game = fresh);
          })),
        DropdownButtonFormField<String>(key: ValueKey('${_game.key}:${_game.userData['status']}'),
          initialValue: {'incomplete', 'finished', 'completed_100'}.contains(_game.userData['status']) ? _game.userData['status'] as String : '',
          decoration: InputDecoration(labelText: rommText(context, 'status')),
          items: [for (final entry in {'': 'unplayed', 'incomplete': 'playing', 'finished': 'completed', 'completed_100': 'completedAll'}.entries)
            DropdownMenuItem(value: entry.key, child: Text(rommText(context, entry.value)))],
          onChanged: _loading ? null : (value) => _run(() async {
            await (await c.client(_game.connectionId)).setProgress(_game, {'status': value == '' ? null : value});
            final fresh = await c.detail(_game); if (live) setState(() => _game = fresh);
          })),
        const SizedBox(height: 20), Text(rommText(context, 'playWith'), style: Theme.of(context).textTheme.titleLarge),
        if (routes.isEmpty) Text(rommText(context, _game.hasBytes ? 'noRoute' : 'missing')),
        for (final route in routes) ListTile(title: Text('${rommText(context, route.engine.name)}${route.core.isEmpty ? '' : ' · ${route.core}'}'),
          subtitle: route.available ? null : Text(rommText(context, route.reason)), leading: const Icon(Icons.play_circle_outline),
          onTap: !route.available || _loading || _launching ? null : () => _play(route)),
        const SizedBox(height: 16), Text(rommText(context, 'firmwareHelp')),
        const SizedBox(height: 8), Text(rommText(context, 'netplayHelp')),
        const SizedBox(height: 20), Text(rommText(context, 'storage'), style: Theme.of(context).textTheme.titleLarge),
        Text('${(storage.used / 1073741824).toStringAsFixed(1)} / ${(storage.quota / 1073741824).round()} GiB'),
        DropdownButton<int>(value: [5, 10, 25, 50, 100, 250].contains(storage.quota ~/ 1073741824) ? storage.quota ~/ 1073741824 : 10,
          items: [for (final size in [5, 10, 25, 50, 100, 250]) DropdownMenuItem(value: size, child: Text('$size GiB'))],
          onChanged: (size) { if (size != null) unawaited(_run(() => storage.setQuota(size * 1073741824))); }),
        if (downloading) LinearProgressIndicator(value: storage.progress[_game.key]),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: downloading ? () => storage.cancel(_game.key) : _loading || !_game.hasBytes ? null : () => _run(_download),
            child: Text(rommText(context, downloading ? 'cancelDownload' : offline ? 'downloadAgain' : 'download'))),
          if (offline) OutlinedButton(onPressed: _loading ? null : () => _run(() => storage.remove(_game)), child: Text(rommText(context, 'removeOffline'))),
        ]),
        if (offline) Text(rommText(context, storage.downloads[_game.key]?['serverVerified'] == true ? 'offline' : 'offlineUnverified')),
        const SizedBox(height: 20), Text(rommText(context, 'files'), style: Theme.of(context).textTheme.titleLarge),
        for (final file in _game.files) Text('${isolateDisplayText(file.name)} · ${(file.size / 1048576).toStringAsFixed(1)} MiB'),
        if (_game.achievementId > 0) ...[const SizedBox(height: 20), Text(rommText(context, 'achievements'), style: Theme.of(context).textTheme.titleLarge),
          Text(rommText(context, 'achievementsHelp')),
          Text('${rommText(context, 'achievementCount')}: ${rommInt(earned?['num_awarded'])} / ${achievements.length}'),
          for (final achievement in achievements.take(100)) ListTile(
            leading: Icon(earnedIds.contains(achievement['ra_id'].toString()) ? Icons.emoji_events : Icons.lock_outline),
            title: Text(isolateDisplayText(rommString(achievement['title'], 500))),
            subtitle: Text(isolateDisplayText(rommString(achievement['description'], 2000))))],
        if (_game.screenshots.isNotEmpty) ...[const SizedBox(height: 20), Text(rommText(context, 'screenshots'), style: Theme.of(context).textTheme.titleLarge),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final path in _game.screenshots.take(12)) _RommScreenshot(controller: c, game: _game, path: path)])],
      ]))),
      if (_game.siblingIds.isNotEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Text(rommText(context, 'variants'), style: Theme.of(context).textTheme.titleLarge))),
      for (final id in _game.siblingIds) SliverToBoxAdapter(child: FocusableListTile(title: Text('${rommText(context, 'variants')} #$id'),
        onTap: _loading ? null : () => _run(() async {
          final game = await (await c.client(_game.connectionId)).game(_game.connectionId, id);
          if (live) await rommPush<void>(context, c, RommDetailScreen(controller: c, game: game), connectionId: _game.connectionId);
        }))),
    ]);
  });
}
class _RommScreenshot extends StatefulWidget {
  const _RommScreenshot({required this.controller, required this.game, required this.path});
  final RommController controller;
  final RommGame game;
  final String path;
  @override State<_RommScreenshot> createState() => _RommScreenshotState();
}
class _RommScreenshotState extends State<_RommScreenshot> {
  late final Future<Uint8List> _bytes = _load();
  Future<Uint8List> _load() async => (await widget.controller.client(widget.game.connectionId)).asset(widget.path, externalImage: true);
  @override Widget build(BuildContext context) => FutureBuilder<Uint8List>(future: _bytes, builder: (context, snapshot) =>
    snapshot.data == null ? const SizedBox(width: 180, height: 100) : Image.memory(snapshot.data!, width: 240, height: 160, fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const SizedBox.shrink()));
}
