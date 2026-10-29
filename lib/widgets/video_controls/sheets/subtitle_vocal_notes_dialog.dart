import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_companion_service.dart';
import '../../../services/subtitle_overlay_service.dart';
import '../../../services/subtitle_retimer.dart';

class _Note {
  _Note(this.key, this.cue, this.source, int start, int end, int? midi)
      : start = '$start', end = '$end', pitch = midi == null ? '' : '$midi';
  final String key;
  final SubtitleCue cue;
  final Map<String, Object?>? source;
  String start, end, pitch;
  bool selected = false;
  Map<String, Object?> reviewed() {
    final a = int.tryParse(start), b = int.tryParse(end), midi = int.tryParse(pitch);
    if (a == null || b == null || midi == null || a < cue.startMs || b > cue.endMs || a >= b || midi < 0 || midi > 127) {
      throw FormatException('Cue ${cue.index}: enter ordered times inside the cue and a MIDI pitch from 0 to 127.');
    }
    return {'cueId': cue.stableId, 'sourceNoteId': source?['noteId'], 'startMs': a, 'endMs': b, 'midi': midi,
      'origin': source == null ? 'viewer-added' : source!['startMs'] == a && source!['endMs'] == b && source!['midi'] == midi
          ? 'viewer-accepted-proposal' : 'viewer-corrected-proposal'};
  }
}

Future<void> showSubtitleVocalNoteReview(BuildContext context, {required SubtitleCompanionResult result,
    required String jobId, required String inputDigest, required bool Function() isCurrent}) async {
  try {
    final evidence = result.researchEvidence['vocalNoteEvidence'];
    if (!isCurrent() || result.itemTimeline || result.cues.isEmpty || result.cues.length > 120 ||
        result.provenance['task'] != 'vocal_notes' || evidence is! Map || evidence['declaredIsolatedLeadVocal'] != true ||
        evidence['cues'] is! List || (evidence['cues'] as List).length > 120) {
      throw const FormatException('This result does not contain a matching solo-vocal note proposal.');
    }
    final cues = {for (final cue in result.cues) cue.stableId: cue}, notes = <_Note>[];
    final ids = <String>{};
    for (final row in evidence['cues'] as List) {
      if (row is! Map || cues[row['cueId']] == null || row['candidates'] is! List) {
        throw const FormatException('Invalid cue identity in note evidence.');
      }
      final cue = cues[row['cueId']]!;
      for (final raw in row['candidates'] as List) {
        if (raw is! Map || raw['noteId'] is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['noteId'] as String) ||
            !ids.add(raw['noteId'] as String) || raw['startMs'] is! int || raw['endMs'] is! int || raw['midi'] is! int ||
            notes.length >= 1000) throw const FormatException('Invalid or excessive note candidates.');
        final note = _Note(raw['noteId'] as String, cue, Map<String, Object?>.from(raw),
          raw['startMs'] as int, raw['endMs'] as int, raw['midi'] as int);
        note.reviewed(); // Validate the proposal's clock and range before editing.
        notes.add(note);
      }
    }
    if (!context.mounted || !isCurrent()) return;
    await showDialog<void>(context: context, builder: (_) => _VocalNoteDialog(result: result, notes: notes,
      jobId: jobId, inputDigest: inputDigest, isCurrent: isCurrent));
  } on FormatException catch (error) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
  }
}

class _VocalNoteDialog extends StatefulWidget {
  const _VocalNoteDialog({required this.result, required this.notes, required this.jobId,
    required this.inputDigest, required this.isCurrent});
  final SubtitleCompanionResult result;
  final List<_Note> notes;
  final String jobId, inputDigest;
  final bool Function() isCurrent;
  @override
  State<_VocalNoteDialog> createState() => _VocalNoteDialogState();
}

class _VocalNoteDialogState extends State<_VocalNoteDialog> {
  bool _checked = false, _saving = false;
  int _manual = 0;
  String? _status;
  void _edit(VoidCallback action) => setState(() { action(); _checked = false; _status = null; });
  String _name(String value) {
    final pitch = int.tryParse(value);
    const names = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
    return pitch == null || pitch < 0 || pitch > 127 ? 'Unset pitch' : '${names[pitch % 12]}${pitch ~/ 12 - 1}';
  }

