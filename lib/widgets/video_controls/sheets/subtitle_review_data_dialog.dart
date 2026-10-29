import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_rejection_service.dart';
import '../../../services/subtitle_review_data.dart';
import '../../../services/subtitle_translation_memory.dart';

class SubtitleReviewDataDialog extends StatefulWidget {
  const SubtitleReviewDataDialog({super.key});
  @override
  State<SubtitleReviewDataDialog> createState() => _SubtitleReviewDataDialogState();
}

class _SubtitleReviewDataDialogState extends State<SubtitleReviewDataDialog> {
  ActiveProfileProvider? _profiles;
  String? _profile, _error, _status;
  bool _initialized = false, _busy = false, _conflictsOnly = true;
  SubtitleReviewData? _local, _incoming;
  Set<String> _conflicts = {}, _replace = {};
  bool get _current => mounted && _profile != null && _profiles?.activeId == _profile;
  void _check() { if (!_current) throw StateError('Profile changed.'); }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true; _profiles = context.read<ActiveProfileProvider>(); _profile = _profiles!.activeId;
    _run(_capture);
  }
  Future<void> _capture() async {
    _check(); final data = await SubtitleReviewData.capture(_profile!); _check(); _local = data;
    _conflicts = _incoming?.conflictsWith(data) ?? {};
    _replace = {};
  }
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; _status = null; });
    try { await action(); }
    catch (_) { if (mounted) _error = t.videoSettings.subtitleReviewTransferFailed; }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _export() async {
    await _capture();
    final bytes = _local!.encode();
    final path = await FilePickerService.instance.saveFile(fileName: 'PlezyNG.subtitle-review-data.json',
      bytes: bytes, type: FileType.custom, allowedExtensions: const ['json']);
    if (path == null) return;
    // Export is a frozen snapshot explicitly chosen by the viewer; it neither
    // alters active playback nor rebinds an import after a profile transition.
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) await File(path).writeAsBytes(bytes, flush: true);
    if (_current) _status = t.videoSettings.subtitleReviewExported;
  }
  Future<void> _preview() async {
    _check();
    final choice = await FilePickerService.instance.pickFiles(type: FileType.custom,
      allowedExtensions: const ['json'], withReadStream: true);
    _check();
    if (choice == null) return;
    if (choice.files.length != 1 || choice.files.single.size > SubtitleReviewData.maximumBytes) {
      throw const FormatException('Review data size limit.');
    }
    final file = choice.files.single;
    final stream = file.readStream ?? (file.path == null ? null : File(file.path!).openRead());
    if (stream == null) throw const FormatException('Review data cannot be read.');
    final bytes = BytesBuilder(copy: false), deadline = DateTime.now().add(const Duration(seconds: 20));
    await for (final chunk in stream.timeout(const Duration(seconds: 5))) {
      _check();
      if (DateTime.now().isAfter(deadline) || bytes.length + chunk.length > SubtitleReviewData.maximumBytes) {
        throw const FormatException('Review data read limit.');
      }
      bytes.add(chunk);
    }
    if (file.size > 0 && bytes.length != file.size) throw const FormatException('Review data was truncated.');
    final incoming = SubtitleReviewData.decode(bytes.takeBytes());
    _check(); _incoming = incoming;
    await _capture();
  }
  Future<void> _legacy() async {
    _check();
    _incoming = SubtitleReviewData(memory: const {}, rejections: SubtitleRejectionService.legacyPortable());
    await _capture();
  }
  Future<void> _importMemory() async {
    _check();
    final incoming = _incoming, local = _local;
    if (incoming == null || local == null) return;
    await SubtitleTranslationMemory.mergePortable(_profile!, incoming.memory, expectedDigest: local.memoryDigest,
      replaceKeys: Set.of(_replace), checkCurrent: _check);
    await _capture(); _status = t.videoSettings.subtitleReviewMemoryImported;
  }
  Future<void> _importRejections() async {
    _check();
    final incoming = _incoming, local = _local;
    if (incoming == null || local == null) return;
    await SubtitleRejectionService.mergePortable(_profile!, incoming.rejections,
      expectedDigest: local.rejectionDigest, checkCurrent: _check);
    await _capture(); _status = t.videoSettings.subtitleReviewRejectionsImported;
  }
  @override
  Widget build(BuildContext context) {
    final incoming = _incoming, local = _local;
    final keys = incoming?.memory.keys.where((key) => !_conflictsOnly || _conflicts.contains(key)).toList() ?? <String>[];
    return PopScope(canPop: !_busy, child: AlertDialog(title: Text(t.videoSettings.subtitleReviewData),
      content: SizedBox(width: 680, height: MediaQuery.sizeOf(context).height * .64,
        child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.videoSettings.subtitleReviewDataHelp),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: _busy || !_current ? null : () => _run(_export), child: Text(t.videoSettings.subtitleReviewExport)),
            TextButton(onPressed: _busy || !_current ? null : () => _run(_preview), child: Text(t.videoSettings.subtitleReviewOpen)),
            TextButton(onPressed: _busy || !_current ? null : () => _run(_legacy), child: Text(t.videoSettings.subtitleReviewLegacy)),
          ]),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_status != null) Text(_status!),
          if (incoming != null && local != null) ...[
            Text(t.videoSettings.subtitleReviewCounts(memory: incoming.memory.length,
              rejected: incoming.rejections.length, conflicts: _conflicts.length)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(t.videoSettings.subtitleReviewOnlyConflicts),
              value: _conflictsOnly, onChanged: _busy ? null : (value) => setState(() => _conflictsOnly = value)),
            SizedBox(height: 300, child: ListView.builder(itemCount: keys.length, itemBuilder: (context, index) {
              final key = keys[index], entry = incoming.memory[key]!;
              final conflict = _conflicts.contains(key);
              return Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${key.substring(0, 12)} · ${entry['reviewedAt']}', style: Theme.of(context).textTheme.labelSmall),
                if (conflict) SelectableText(t.videoSettings.subtitleReviewLocal(text: local.memory[key]!['text'] as String)),
                SelectableText(t.videoSettings.subtitleReviewIncoming(text: entry['text'] as String)),
                if (conflict) CheckboxListTile(contentPadding: EdgeInsets.zero,
                  title: Text(t.videoSettings.subtitleReviewReplace), value: _replace.contains(key),
                  onChanged: _busy ? null : (value) => setState(() {
                    if (value == true) { _replace.add(key); } else { _replace.remove(key); }
                  })),
              ])));
            })),
            Wrap(spacing: 8, children: [
              FilledButton(onPressed: _busy || !_current || incoming.memory.isEmpty ? null : () => _run(_importMemory),
                child: Text(t.videoSettings.subtitleReviewImportMemory)),
              FilledButton(onPressed: _busy || !_current || incoming.rejections.isEmpty ? null : () => _run(_importRejections),
                child: Text(t.videoSettings.subtitleReviewImportRejections)),
              TextButton(onPressed: _busy || !_current ? null : () => _run(_capture), child: Text(t.common.refresh)),
            ]),
          ] else const SizedBox(height: 12),
        ]))),
      actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(t.common.close))]));
  }
}
