import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../focus/focusable_text_field.dart';
import '../../games/romm/romm_controller.dart';
import '../../games/romm/romm_models.dart';
import '../../games/romm/romm_text.dart';
import '../../i18n/presentation_formats.dart';
import '../../services/file_picker_service.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';

class RommSavesScreen extends StatefulWidget {
  const RommSavesScreen({super.key, required this.controller, required this.game});
  final RommController controller;
  final RommGame game;
  @override State<RommSavesScreen> createState() => _RommSavesScreenState();
}
class _RommSavesScreenState extends State<RommSavesScreen> {
  late RommGame _game = widget.game;
  bool _busy = false;
  String _error = '';
  bool get live => mounted && widget.controller.current;
  @override void initState() { super.initState(); }
  Future<void> _run(Future<void> Function() work) async {
    if (!live || _busy) return;
    setState(() { _busy = true; _error = ''; });
    try { await work(); }
    catch (error) { if (live) setState(() => _error = error is RommFailure ? error.code : 'romm.connectionFailed'); }
    finally { if (live) setState(() => _busy = false); }
  }
  Future<void> _refresh() async { final next = await widget.controller.detail(_game); if (live) setState(() => _game = next); }
  Future<void> _export(String name, Uint8List bytes) async {
    if (!live) return;
    final path = await FilePickerService.instance.saveFile(fileName: rommSafeFileName(name), bytes: bytes);
    if (path != null && live && (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) await File(path).writeAsBytes(bytes, flush: true);
    if (path != null && live) showSnackBar(context, rommText(context, 'saveExported'));
  }
  Future<void> _import(bool state) async {
    final emulator = TextEditingController(text: _game.saves.firstOrNull?.emulator ?? ''), core = TextEditingController(), slot = TextEditingController(text: 'manual');
    try {
      final accepted = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
        title: Text(rommText(dialog, state ? 'importState' : 'importSave')),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(isolateDisplayText(_game.variant)), Text(rommText(dialog, 'compatibilityHelp')),
          FocusableTextField(controller: emulator, decoration: InputDecoration(labelText: rommText(dialog, 'engine'))),
          if (state) FocusableTextField(controller: core, decoration: InputDecoration(labelText: rommText(dialog, 'core'))),
          if (!state) FocusableTextField(controller: slot, decoration: InputDecoration(labelText: rommText(dialog, 'slot'))),
        ])), actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(rommText(dialog, 'cancel'))),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(rommText(dialog, 'importSave')))]));
      if (accepted != true || !live) return;
      if (!RegExp(r'^[a-zA-Z0-9_.-]{1,50}$').hasMatch(emulator.text) ||
          state && !RegExp(r'^[a-zA-Z0-9_.-]{1,100}$').hasMatch(core.text) ||
          !RegExp(r'^[a-zA-Z0-9_.-]{1,100}$').hasMatch(slot.text)) throw const RommFailure('romm.invalidFile');
      final picked = await FilePickerService.instance.pickFiles(withData: false);
      if (!live || picked == null) return;
      final file = picked.files.single;
      if (file.size <= 0 || file.size > 128 * 1024 * 1024) throw const RommFailure('romm.invalidFile');
      final bytes = file.bytes ?? (file.path == null ? null : await File(file.path!).readAsBytes());
      if (!live || bytes == null) return;
      final id = await widget.controller.storage.enqueue(game: _game, bytes: bytes, emulator: emulator.text,
        core: core.text, state: state, slot: slot.text);
      await widget.controller.storage.sync(id, keepBoth: true); await _refresh();
      if (live) showSnackBar(context, rommText(context, 'saveImported'));
    } finally { emulator.dispose(); core.dispose(); slot.dispose(); }
  }
  Future<void> _resolve(String id, String action) async {
    if (action == 'replaceServer' || action == 'useServer') {
      final confirmed = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
        title: Text(rommText(dialog, action)), content: Text(rommText(dialog, 'saveConflict')),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(rommText(dialog, 'cancel'))),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(rommText(dialog, action)))]));
      if (confirmed != true || !live) return;
    }
    if (action == 'useServer') await widget.controller.storage.discardPending(id);
    else await widget.controller.storage.sync(id, keepBoth: action == 'keepBoth', replace: action == 'replaceServer');
    await _refresh();
  }
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: widget.controller.storage, builder: (context, _) {
    final storage = widget.controller.storage;
    final own = widget.controller.connection(_game.connectionId).userId;
    final pending = storage.pending.entries.where((e) => e.value['connectionId'] == _game.connectionId && rommMap(e.value['game'])['id'] == _game.id).toList();
    return FocusedScrollScaffold(title: Text(rommText(context, 'saves')), slivers: [
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(isolateDisplayText(_game.name)), Text(rommText(context, 'compatibilityHelp')),
        Wrap(spacing: 12, children: [for (final state in [false, true]) OutlinedButton(onPressed: _busy ? null : () => _run(() => _import(state)), child: Text(rommText(context, state ? 'importState' : 'importSave'))),
          OutlinedButton(onPressed: _busy ? null : () => _run(_refresh), child: Text(rommText(context, 'refresh')))]),
        if (_busy) const LinearProgressIndicator(), if (_error.isNotEmpty) Text(rommText(context, _error)),
      ]))),
      if (pending.isNotEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Text(rommText(context, 'pendingSaves'), style: Theme.of(context).textTheme.titleLarge))),
      for (final entry in pending) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${entry.value['emulator']} · ${entry.value['core']} · ${entry.value['created']}'),
        Text(rommText(context, storage.failures[entry.key] ?? 'savedLocally')),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : () => _run(() async => _export('plezy-${entry.key}.save', await storage.pendingBytes(entry.key))), child: Text(rommText(context, 'exportSave'))),
          for (final action in entry.value['conflict'] == true ? ['keepBoth', 'useServer', 'replaceServer'] : ['sync'])
            OutlinedButton(onPressed: _busy ? null : () => _run(() => _resolve(entry.key, action)), child: Text(rommText(context, action))),
        ]),
      ]))),
      if (_game.saves.isEmpty && _game.states.isEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Text(rommText(context, 'noSaves')))),
      for (final save in [..._game.saves, ..._game.states].where((s) => s.userId == own && s.romId == _game.id)) SliverToBoxAdapter(child: FocusableListTile(
        title: Text(isolateDisplayText(save.name)),
        subtitle: Text('${save.emulator} · ${save.core} · ${save.slot}\n${save.updatedAt?.toLocal().toString() ?? ''}'),
        leading: Icon(save.state ? Icons.pause_circle_outline : Icons.save_outlined),
        trailing: IconButton(tooltip: rommText(context, 'exportSave'), icon: const Icon(Icons.download),
          onPressed: _busy || save.missing ? null : () => _run(() async {
            final bytes = await (await widget.controller.client(_game.connectionId)).saveBytes(save);
            await _export(save.name, bytes);
          })),
      )),
    ]);
  });
}
