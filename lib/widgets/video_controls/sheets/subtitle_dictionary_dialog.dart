import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_dictionary_service.dart';
import '../../../services/subtitle_retimer.dart';

class SubtitleDictionaryReview {
  const SubtitleDictionaryReview(this.cues, this.pack, this.changed);
  final List<SubtitleCue> cues;
  final SubtitleDictionaryPack pack;
  final int changed;
}

class SubtitleDictionaryDialog extends StatefulWidget {
  const SubtitleDictionaryDialog({super.key, required this.isCurrent, this.cues, this.contextText = ''});
  final bool Function() isCurrent;
  final List<SubtitleCue>? cues;
  final String contextText;
  @override
  State<SubtitleDictionaryDialog> createState() => _SubtitleDictionaryDialogState();
}

class _SubtitleDictionaryDialogState extends State<SubtitleDictionaryDialog> {
  final _store = SubtitleDictionaryService.instance;
  final _term = TextEditingController();
  SubtitleDictionaryPack? _pack;
  List<SubtitleDictionaryEntry> _definitions = [];
  SubtitleSpellingReport? _report;
  final Map<int, String> _choices = {};
  bool _busy = false;
  String? _message;
  bool get _current => mounted && widget.isCurrent();
  @override
  void initState() { super.initState(); unawaited(_run(() async { await _store.initialize(); })); }
  @override
  void dispose() { _term.dispose(); super.dispose(); }
  Future<void> _run(Future<void> Function() body) async {
    if (_busy || !_current) return;
    setState(() { _busy = true; _message = null; });
    try { await body(); }
    catch (error) { _message = error is FormatException ? error.message : 'The local dictionary operation could not finish.'; }
    finally { if (mounted) setState(() => _busy = false); }
  }
  void _select(SubtitleDictionaryPack pack) {
    _pack = pack; _definitions = []; _report = null; _choices.clear();
  }
  Future<void> _import() => _run(() async {
    final selected = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    final path = selected?.files.single.path;
    if (path == null || !_current) return;
    final file = File(path), pack = await _store.preview(File(path));
    if (!_current) return;
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('Import ${pack.title}?'),
      content: SizedBox(width: 520, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${pack.language} · ${pack.entries.length} terms · ${(pack.bytes / 1048576).toStringAsFixed(2)} MiB'),
          const SizedBox(height: 12), SelectableText(pack.license), const SizedBox(height: 12),
          const Text('This pack is saved on this device and available to every local profile. Its definitions and vocabulary are supplied by the pack author.'),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import offline'))]));
    if (accepted != true || !_current) return;
    final imported = await _store.importFile(file, expectedDigest: pack.digest);
    if (_current) _select(imported);
  });
  Future<void> _remove() => _run(() async {
    final pack = _pack;
    if (pack == null) return;
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('Remove ${pack.title}?'), content: const Text('Remove this dictionary from the device. Saved subtitle corrections remain unchanged.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove'))]));
    if (accepted != true || !_current) return;
    await _store.remove(pack.digest);
    _pack = null; _report = null; _definitions = []; _choices.clear();
  });
  Future<void> _check() => _run(() async {
    final pack = _pack, cues = widget.cues;
    if (pack == null || cues == null) return;
    final report = await SubtitleDictionaryService.check(pack, cues);
    if (!_current || !identical(_pack, pack)) return;
    _report = report; _choices.clear();
    _message = '${report.words} words checked; ${report.skippedStyled} styled cues skipped. '
        '${report.candidates.length} vocabulary misses shown.${report.limited ? ' Review stopped at its work limit; remaining text is unchecked.' : ''}';
  });
  void _apply() {
    final pack = _pack, report = _report, source = widget.cues;
    if (!_current || _busy || pack == null || report == null || source == null || _choices.isEmpty) return;
    try {
      final grouped = <int, List<(SubtitleSpellingCandidate, String)>>{};
      for (final entry in _choices.entries) {
        final candidate = report.candidates[entry.key];
        if (!candidate.suggestions.contains(entry.value)) throw StateError('Dictionary choice changed.');
        (grouped[candidate.cue] ??= []).add((candidate, entry.value));
      }
      final result = List<SubtitleCue>.of(source);
      for (final group in grouped.entries) {
        final cue = source[group.key];
        var text = cue.text;
        final replacements = group.value..sort((a, b) => b.$1.start.compareTo(a.$1.start));
        for (final (candidate, replacement) in replacements) {
          if (text.substring(candidate.start, candidate.end) != candidate.term) throw StateError('Source cue changed.');
          text = text.replaceRange(candidate.start, candidate.end, replacement);
        }
        if (text.length > 4000) throw const FormatException('A corrected cue exceeds 4000 characters.');
        result[group.key] = SubtitleCue(index: cue.index, startMs: cue.startMs, endMs: cue.endMs,
          text: text, cueId: cue.stableId);
      }
      Navigator.pop(context, SubtitleDictionaryReview(List.unmodifiable(result), pack, _choices.length));
    } catch (_) { setState(() => _message = 'The selected corrections no longer match the source cues. Run the review again.'); }
  }
  @override
  Widget build(BuildContext context) {
    final pack = _pack, report = _report;
    return AlertDialog(title: Text(widget.cues == null ? 'Offline dictionaries' : 'Review spelling with an offline dictionary'),
      content: SizedBox(width: 680, height: (MediaQuery.sizeOf(context).height - 220).clamp(240.0, 660.0).toDouble(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Choose the language and edition explicitly. Missing vocabulary can be a name, inflection or valid spelling. Nothing is corrected automatically.'),
          DropdownButtonFormField<String>(key: ValueKey(pack?.digest), initialValue: pack?.digest,
            isExpanded: true, decoration: const InputDecoration(labelText: 'Installed dictionary / language'),
            items: [for (final entry in _store.saved.entries) DropdownMenuItem(value: entry.key,
              child: Text('${entry.value.language} · ${entry.value.title} (${entry.value.entries})', overflow: TextOverflow.ellipsis))],
            onChanged: _busy ? null : (value) { if (value != null) unawaited(_run(() async {
              final selected = await _store.load(value); if (_current) _select(selected);
            })); }),
          Wrap(spacing: 12, children: [TextButton(onPressed: _busy ? null : _import, child: const Text('Import dictionary JSON')),
            TextButton(onPressed: _busy || pack == null ? null : _remove, child: const Text('Remove dictionary')),
            if (widget.cues != null) FilledButton(onPressed: _busy || pack == null ? null : _check, child: const Text('Check this language'))]),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null) Text(_message!),
          if (widget.cues == null) ...[
            if (widget.contextText.isNotEmpty) SizedBox(height: 80, child: SingleChildScrollView(child: SelectableText(widget.contextText))),
            TextField(controller: _term, maxLength: 128, decoration: const InputDecoration(labelText: 'Word or phrase'),
              onSubmitted: (_) => _lookup()),
            TextButton(onPressed: _busy || pack == null ? null : _lookup, child: const Text('Look up locally')),
          ],
          Expanded(child: ListView.builder(itemCount: widget.cues == null ? _definitions.length : report?.candidates.length ?? 0,
            itemBuilder: (context, index) {
              if (widget.cues == null) {
                final entry = _definitions[index];
                return ListTile(title: Text(entry.term), subtitle: SelectableText(entry.definitions.isEmpty
                    ? 'Vocabulary entry; this pack provides no definition.' : entry.definitions.join('\n\n')));
              }
              final candidate = report!.candidates[index], cue = widget.cues![candidate.cue];
              return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Cue ${cue.index} · ${candidate.term}'), SelectableText(cue.text),
                DropdownButtonFormField<String>(key: ValueKey('${pack!.digest}:$index:${_choices[index]}'),
                  initialValue: _choices[index] ?? '', isExpanded: true,
                  items: [const DropdownMenuItem(value: '', child: Text('Keep original')),
                    for (final text in candidate.suggestions) DropdownMenuItem(value: text, child: Text(text))],
                  onChanged: _busy ? null : (value) => setState(() {
                    if (value == null || value.isEmpty) { _choices.remove(index); } else { _choices[index] = value; }
                  })),
              ]));
            })),
        ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (widget.cues != null) FilledButton(onPressed: _busy || _choices.isEmpty ? null : _apply,
          child: Text('Preview ${_choices.length} selected corrections'))]);
  }
  void _lookup() {
    if (!_current || _busy || _pack == null) return;
    setState(() {
      _definitions = _pack!.lookup(_term.text);
      _message = _definitions.isEmpty ? 'No exact normalized entry in this dictionary.' : '${_definitions.length} matching entries; supplied by ${_pack!.title}.';
    });
  }
}