  Future<void> _add() async {
    if (widget.notes.length >= 1000 || !widget.isCurrent()) return;
    var cue = widget.result.cues.first;
    final chosen = await showDialog<SubtitleCue>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: const Text('Add a note inside a cue'),
        content: DropdownButtonFormField<SubtitleCue>(initialValue: cue, isExpanded: true,
          items: [for (final value in widget.result.cues) DropdownMenuItem(value: value,
            child: Text('Cue ${value.index}: ${SubtitleOverlayTrack.plain(value.text)}', maxLines: 1, overflow: TextOverflow.ellipsis))],
          onChanged: (value) { if (value != null) update(() => cue = value); }),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, cue), child: const Text('Add and edit'))])));
    if (!mounted || chosen == null || !widget.isCurrent()) return;
    _edit(() => widget.notes.add(_Note('manual-${++_manual}', chosen, null, chosen.startMs, chosen.endMs, null)..selected = true));
  }

  Future<void> _export() async {
    if (!_checked || _saving) return;
    setState(() { _saving = true; _status = null; });
    try {
      if (!widget.isCurrent()) throw StateError('The item or profile changed.');
      final notes = [for (final note in widget.notes) if (note.selected) note.reviewed()];
      if (notes.isEmpty) throw const FormatException('Select at least one checked note.');
      notes.sort((a, b) => (a['startMs'] as int).compareTo(b['startMs'] as int));
      for (var i = 1; i < notes.length; i++) {
        if ((notes[i]['startMs'] as int) < (notes[i - 1]['endMs'] as int)) {
          throw const FormatException('Selected solo-vocal notes overlap. Adjust their boundaries or deselect a duplicate.');
        }
      }
      final report = <String, Object?>{'schema': 'plezyng.reviewed-vocal-notes.v1',
        'jobId': widget.jobId, 'inputSha256': widget.inputDigest, 'clock': 'uploaded-file',
        'status': 'viewer-reviewed-notes', 'qualityQualified': false,
        'viewerDeclaredSourceComparison': true, 'reviewedAt': DateTime.now().toUtc().toIso8601String(),
        'notes': notes, 'unselectedCandidates': widget.notes.where((n) => n.source != null && !n.selected).length,
        'sourceEvidence': widget.result.researchEvidence['vocalNoteEvidence'], 'provenance': widget.result.provenance,
        'warnings': widget.result.warnings, 'captionTextAndTimingChanged': false,
        'cues': [for (final cue in widget.result.cues) {'cueId': cue.stableId, 'startMs': cue.startMs,
          'endMs': cue.endMs, 'text': cue.text}],
      };
      final bytes = await compute(_encodeNotes, report);
      if (!widget.isCurrent()) throw StateError('The item or profile changed.');
      final saved = await FilePickerService.instance.saveFile(fileName: 'PlezyNG.reviewed-vocal-notes.json', bytes: bytes,
        type: FileType.custom, allowedExtensions: const ['json']);
      if (mounted) setState(() => _status = saved == null ? 'Export cancelled.' : 'Reviewed notes exported; captions are unchanged.');
    } on FormatException catch (error) {
      if (mounted) setState(() => _status = error.message);
    } on StateError catch (error) {
      if (mounted) setState(() => _status = error.message);
    } catch (_) {
      if (mounted) setState(() => _status = 'Could not export reviewed notes.');
    } finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Review solo-vocal notes'),
    content: SizedBox(width: 740, height: (MediaQuery.sizeOf(context).height * .6).clamp(160.0, 620.0).toDouble(),
      child: CustomScrollView(slivers: [SliverToBoxAdapter(child: Column(children: [
        const Text('Compare each selected note against the uploaded isolated vocal. Correct its pitch and file-clock times, '
          'or add a missing note. No proposal is selected automatically. A viewer review does not qualify the model.'),
        const Text('The 20 ms output grid comes from 128 ms analysis windows; it is not a measured boundary-error limit.'),
        ])), SliverList(delegate: SliverChildBuilderDelegate((context, index) {
          final note = widget.notes[index];
          return ExpansionTile(key: ValueKey(note.key),
            title: Text('Cue ${note.cue.index} · ${_name(note.pitch)} · ${note.start}–${note.end} ms'),
            subtitle: Text(SubtitleOverlayTrack.plain(note.cue.text), maxLines: 1, overflow: TextOverflow.ellipsis),
            leading: Checkbox(value: note.selected, onChanged: _saving ? null : (v) => _edit(() => note.selected = v == true)),
            children: [Padding(padding: const EdgeInsets.all(8), child: Row(children: [
              for (final field in ['Start ms', 'End ms', 'MIDI pitch']) Expanded(child: Padding(padding: const EdgeInsets.all(4),
                child: TextFormField(initialValue: field == 'Start ms' ? note.start : field == 'End ms' ? note.end : note.pitch,
                  enabled: note.selected && !_saving, keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: field), onChanged: (value) => _edit(() {
                    if (field == 'Start ms') { note.start = value; }
                    else if (field == 'End ms') { note.end = value; } else { note.pitch = value; }
                  })))),
            ])), if (note.source != null) Padding(padding: const EdgeInsets.all(8),
              child: Text('Original proposal: ${note.source!['startMs']}–${note.source!['endMs']} ms, '
                'MIDI ${note.source!['midi']}; minimum voiced score ${note.source!['minimumVoicedScore']} (uncalibrated).'))],
          );
        }, childCount: widget.notes.length)), SliverToBoxAdapter(child: Column(children: [
        CheckboxListTile(value: _checked, onChanged: _saving ? null : (v) => setState(() => _checked = v == true),
          title: const Text('I checked the selected notes against the isolated source.'),
          subtitle: Text('${widget.notes.where((note) => note.selected).length} selected; exports are separate from lyric captions.')),
        if (_status != null) Text(_status!),
        if (_saving) const LinearProgressIndicator(),
      ]))])),
    actions: [TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Close')),
      TextButton(onPressed: _saving || widget.notes.length >= 1000 ? null : _add, child: const Text('Add missing note')),
      FilledButton(onPressed: _saving || !_checked ? null : _export, child: const Text('Export selected reviewed notes'))]);
}

Uint8List _encodeNotes(Map<String, Object?> report) {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(report)));
  if (bytes.length > 8 * 1024 * 1024) throw const FormatException('Note report exceeds 8 MiB.');
  return bytes;
}
