import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../../i18n/strings.g.dart';
import '../../../mpv/font_loader.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_font_store.dart';
import '../../../services/subtitle_analysis_source.dart';
import '../../../services/subtitle_embedded_fonts.dart';

class SubtitleFontsDialog extends StatefulWidget {
  const SubtitleFontsDialog({super.key, this.openSource, this.isSourceCurrent});
  final Future<SubtitleAnalysisSource> Function()? openSource;
  final bool Function()? isSourceCurrent;
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
    } catch (_) {
      if (mounted) _message = Translations.of(context).videoControls.subtitleFonts.actionFailed;
    }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _import() => _run(() async {
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleFonts;
    final result = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: ['ttf', 'otf']);
    final file = result?.files.single.path;
    if (file == null || !mounted) return;
    final label = TextEditingController(text: p.basenameWithoutExtension(file));
    final license = TextEditingController();
    try {
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: Text(copy.importOfflineTitle),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: label, maxLength: 100, decoration: InputDecoration(labelText: copy.displayName)),
          TextField(controller: license, minLines: 3, maxLines: 8, maxLength: 16384,
            decoration: InputDecoration(labelText: copy.licenseLabel)),
          Text(copy.importHelp),
        ])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(copy.importButton))]));
      if (accepted == true) await _store.importFile(File(file), label: label.text, license: license.text);
    } finally { label.dispose(); license.dispose(); }
  });
  Future<void> _remove(SubtitleStoredFont font) => _run(() async {
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleFonts;
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(copy.removeTitle(font: font.label)),
      content: Text(copy.removeHelp),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(copy.removeButton))]));
    if (accepted == true) await _store.remove(font);
  });
  Future<void> _embedded() => _run(() async {
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleFonts;
    final open = widget.openSource;
    if (open == null) { _message = copy.sourceUnavailable; return; }
    if (widget.isSourceCurrent?.call() == false) { _message = copy.playbackChanged; return; }
    SubtitleEmbeddedFonts? media;
    final attribution = TextEditingController();
    try {
      media = await SubtitleEmbeddedFonts.open(await open());
      final source = media;
      bool current() => mounted && source.current && widget.isSourceCurrent?.call() != false;
      if (!current()) { _message = copy.playbackChanged; return; }
      if (source.fonts.isEmpty) { _message = copy.noEmbeddedFonts; return; }
      final selected = <SubtitleEmbeddedFont>{};
      final accepted = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) => AlertDialog(
        title: Text(copy.chooseEmbeddedTitle),
        content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(copy.selectedCopyHelp),
          for (final font in source.fonts) CheckboxListTile(value: selected.contains(font), title: Text(font.name),
            subtitle: Text('${(font.bytes / 1048576).toStringAsFixed(2)} MiB'),
            onChanged: (checked) => update(() { if (checked == true) { selected.add(font); } else { selected.remove(font); } })),
          TextField(controller: attribution, minLines: 2, maxLines: 6, maxLength: 15000,
            decoration: InputDecoration(labelText: copy.embeddedLicense)),
        ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          FilledButton(onPressed: selected.isEmpty ? null : () => Navigator.pop(context, true),
            child: Text(copy.importSelected(count: selected.length)))],
      )));
      if (accepted != true) return;
      var imported = 0;
      try {
        for (final font in source.fonts.where(selected.contains)) {
          if (!current()) {
            _message = imported == 0 ? copy.playbackChanged : copy.partialImport(count: imported);
            return;
          }
          final bytes = await source.readFont(font);
          if (!current()) {
            _message = imported == 0 ? copy.playbackChanged : copy.partialImport(count: imported);
            return;
          }
          var name = p.basenameWithoutExtension(font.name).trim();
          if (name.isEmpty) name = copy.embeddedFontName;
          if (name.length > 100) name = name.substring(0, 100);
          await _store.importBytes(bytes, label: name, license: attribution.text.trim());
          imported++;
        }
        _message = copy.retainedOffline(count: imported);
      } catch (_) {
        _message = imported == 0 ? copy.actionFailed : copy.partialImport(count: imported);
      }
    } finally { attribution.dispose(); await media?.close(); }
  });
  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleFonts;
    return AlertDialog(title: Text(copy.title),
    content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(copy.description),
      Text(copy.storageStatus(storage: _bytes == null ? copy.loading : '${(_bytes! / 1048576).toStringAsFixed(2)} MiB',
        count: _store.fonts.length, registered: _store.registeredCount)),
      for (final font in _store.fonts) ListTile(title: Text(font.label),
        subtitle: Text(copy.fontMetadata(bytes: (font.bytes / 1048576).toStringAsFixed(2),
          digest: font.digest.substring(0, 12), license: font.license.isEmpty ? copy.noLicense : copy.licenseRetained)),
        trailing: IconButton(tooltip: copy.removeFont, icon: const Icon(Icons.delete_outline), onPressed: _busy ? null : () => _remove(font))),
      if (_message != null) Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      if (_busy) const LinearProgressIndicator(),
    ]))), actions: [
      if (widget.openSource != null) TextButton(onPressed: _busy ? null : _embedded, child: Text(copy.findEmbedded)),
      TextButton(onPressed: _busy ? null : _import, child: Text(copy.importTtfOtf)),
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(t.common.close))]);
  }
}
