import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../../mpv/font_loader.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_font_store.dart';

class SubtitleFontsDialog extends StatefulWidget {
  const SubtitleFontsDialog({super.key});
  @override
  State<SubtitleFontsDialog> createState() => _SubtitleFontsDialogState();
}
class _SubtitleFontsDialogState extends State<SubtitleFontsDialog> {
  final _store = SubtitleFontStore.instance;
  bool _busy = false;
  int? _bytes;
  String? _message;
  @override
  void initState() { super.initState(); unawaited(_run(() async {})); }
  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; });
    try {
      await _store.initialize();
      await body();
      _bytes = await _store.diskBytes();
      SubtitleFontLoader.importedFontsChanged();
    } catch (error) { _message = error.toString(); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _import() => _run(() async {
    final result = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    final file = result?.files.single.path;
    if (file == null || !mounted) return;
    final label = TextEditingController(text: p.basenameWithoutExtension(file));
    final license = TextEditingController();
    try {
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('Import an offline font'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: label, maxLength: 100, decoration: const InputDecoration(labelText: 'Display name')),
          TextField(controller: license, minLines: 3, maxLines: 8, maxLength: 16384,
            decoration: const InputDecoration(labelText: 'License / attribution text (optional)')),
          const Text('Only this chosen file is imported. Keep any required license text with the font. '
            'App captions can use it immediately. Native ASS can find its internal family name when a new player opens.'),
        ])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import'))]));
      if (accepted == true) await _store.importFile(File(file), label: label.text, license: license.text);
    } finally { label.dispose(); license.dispose(); }
  });
  Future<void> _remove(SubtitleStoredFont font) => _run(() async {
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('Remove ${font.label}?'),
      content: const Text('Remove the saved font file. Captions using it fall back to the bundled font. '
        'Existing native players and Flutter’s registered font memory are released when those players or the app restart.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove'))]));
    if (accepted == true) await _store.remove(font);
  });
  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Offline subtitle fonts'),
    content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('Bundled multilingual and Hangul fonts are always available offline. Imported single-font TTF/OTF files are shared on this device, '
        'limited to 16 fonts, 16 MiB per font and 128 MiB including metadata. Font collections and web fonts are unsupported.'),
      Text('Saved storage: ${_bytes == null ? 'loading' : '${(_bytes! / 1048576).toStringAsFixed(2)} MiB'} · '
        '${_store.fonts.length} saved · ${_store.registeredCount}/16 registered this app session'),
      for (final font in _store.fonts) ListTile(title: Text(font.label),
        subtitle: Text('${(font.bytes / 1048576).toStringAsFixed(2)} MiB · SHA-256 ${font.digest.substring(0, 12)}\n'
          '${font.license.isEmpty ? 'No separate license text supplied' : 'License text retained'}'),
        trailing: IconButton(tooltip: 'Remove font', icon: const Icon(Icons.delete_outline), onPressed: _busy ? null : () => _remove(font))),
      if (_message != null) Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      if (_busy) const LinearProgressIndicator(),
    ]))), actions: [TextButton(onPressed: _busy ? null : _import, child: const Text('Import TTF / OTF')),
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Close'))]);
}
