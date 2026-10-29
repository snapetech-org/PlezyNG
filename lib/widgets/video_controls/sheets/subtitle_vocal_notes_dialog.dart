import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
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
  Map<String, Object?> reviewed(String Function(int cueIndex) invalidRange) {
    final a = int.tryParse(start), b = int.tryParse(end), midi = int.tryParse(pitch);
    if (a == null || b == null || midi == null || a < cue.startMs || b > cue.endMs || a >= b || midi < 0 || midi > 127) {
      throw FormatException(invalidRange(cue.index));
    }
    return {'cueId': cue.stableId, 'sourceNoteId': source?['noteId'], 'startMs': a, 'endMs': b, 'midi': midi,
      'origin': source == null ? 'viewer-added' : source!['startMs'] == a && source!['endMs'] == b && source!['midi'] == midi
          ? 'viewer-accepted-proposal' : 'viewer-corrected-proposal'};
  }
}

Future<void> showSubtitleVocalNoteReview(BuildContext context, {required SubtitleCompanionResult result,
    required String jobId, required String inputDigest, required bool Function() isCurrent}) async {
  final copy = Translations.of(context).videoControls.subtitleAiControls;
  try {
    final evidence = result.researchEvidence['vocalNoteEvidence'];
    if (!isCurrent() || result.itemTimeline || result.cues.isEmpty || result.cues.length > 120 ||
        result.provenance['task'] != 'vocal_notes' || evidence is! Map || evidence['declaredIsolatedLeadVocal'] != true ||
        evidence['cues'] is! List || (evidence['cues'] as List).length != result.cues.length) {
      throw FormatException(copy.vocalNoteResultMissing);
    }
    final cues = {for (final cue in result.cues) cue.stableId: cue}, notes = <_Note>[];
    final ids = <String>{}, cueRows = <String>{};
    for (final row in evidence['cues'] as List) {
      if (row is! Map || row['cueId'] is! String || row['candidates'] is! List) {
        throw FormatException(copy.vocalNoteCueIdentityInvalid);
      }
      final cueId = row['cueId'] as String, candidates = row['candidates'] as List;
      if (!cueRows.add(cueId) || cues[cueId] == null || candidates.length > 80) {
        throw FormatException(copy.vocalNoteCueIdentityInvalid);
      }
      final cue = cues[cueId]!;
      for (final raw in candidates) {
        if (raw is! Map || raw['noteId'] is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['noteId'] as String) ||
            !ids.add(raw['noteId'] as String) || raw['startMs'] is! int || raw['endMs'] is! int || raw['midi'] is! int ||
            notes.length >= 1000) throw FormatException(copy.vocalNoteCandidateInvalid);
        final note = _Note(raw['noteId'] as String, cue, Map<String, Object?>.from(raw),
          raw['startMs'] as int, raw['endMs'] as int, raw['midi'] as int);
        note.reviewed((index) => copy.vocalNoteInvalidRange(index: index)); // Validate proposal clocks before editing.
        notes.add(note);
      }
    }
    if (!context.mounted || !isCurrent()) return;
    await showDialog<void>(context: context, builder: (_) => _VocalNoteDialog(result: result, notes: notes,
      jobId: jobId, inputDigest: inputDigest, isCurrent: isCurrent));
  } on FormatException catch (error) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
  } catch (_) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy.vocalNoteCandidateInvalid)));
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
  Translations get _t => Translations.of(context);
  Translations$videoControls$subtitleAiControls$en get _copy => _t.videoControls.subtitleAiControls;
  Translations$videoControls$subtitleResearchReview$en get _reviewCopy => _t.videoControls.subtitleResearchReview;
  void _edit(VoidCallback action) => setState(() { action(); _checked = false; _status = null; });
  String _name(String value) {
    final pitch = int.tryParse(value);
    const names = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
    return pitch == null || pitch < 0 || pitch > 127 ? _copy.vocalNoteUnsetPitch : '${names[pitch % 12]}${pitch ~/ 12 - 1}';
  }

  Future<void> _add() async {
    if (widget.notes.length >= 1000 || !widget.isCurrent()) return;
    var cue = widget.result.cues.first;
    final chosen = await showDialog<SubtitleCue>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text(_copy.vocalNoteAddTitle),
        content: DropdownButtonFormField<SubtitleCue>(initialValue: cue, isExpanded: true,
          items: [for (final value in widget.result.cues) DropdownMenuItem(value: value,
            child: Text(_copy.vocalNoteCueOption(index: value.index, text: SubtitleOverlayTrack.plain(value.text)), maxLines: 1, overflow: TextOverflow.ellipsis))],
          onChanged: (value) { if (value != null) update(() => cue = value); }),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(_t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, cue), child: Text(_copy.vocalNoteAddAndEdit))])));
    if (!mounted || chosen == null || !widget.isCurrent()) return;
    _edit(() => widget.notes.add(_Note('manual-${++_manual}', chosen, null, chosen.startMs, chosen.endMs, null)..selected = true));
  }

  Future<void> _export() async {
    if (!_checked || _saving) return;
    setState(() { _saving = true; _status = null; });
    try {
      if (!widget.isCurrent()) throw StateError(_reviewCopy.itemChanged);
      final notes = [for (final note in widget.notes) if (note.selected)
        note.reviewed((index) => _copy.vocalNoteInvalidRange(index: index))];
      if (notes.isEmpty) throw FormatException(_copy.vocalNoteSelectAtLeastOne);
      notes.sort((a, b) => (a['startMs'] as int).compareTo(b['startMs'] as int));
      for (var i = 1; i < notes.length; i++) {
        if ((notes[i]['startMs'] as int) < (notes[i - 1]['endMs'] as int)) {
          throw FormatException(_copy.vocalNoteOverlap);
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
      if (!widget.isCurrent()) throw StateError(_reviewCopy.itemChanged);
      final saved = await FilePickerService.instance.saveFile(dialogTitle: _copy.vocalNoteExportTitle,
        fileName: 'PlezyNG.reviewed-vocal-notes.json', bytes: bytes,
        type: FileType.custom, allowedExtensions: const ['json']);
      if (mounted) setState(() => _status = saved == null ? _copy.vocalNoteExportCancelled : _copy.vocalNoteExported);
    } on FormatException catch (error) {
      if (mounted) setState(() => _status = error.message == 'vocalNoteReportLimit' ? _copy.vocalNoteReportLimit : error.message);
    } on StateError {
      if (mounted) setState(() => _status = _reviewCopy.itemChanged);
    } catch (_) {
      if (mounted) setState(() => _status = _copy.vocalNoteExportFailed);
    } finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(title: Text(_copy.vocalNoteDialogTitle),
    content: SizedBox(width: 740, height: (MediaQuery.sizeOf(context).height * .6).clamp(160.0, 620.0).toDouble(),
      child: CustomScrollView(slivers: [SliverToBoxAdapter(child: Column(children: [
        Text(_copy.vocalNoteReviewDescription),
        Text(_copy.vocalNoteBoundaryCaveat),
        ])), SliverList(delegate: SliverChildBuilderDelegate((context, index) {
          final note = widget.notes[index];
          return ExpansionTile(key: ValueKey(note.key),
            title: Text(_copy.vocalNoteCueTitle(index: note.cue.index, pitch: _name(note.pitch), start: note.start, end: note.end)),
            subtitle: Text(SubtitleOverlayTrack.plain(note.cue.text), maxLines: 1, overflow: TextOverflow.ellipsis),
            leading: Checkbox(value: note.selected, onChanged: _saving ? null : (v) => _edit(() => note.selected = v == true)),
            children: [Padding(padding: const EdgeInsets.all(8), child: Row(children: [
              for (final field in [_copy.vocalNoteStart, _copy.vocalNoteEnd, _copy.vocalNoteMidiPitch]) Expanded(child: Padding(padding: const EdgeInsets.all(4),
                child: TextFormField(initialValue: field == _copy.vocalNoteStart ? note.start : field == _copy.vocalNoteEnd ? note.end : note.pitch,
                  enabled: note.selected && !_saving, keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: field), onChanged: (value) => _edit(() {
                    if (field == _copy.vocalNoteStart) { note.start = value; }
                    else if (field == _copy.vocalNoteEnd) { note.end = value; } else { note.pitch = value; }
                  })))),
            ])), if (note.source != null) Padding(padding: const EdgeInsets.all(8),
              child: Text(_copy.vocalNoteOriginalProposal(start: note.source!['startMs'], end: note.source!['endMs'],
                midi: note.source!['midi'], score: note.source!['minimumVoicedScore'])))],
          );
        }, childCount: widget.notes.length)), SliverToBoxAdapter(child: Column(children: [
        CheckboxListTile(value: _checked, onChanged: _saving ? null : (v) => setState(() => _checked = v == true),
          title: Text(_copy.vocalNoteSourceCheck),
          subtitle: Text(_copy.vocalNoteSelectedSummary(count: widget.notes.where((note) => note.selected).length))),
        if (_status != null) Text(_status!),
        if (_saving) const LinearProgressIndicator(),
      ]))])),
    actions: [TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(_t.common.close)),
      TextButton(onPressed: _saving || widget.notes.length >= 1000 ? null : _add, child: Text(_copy.vocalNoteAddMissing)),
      FilledButton(onPressed: _saving || !_checked ? null : _export, child: Text(_copy.vocalNoteExportSelected))]);
}

Uint8List _encodeNotes(Map<String, Object?> report) {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(report)));
  if (bytes.length > 8 * 1024 * 1024) throw const FormatException('vocalNoteReportLimit');
  return bytes;
}
