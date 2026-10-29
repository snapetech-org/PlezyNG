import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/subtitle_text_codec.dart';
import '../../../services/subtitle_text_importer.dart';

/// Explicit charset/format review. Preview parsing runs on an isolate and never
/// mutates the picked source. Changing an option invalidates the old preview.
class SubtitleImportDialog extends StatefulWidget {
  const SubtitleImportDialog({super.key, required this.bytes, required this.extension, required this.name});
  final List<int> bytes;
  final String extension;
  final String name;
  @override
  State<SubtitleImportDialog> createState() => _SubtitleImportDialogState();
}

class _SubtitleImportDialogState extends State<SubtitleImportDialog> {
  final _fps = TextEditingController();
  final _tail = TextEditingController(text: '2000');
  final _samiClass = TextEditingController();
  final _sccOrigin = TextEditingController(text: '0');
  int _sccChannel = 1;
  bool _sccNtsc = true;
  String _encoding = 'unicode';
  SubtitleTextImport? _result;
  String? _error;
  bool _parsing = false;
  int _generation = 0;

  @override
  void initState() { super.initState(); unawaited(_preview()); }
  @override
  void dispose() { ++_generation; _fps.dispose(); _tail.dispose(); _samiClass.dispose(); _sccOrigin.dispose(); super.dispose(); }

  void _invalidate() { ++_generation; setState(() { _result = null; _error = null; }); }

  Future<void> _preview() async {
    if (_parsing) return;
    final generation = ++_generation;
    setState(() { _parsing = true; _result = null; _error = null; });
    try {
      final fps = _fps.text.trim().isEmpty ? null : double.tryParse(_fps.text.trim());
      if (_fps.text.trim().isNotEmpty && fps == null) throw const FormatException('Enter a numeric frame rate.');
      final tail = int.tryParse(_tail.text.trim());
      if (tail == null) throw const FormatException('Enter the final cue duration in whole milliseconds.');
      final origin = int.tryParse(_sccOrigin.text.trim());
      if (origin == null) throw const FormatException('Enter the SCC clock origin in whole milliseconds.');
      final result = await SubtitleTextImporter.parseAsync(widget.bytes, widget.extension,
        encoding: _encoding, framesPerSecond: fps, finalCueDurationMs: tail, samiClass: _samiClass.text,
        sccChannel: _sccChannel, sccNtsc: _sccNtsc, sccClockOriginMs: origin);
      if (mounted && generation == _generation) setState(() => _result = result);
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error is FormatException ? error.message.toString() : 'This file could not be decoded. Check its format and encoding.');
    } finally { if (mounted) setState(() => _parsing = false); }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final count = result?.cues.length ?? 0;
    final sample = <int>{0, 1, count ~/ 2, count - 2, count - 1}.where((i) => i >= 0 && i < count).toList()..sort();
    return AlertDialog(title: const Text('Preview subtitle import'),
      content: SizedBox(width: 680, height: (MediaQuery.sizeOf(context).height - 210).clamp(250.0, 650.0).toDouble(),
        child: ListView(children: [
          Text(widget.name),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(initialValue: _encoding, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Source encoding'),
            items: SubtitleTextCodec.encodings.entries.map((e) => DropdownMenuItem(value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: _parsing ? null : (value) { _encoding = value ?? _encoding; _invalidate(); }),
          if (widget.extension == '.sub') TextField(controller: _fps,
            keyboardType: const TextInputType.numberWithOptions(decimal: true), maxLength: 16,
            decoration: const InputDecoration(labelText: 'MicroDVD FPS (blank uses the file header)', helperText: 'For 23.976 film use 23.976023976; VFR media does not imply a subtitle FPS.'),
            onChanged: (_) => _invalidate()),
          if (const {'.smi', '.sami'}.contains(widget.extension)) TextField(controller: _samiClass, maxLength: 128,
            decoration: const InputDecoration(labelText: 'SAMI language class (blank selects first)', helperText: 'The preview lists the classes declared in the file.'), onChanged: (_) => _invalidate()),
          if (widget.extension == '.scc') ...[
            DropdownButtonFormField<int>(initialValue: _sccChannel,
              decoration: const InputDecoration(labelText: 'Channel within the supplied SCC field'),
              items: const [DropdownMenuItem(value: 1, child: Text('Channel 1')), DropdownMenuItem(value: 2, child: Text('Channel 2'))],
              onChanged: _parsing ? null : (value) { _sccChannel = value ?? 1; _invalidate(); }),
            DropdownButtonFormField<bool>(initialValue: _sccNtsc,
              decoration: const InputDecoration(labelText: 'SCC frame clock'),
              items: const [DropdownMenuItem(value: true, child: Text('30000/1001 fps (29.97)')),
                DropdownMenuItem(value: false, child: Text('30 fps'))],
              onChanged: _parsing ? null : (value) { _sccNtsc = value ?? true; _invalidate(); }),
            TextField(controller: _sccOrigin, maxLength: 8, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'SCC clock origin to subtract (ms)',
                helperText: '0 preserves its clock. Set a known media origin; the first caption is not assumed to be time zero.'),
              onChanged: (_) => _invalidate()),
          ],
          if (const {'.smi', '.sami', '.lrc', '.scc'}.contains(widget.extension)) TextField(controller: _tail, maxLength: 5,
            keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Final cue duration without a closing time (ms)'),
            onChanged: (_) => _invalidate()),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _parsing ? null : _preview, child: const Text('Refresh preview')),
          if (_parsing) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (result != null) ...[
            Text('$count cues · separate UTF-8 SRT derivative; original stays unchanged'),
            for (final warning in result.warnings) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(warning)),
            for (final index in sample) ListTile(dense: true,
              title: SelectableText(widget.extension.toLowerCase() == '.scc'
                  ? SubtitleTextImporter.decodeHtmlEntities(result.cues[index].text)
                  : result.cues[index].text),
              subtitle: Text('${Duration(milliseconds: result.cues[index].startMs)} → ${Duration(milliseconds: result.cues[index].endMs)}')),
          ],
        ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: result == null || _parsing ? null : () => Navigator.pop(context, result), child: const Text('Use this decoding'))]);
  }
}
