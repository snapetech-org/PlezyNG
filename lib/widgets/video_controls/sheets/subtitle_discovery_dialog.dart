import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../mpv/mpv.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_discovery_service.dart';
import '../../../services/subtitle_text_importer.dart';

class SubtitleDiscoveryDialog extends StatefulWidget {
  const SubtitleDiscoveryDialog({super.key, required this.player, required this.profileId,
    required this.isCurrent, this.title});
  final Player player;
  final String profileId;
  final String? title;
  final bool Function() isCurrent;
  @override
  State<SubtitleDiscoveryDialog> createState() => _SubtitleDiscoveryDialogState();
}

class _SubtitleDiscoveryDialogState extends State<SubtitleDiscoveryDialog> {
  final _title = TextEditingController();
  List<String> _roots = [];
  String? _mediaFolder;
  bool _includeMediaFolder = true, _subfolders = true, _busy = true;
  SubtitleDiscoveryResult? _result;
  String? _error;
  bool get _current => mounted && widget.isCurrent();

  @override
  void initState() { super.initState(); unawaited(_load()); }
  @override
  void dispose() { _title.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final roots = await SubtitleDiscoveryService.roots(widget.profileId);
      String? path;
      try { path = SubtitleDiscoveryService.localMediaPath(await widget.player.getProperty('path').timeout(const Duration(seconds: 2))); }
      catch (_) { /* This backend does not expose a local source path. */ }
      if (!_current) return;
      setState(() { _roots = List.of(roots); _mediaFolder = path == null ? null : p.dirname(path);
        _title.text = path == null ? widget.title ?? '' : p.basenameWithoutExtension(path!); });
    } catch (_) { if (mounted) setState(() => _error = 'Saved subtitle folders could not be read.'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _addRoot() async {
    if (!_current || _busy || _roots.length >= 8) return;
    setState(() { _busy = true; _error = null; });
    try {
      final path = await FilePickerService.instance.getDirectoryPath(dialogTitle: 'Choose a subtitle folder');
      if (path == null || !_current) return;
      final roots = {..._roots, p.normalize(path)}.toList();
      await SubtitleDiscoveryService.saveRoots(widget.profileId, roots);
      if (_current) setState(() { _roots = roots; _result = null; });
    } catch (_) { if (mounted) setState(() => _error = 'This folder is unavailable. Use subtitle file import if this platform cannot grant folder access.'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _removeRoot(String root) async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      final roots = _roots.where((value) => value != root).toList();
      await SubtitleDiscoveryService.saveRoots(widget.profileId, roots);
      if (_current) setState(() { _roots = roots; _result = null; });
    } catch (_) { if (mounted) setState(() => _error = 'This folder preference could not be saved.'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _search() async {
    if (!_current || _busy) return;
    setState(() { _busy = true; _error = null; _result = null; });
    try {
      final result = await SubtitleDiscoveryService.discover(
        roots: [if (_includeMediaFolder && _mediaFolder != null) _mediaFolder!, ..._roots], title: _title.text,
        extensions: {...widget.player.supportedLocalSubtitleExtensions,
          if (widget.player.supportedLocalSubtitleExtensions.contains('srt')) ...SubtitleTextImporter.extensions},
        includeSubfolders: _subfolders, isCurrent: () => _current,
      );
      if (_current) setState(() => _result = result);
    } catch (error) { if (mounted) setState(() => _error = error is FormatException ? error.message.toString() : 'Discovery stopped because the folder or playback session changed.'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Find subtitles in folders'),
    content: SizedBox(width: 680, height: (MediaQuery.sizeOf(context).height - 200).clamp(260.0, 650.0).toDouble(),
      child: ListView(children: [
        TextField(controller: _title, maxLength: 256, enabled: !_busy,
          onChanged: (_) => setState(() => _result = null),
          decoration: const InputDecoration(labelText: 'Media filename/title prefix', helperText: 'Punctuation and case are ignored. Release and language suffixes may follow the title.')),
        if (_mediaFolder != null) SwitchListTile(title: const Text('Include the local media folder'), subtitle: Text(_mediaFolder!),
          value: _includeMediaFolder, onChanged: _busy ? null : (value) => setState(() { _includeMediaFolder = value; _result = null; })),
        for (final root in _roots) ListTile(title: Text(root), trailing: IconButton(tooltip: 'Forget folder (keeps files)',
          onPressed: _busy ? null : () => _removeRoot(root), icon: const Icon(Icons.remove_circle_outline))),
        OutlinedButton(onPressed: _busy || _roots.length >= 8 ? null : _addRoot, child: const Text('Add subtitle folder')),
        SwitchListTile(title: const Text('Include one subfolder level'), value: _subfolders,
          onChanged: _busy ? null : (value) => setState(() { _subfolders = value; _result = null; })),
        const Text('Folders are remembered for this profile. Originals stay in place. Only chosen local folders are searched; expired permissions may require choosing the folder again.'),
        FilledButton(onPressed: _busy ? null : _search, child: const Text('Search folders')),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_result != null) ...[
          Text('${_result!.paths.length} matching files · ${_result!.scanned} entries inspected${_result!.limited ? ' · search limit reached; choose a narrower folder' : ''}'),
          for (final warning in _result!.warnings) Text(warning),
          for (final path in _result!.paths) ListTile(title: Text(p.basename(path)), subtitle: Text(p.dirname(path)),
            onTap: _busy || !_current ? null : () => Navigator.pop(context, path)),
        ],
      ])),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]);
}
