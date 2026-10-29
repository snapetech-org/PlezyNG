import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../i18n/strings.g.dart';
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
      if (!mounted) return;
      final t = Translations.of(context);
      final copy = t.videoControls.subtitleBook;
      _message = error is SubtitleBookException
          ? switch (error.issue) {
              SubtitleBookIssue.changed => copy.changed,
              SubtitleBookIssue.clockOutsidePart => copy.clockMismatch,
              SubtitleBookIssue.invalidExport => copy.invalidExport,
              SubtitleBookIssue.exportTooLarge => copy.exportTooLarge,
              SubtitleBookIssue.combinedLimit => copy.combinedLimit,
            }
          : copy.actionFailed;
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _select(SubtitleBookPart part) => _run(() async {
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleBook;
    final revisions = await SubtitleRevisionService.loadRevisions(part.identity);
    if (!mounted || !_current) return;
    if (revisions.isEmpty) { _message = copy.noSavedRevisions(file: part.title); return; }
    var bookClock = false, confirmed = false;
    final revision = await showDialog<SubtitleRevision>(context: context, builder: (context) => AnimatedBuilder(
      animation: widget.timeline.changes, builder: (context, _) => !_current
        ? AlertDialog(title: Text(copy.sourceChangedTitle), actions: [TextButton(
          onPressed: () => Navigator.pop(context), child: Text(t.common.close))]) : StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text(copy.savedRevisionTitle(title: part.title)),
        content: SizedBox(width: 620, height: 440, child: Column(children: [
          Text(copy.fileClockInfo(start: Duration(milliseconds: part.startMs),
            duration: Duration(milliseconds: part.durationMs))),
          SwitchListTile(title: Text(copy.bookClockTitle), value: bookClock,
            subtitle: Text(copy.bookClockHelp),
            onChanged: (value) => update(() { bookClock = value; confirmed = false; })),
          CheckboxListTile(title: Text(copy.confirmationTitle),
            subtitle: Text(copy.confirmationHelp),
            value: confirmed, onChanged: (value) => update(() => confirmed = value == true)),
          Expanded(child: ListView.builder(itemCount: revisions.length, itemBuilder: (context, index) {
            final item = revisions[index];
            return ListTile(title: Text(copy.revisionSummary(
                operation: item.operation,
                language: item.languageCode ?? copy.unspecifiedLanguage)),
              subtitle: Text(copy.revisionDetails(
                createdAt: item.createdAt.toLocal(),
                count: item.cues.length,
                firstCue: item.cues.isEmpty
                    ? copy.none
                    : Duration(milliseconds: item.cues.first.startMs))),
              enabled: confirmed, onTap: !confirmed ? null : () => Navigator.pop(context, item));
          })),
        ])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel))],
      ))));
    if (revision == null || !mounted || !_current) return;
    final added = widget.timeline.useRevision(part, revision, bookClock: bookClock);
    final all = [for (final entry in _selected.entries) if (entry.key != part.fileIndex) ...entry.value, ...added];
    if (all.length > 50000 || all.fold<int>(0, (sum, cue) => sum + utf8.encode(cue.source.text).length) > 5 * 1024 * 1024) {
      throw const SubtitleBookException(SubtitleBookIssue.combinedLimit);
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
    final t = Translations.of(context);
    final copy = t.videoControls.subtitleBook;
    final current = _current, position = widget.timeline.positionMs(), query = _search.text.toLowerCase().trim();
    if (!current) return AlertDialog(title: Text(copy.unavailableTitle),
      content: Text(copy.unavailableBody),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close))]);
    final visible = _cues.where((cue) => (!_hideFuture || cue.startMs <= position) &&
      (query.isEmpty || SubtitleRubyText.plain(cue.source.text).toLowerCase().contains(query))).toList();
    return PopScope(canPop: !_busy, child: AlertDialog(title: Text(copy.title(title: widget.timeline.title)),
      content: SizedBox(width: 760, height: (MediaQuery.sizeOf(context).height - 180).clamp(300.0, 700.0).toDouble(),
        child: Column(children: [
          Text(copy.description),
          Row(children: [Expanded(child: Text(copy.selectedSummary(
              selected: _selected.length, total: widget.timeline.parts.length, cues: _cues.length))),
            FilterChip(label: Text(copy.hideFutureText), selected: _hideFuture,
              onSelected: (value) => setState(() => _hideFuture = value))]),
          SizedBox(height: 125, child: ListView.builder(itemCount: widget.timeline.parts.length,
            itemBuilder: (context, index) {
              final part = widget.timeline.parts[index], selected = _selected[part.fileIndex];
              return ListTile(dense: true, title: Text(part.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${Duration(milliseconds: part.startMs)} · '
                    '${selected == null ? copy.noRevisionSelected : copy.cueCount(count: selected.length)}'),
                onTap: _busy || !current ? null : () => _select(part),
                trailing: selected == null ? const Icon(Icons.add) : IconButton(tooltip: copy.removeFile,
                  onPressed: _busy ? null : () => setState(() {
                    _selected.remove(part.fileIndex); _cues = _cues.where((cue) => cue.part.fileIndex != part.fileIndex).toList();
                  }), icon: const Icon(Icons.close)));
            })),
          TextField(controller: _search, maxLength: 128, decoration: InputDecoration(labelText: copy.searchSelected, counterText: ''),
            onChanged: (_) => setState(() {})),
          if (_message != null) Semantics(liveRegion: true, child: Text(_message!)),
          Expanded(child: ListView.builder(itemCount: visible.length, itemBuilder: (context, index) {
            final cue = visible[index], text = SubtitleRubyText.plain(cue.source.text);
            return ListTile(title: SelectableText(text), subtitle: Text('${Duration(milliseconds: cue.startMs)} · ${cue.part.title}'),
              leading: IconButton(tooltip: copy.seekCue, icon: const Icon(Icons.play_arrow),
                onPressed: _busy || !current ? null : () => _run(() => widget.timeline.seek(cue.part.fileIndex, cue.fileStartMs))),
              trailing: IconButton(tooltip: copy.copyCue, icon: const Icon(Icons.copy),
                onPressed: () => Clipboard.setData(ClipboardData(text: text))));
          })),
        ])), actions: [TextButton(onPressed: _busy || !current || _cues.isEmpty ? null : _export, child: Text(copy.export)),
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(t.common.close))],
    ));
  }
}
