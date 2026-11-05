import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../providers/theme_provider.dart';
import '../../services/file_picker_service.dart';
import '../../services/settings_mutation_service.dart';
import '../../services/settings_service.dart' as settings;
import '../../theme/mono_theme.dart';
import '../../theme/theme_package.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/settings_section.dart';

class ThemePackageScreen extends StatefulWidget {
  const ThemePackageScreen({super.key});
  @override
  State<ThemePackageScreen> createState() => _ThemePackageScreenState();
}

class _ThemePackageScreenState extends State<ThemePackageScreen> {
  late final TextEditingController _text;
  ThemePackage? _preview;
  bool _busy = false, _invalid = false;

  @override
  void initState() {
    super.initState();
    final theme = context.read<ThemeProvider>();
    _preview = theme.customPackage ?? ThemePackage(id: 'my-theme', name: t.themeEditor.custom, palette: theme.activePalette);
    _text = TextEditingController(text: _preview!.encode());
  }
  @override
  void dispose() { _text.dispose(); super.dispose(); }

  void _parse(String value) {
    try {
      final package = ThemePackage.decode(value);
      setState(() { _preview = package; _invalid = false; });
    } on Object {
      setState(() { _preview = null; _invalid = true; });
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final result = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
      if (result == null || !mounted) return;
      final selected = result.files.single;
      if (selected.size > ThemePackage.maximumBytes || selected.path == null) throw const FormatException();
      final bytes = <int>[];
      await for (final chunk in File(selected.path!).openRead()) {
        if (bytes.length + chunk.length > ThemePackage.maximumBytes) throw const FormatException();
        bytes.addAll(chunk);
      }
      final value = utf8.decode(bytes);
      final package = ThemePackage.decode(value);
      if (!mounted) return;
      _text.text = value;
      setState(() { _preview = package; _invalid = false; });
    } on Object {
      if (mounted) setState(() => _invalid = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool reset = false}) async {
    final package = _preview;
    if (!reset && package == null) return;
    setState(() => _busy = true);
    try {
      const mutation = SettingsMutationService();
      final failure = await mutation.write(context, settings.SettingsService.customThemePackage, reset ? null : package);
      if (failure != null) throw StateError(failure.display);
      if (!mounted) return;
      if (!reset) {
        final modeFailure = await mutation.write(context, settings.SettingsService.themeMode, settings.ThemeMode.custom);
        if (modeFailure != null) throw StateError(modeFailure.display);
      }
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) setState(() => _invalid = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final package = _preview;
    if (package == null) return;
    setState(() => _busy = true);
    try {
      await FilePickerService.instance.saveFile(fileName: '${package.id}.plezy-theme.json',
        bytes: Uint8List.fromList(utf8.encode(package.encode())),
        type: FileType.custom, allowedExtensions: const ['json']);
    } on Object {
      if (mounted) setState(() => _invalid = true);
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: Text(t.themeEditor.title),
    children: [
      if (_preview case final package?)
        Theme(data: package.apply(monoTheme(package.palette)), child: Builder(builder: (context) => Card(
          child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(package.name, style: Theme.of(context).textTheme.headlineSmall),
            Text(t.themeEditor.preview, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 12),
            Wrap(spacing: 12, children: [FilledButton(onPressed: () {}, child: Text(t.common.save)),
              OutlinedButton(onPressed: () {}, child: Text(t.common.cancel))]),
          ])),
        ))),
      if (_invalid) Padding(padding: const EdgeInsets.all(16), child: Text(t.settings.importSettingsInvalidFile,
        style: TextStyle(color: Theme.of(context).colorScheme.error))),
      Padding(padding: const EdgeInsets.all(16), child: TextField(controller: _text, enabled: !_busy,
        minLines: 8, maxLines: 24, onChanged: _parse,
        style: const TextStyle(fontFamily: 'monospace'),
        decoration: InputDecoration(labelText: t.themeEditor.custom, border: const OutlineInputBorder()))),
      Padding(padding: const EdgeInsets.all(16), child: Wrap(spacing: 12, runSpacing: 12, children: [
        OutlinedButton(onPressed: _busy ? null : _import, child: Text(t.settings.importSettings)),
        OutlinedButton(onPressed: _busy || _preview == null ? null : _export, child: Text(t.settings.exportSettings)),
        FilledButton(onPressed: _busy || _preview == null ? null : _save, child: Text(t.common.save)),
        TextButton(onPressed: _busy ? null : () => _save(reset: true), child: Text(t.common.reset)),
      ])),
    ],
  );
}
