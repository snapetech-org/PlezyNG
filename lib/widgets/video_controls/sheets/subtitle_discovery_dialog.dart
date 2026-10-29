import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../i18n/strings.g.dart';
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
  Translations get _t => Translations.of(context);

  @override
  void initState() { super.initState(); unawaited(_load()); }
  @override
  void dispose() { _title.dispose(); super.dispose(); }

  Future<void> _load() async {
    final copy = _t.videoControls.subtitleDiscovery;
    try {
      final roots = await SubtitleDiscoveryService.roots(widget.profileId);
      String? path;
      try { path = SubtitleDiscoveryService.localMediaPath(await widget.player.getProperty('path').timeout(const Duration(seconds: 2))); }
      catch (_) { /* This backend does not expose a local source path. */ }
      if (!_current) return;
      setState(() { _roots = List.of(roots); _mediaFolder = path == null ? null : p.dirname(path);
        _title.text = path == null ? widget.title ?? '' : p.basenameWithoutExtension(path!); });
    } catch (_) { if (mounted) setState(() => _error = copy.readFoldersFailed); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _addRoot() async {
    if (!_current || _busy || _roots.length >= 8) return;
    final copy = _t.videoControls.subtitleDiscovery;
    setState(() { _busy = true; _error = null; });
    try {
      final path = await FilePickerService.instance.getDirectoryPath(dialogTitle: copy.chooseFolderTitle);
      if (path == null || !_current) return;
      final roots = {..._roots, p.normalize(path)}.toList();
      await SubtitleDiscoveryService.saveRoots(widget.profileId, roots);
      if (_current) setState(() { _roots = roots; _result = null; });
    } catch (_) { if (mounted) setState(() => _error = copy.folderUnavailable); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _removeRoot(String root) async {
    if (!_current || _busy) return;
    final copy = _t.videoControls.subtitleDiscovery;
    setState(() => _busy = true);
    try {
      final roots = _roots.where((value) => value != root).toList();
      await SubtitleDiscoveryService.saveRoots(widget.profileId, roots);
      if (_current) setState(() { _roots = roots; _result = null; });
    } catch (_) { if (mounted) setState(() => _error = copy.folderPreferenceSaveFailed); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _search() async {
    if (!_current || _busy) return;
    final copy = _t.videoControls.subtitleDiscovery;
    setState(() { _busy = true; _error = null; _result = null; });
    try {
      final result = await SubtitleDiscoveryService.discover(
        roots: [if (_includeMediaFolder && _mediaFolder != null) _mediaFolder!, ..._roots], title: _title.text,
        extensions: {...widget.player.supportedLocalSubtitleExtensions,
          if (widget.player.supportedLocalSubtitleExtensions.contains('srt')) ...SubtitleTextImporter.extensions},
        includeSubfolders: _subfolders, isCurrent: () => _current,
      );
      if (_current) setState(() => _result = result);
    } catch (error) {
      final message = error is SubtitleDiscoveryException
          ? switch (error.failure) {
              SubtitleDiscoveryFailure.queryBounds => copy.queryBounds,
              SubtitleDiscoveryFailure.tooManyRoots => copy.tooManyRoots,
              SubtitleDiscoveryFailure.staleOwner => copy.staleSession,
            }
          : copy.staleSession;
      if (mounted) setState(() => _error = message);
    }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _t.videoControls.subtitleDiscovery;
    return AlertDialog(title: Text(copy.title),
      content: SizedBox(width: 680, height: (MediaQuery.sizeOf(context).height - 200).clamp(260.0, 650.0).toDouble(),
        child: ListView(children: [
        TextField(controller: _title, maxLength: 256, enabled: !_busy,
          onChanged: (_) => setState(() => _result = null),
          decoration: InputDecoration(labelText: copy.titlePrefixLabel, helperText: copy.titlePrefixHint)),
        if (_mediaFolder != null) SwitchListTile(title: Text(copy.includeMediaFolder), subtitle: Text(_mediaFolder!),
          value: _includeMediaFolder, onChanged: _busy ? null : (value) => setState(() { _includeMediaFolder = value; _result = null; })),
        for (final root in _roots) ListTile(title: Text(root), trailing: IconButton(tooltip: copy.forgetFolder,
          onPressed: _busy ? null : () => _removeRoot(root), icon: const Icon(Icons.remove_circle_outline))),
        OutlinedButton(onPressed: _busy || _roots.length >= 8 ? null : _addRoot, child: Text(copy.addFolder)),
        SwitchListTile(title: Text(copy.includeOneSubfolder), value: _subfolders,
          onChanged: _busy ? null : (value) => setState(() { _subfolders = value; _result = null; })),
        Text(copy.foldersHelp),
        FilledButton(onPressed: _busy ? null : _search, child: Text(copy.searchFolders)),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_result != null) ...[
          Text(copy.matchSummary(matches: _result!.paths.length, scanned: _result!.scanned)),
          if (_result!.paths.isEmpty) Text(copy.noMatches),
          if (_result!.limited) Text(copy.searchLimited),
          for (final warning in _result!.warnings) Text(switch (warning.kind) {
            SubtitleDiscoveryWarningKind.permissionExpired => copy.permissionExpired(folder: warning.folder),
            SubtitleDiscoveryWarningKind.unreadable => copy.unreadableFolder(folder: warning.folder),
            SubtitleDiscoveryWarningKind.timedOut => copy.folderTimedOut(folder: warning.folder),
          }),
          for (final path in _result!.paths) ListTile(title: Text(p.basename(path)), subtitle: Text(p.dirname(path)),
            onTap: _busy || !_current ? null : () => Navigator.pop(context, path)),
        ],
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t.common.close))]);
  }
}
