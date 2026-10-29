import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_book_timeline.dart';
import '../../../services/subtitle_revision_service.dart';
import '../../../services/subtitle_ruby_text.dart';

class SubtitleBookDialog extends StatefulWidget {
  const SubtitleBookDialog({super.key, required this.timeline});
  final SubtitleBookTimeline timeline;
  @override
  State<SubtitleBookDialog> createState() => _SubtitleBookDialogState();
}

class _SubtitleBookDialogState extends State<SubtitleBookDialog> {
  final _search = TextEditingController();
  final Map<int, List<SubtitleBookCue>> _selected = {};
  List<SubtitleBookCue> _cues = [];
  Timer? _timer;
  bool _busy = false, _hideFuture = true;
  String? _message;
  bool get _current { try { return widget.timeline.isCurrent(); } catch (_) { return false; } }

  @override
  void initState() {
    super.initState();
    widget.timeline.changes.addListener(_changed);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  void _changed() {
    if (!mounted || _current) return;
    _selected.clear(); _cues = [];
    setState(() {});
  }

  @override
  void dispose() { widget.timeline.changes.removeListener(_changed); _timer?.cancel(); _search.dispose(); super.dispose(); }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_current) return;
    setState(() { _busy = true; _message = null; });
    try { await action(); }
    catch (error) {
      if (mounted) _message = error is FormatException ? error.message
          : error is StateError ? error.message.toString() : 'The transcript action could not complete.';
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _select(SubtitleBookPart part) => _run(() async {
    final revisions = await SubtitleRevisionService.loadRevisions(part.identity);
    if (!mounted || !_current) return;
    if (revisions.isEmpty) { _message = 'No saved revisions for this exact file. Generate or import one through its transcript tools first.'; return; }
    var bookClock = false, confirmed = false;
    final revision = await showDialog<SubtitleRevision>(context: context, builder: (context) => AnimatedBuilder(
      animation: widget.timeline.changes, builder: (context, _) => !_current
        ? AlertDialog(title: const Text('Source changed'), actions: [TextButton(
          onPressed: () => Navigator.pop(context), child: const Text('Close'))]) : StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text('Saved transcript: ${part.title}'),
        content: SizedBox(width: 620, height: 440, child: Column(children: [
          Text('File starts at ${Duration(milliseconds: part.startMs)} in this queue and lasts ${Duration(milliseconds: part.durationMs)}.'),
          SwitchListTile(title: const Text('Revision timestamps use the whole book clock'), value: bookClock,
            subtitle: const Text('Off: file-local timestamps, as used by standalone transcription. On: subtract this file’s book offset. Cues outside the file are refused.'),
            onChanged: (value) => update(() { bookClock = value; confirmed = false; })),
          CheckboxListTile(title: const Text('I checked this file, edition, audio and timestamp basis'),
            subtitle: const Text('The file identity matches; that does not prove the selected revision matches this narration.'),
            value: confirmed, onChanged: (value) => update(() => confirmed = value == true)),
          Expanded(child: ListView.builder(itemCount: revisions.length, itemBuilder: (context, index) {
            final item = revisions[index];
            return ListTile(title: Text('${item.operation} · ${item.languageCode ?? 'unspecified language'}'),
              subtitle: Text('${item.createdAt.toLocal()} · ${item.cues.length} cues\n'
                'First cue: ${item.cues.isEmpty ? 'none' : Duration(milliseconds: item.cues.first.startMs)}'),
              enabled: confirmed, onTap: !confirmed ? null : () => Navigator.pop(context, item));
          })),
        ])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
      ))));
    if (revision == null || !mounted || !_current) return;
    final added = widget.timeline.useRevision(part, revision, bookClock: bookClock);
    final all = [for (final entry in _selected.entries) if (entry.key != part.fileIndex) ...entry.value, ...added];
    if (all.length > 50000 || all.fold<int>(0, (sum, cue) => sum + utf8.encode(cue.source.text).length) > 5 * 1024 * 1024) {
      throw const FormatException('The combined view is limited to 50000 cues and 5 MiB of text.');
    }
    all.sort((a, b) => a.startMs.compareTo(b.startMs));
    _selected[part.fileIndex] = added;
    _cues = all;
  });

  Future<void> _export() => _run(() async {
    final bytes = widget.timeline.export(_cues);
    final path = await FilePickerService.instance.saveFile(fileName: 'PlezyNG.book-transcript.json', bytes: bytes,
      type: FileType.custom, allowedExtensions: const ['json']);
    if (path != null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
  });

  @override
  Widget build(BuildContext context) {
    final current = _current, position = widget.timeline.positionMs(), query = _search.text.toLowerCase().trim();
    if (!current) return AlertDialog(title: const Text('Book transcript unavailable'),
      content: const Text('The source, profile, queue order or a file duration changed. Reopen the transcript for the current book.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]);
    final visible = _cues.where((cue) => (!_hideFuture || cue.startMs <= position) &&
      (query.isEmpty || SubtitleRubyText.plain(cue.source.text).toLowerCase().contains(query))).toList();
    return PopScope(canPop: !_busy, child: AlertDialog(title: Text('Book transcript: ${widget.timeline.title}'),
      content: SizedBox(width: 760, height: (MediaQuery.sizeOf(context).height - 180).clamp(300.0, 700.0).toDouble(),
        child: Column(children: [
          const Text('Select a saved revision for each file. This view adds the current queue offsets once and does not replace '
            'native subtitles or original revisions. Seeking preserves the current play/pause state. Missing files stay visibly incomplete.'),
          Row(children: [Expanded(child: Text('${_selected.length}/${widget.timeline.parts.length} files selected · ${_cues.length} cues')),
            FilterChip(label: const Text('Hide future text'), selected: _hideFuture,
              onSelected: (value) => setState(() => _hideFuture = value))]),
          SizedBox(height: 125, child: ListView.builder(itemCount: widget.timeline.parts.length,
            itemBuilder: (context, index) {
              final part = widget.timeline.parts[index], selected = _selected[part.fileIndex];
              return ListTile(dense: true, title: Text(part.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${Duration(milliseconds: part.startMs)} · ${selected == null ? 'No revision selected' : '${selected.length} cues'}'),
                onTap: _busy || !current ? null : () => _select(part),
                trailing: selected == null ? const Icon(Icons.add) : IconButton(tooltip: 'Remove this file from the view',
                  onPressed: _busy ? null : () => setState(() {
                    _selected.remove(part.fileIndex); _cues = _cues.where((cue) => cue.part.fileIndex != part.fileIndex).toList();
                  }), icon: const Icon(Icons.close)));
            })),
          TextField(controller: _search, maxLength: 128, decoration: const InputDecoration(labelText: 'Search selected transcripts', counterText: ''),
            onChanged: (_) => setState(() {})),
          if (_message != null) Semantics(liveRegion: true, child: Text(_message!)),
          Expanded(child: ListView.builder(itemCount: visible.length, itemBuilder: (context, index) {
            final cue = visible[index], text = SubtitleRubyText.plain(cue.source.text);
            return ListTile(title: SelectableText(text), subtitle: Text('${Duration(milliseconds: cue.startMs)} · ${cue.part.title}'),
              leading: IconButton(tooltip: 'Seek to this cue in its source file', icon: const Icon(Icons.play_arrow),
                onPressed: _busy || !current ? null : () => _run(() => widget.timeline.seek(cue.part.fileIndex, cue.fileStartMs))),
              trailing: IconButton(tooltip: 'Copy cue text', icon: const Icon(Icons.copy),
                onPressed: () => Clipboard.setData(ClipboardData(text: text))));
          })),
        ])), actions: [TextButton(onPressed: _busy || !current || _cues.isEmpty ? null : _export, child: const Text('Export book transcript JSON')),
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Close'))],
    ));
  }
}
