import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;

import '../../../services/file_picker_service.dart';
import '../../../services/subtitle_companion_service.dart';
import '../../../services/subtitle_overlay_service.dart';

/// Review host observations separately from the later editable caption draft.
/// Export records the returned baseline, not a claim that the viewer accepted it.
class SubtitleResearchReviewDialog extends StatefulWidget {
  const SubtitleResearchReviewDialog({super.key, required this.result, required this.jobId,
    required this.inputDigest, required this.isCurrent});
  final SubtitleCompanionResult result;
  final String jobId, inputDigest;
  final bool Function() isCurrent;
  @override
  State<SubtitleResearchReviewDialog> createState() => _SubtitleResearchReviewDialogState();
}

class _SubtitleResearchReviewDialogState extends State<SubtitleResearchReviewDialog> {
  bool _saving = false;
  String? _status;
  late final _cues = {for (final cue in widget.result.cues) cue.stableId: cue};
  static const _labels = {
    'coverageEvidence': 'Possible uncovered speech', 'ensembleEvidence': 'Recognition comparison',
    'soundEvidence': 'Possible sound events and mix balance', 'lyricTimingEvidence': 'Lyric boundary agreement',
    'lyricSyllableEvidence': 'Supplied syllable alignment', 'lyricPitchEvidence': 'Mix pitch candidates (unqualified)',
    'uncertainCueIds': 'Cues without an agreed word proposal', 'sceneRegionTracks': 'Sampled region paths',
    'sceneAudioEvidence': 'Audio sent with scene images', 'sceneMotionEvidence': 'Local motion tracking observations',
    'sceneObjectEvidence': 'Local object classes and short-gap association',
    'synthesisEvidence': 'Synthesized line fitting and omissions',
  };

  Future<void> _export() async {
    setState(() { _saving = true; _status = null; });
    try {
      if (!widget.isCurrent()) throw StateError('The playback item changed');
      final result = widget.result;
      final report = <String, Object?>{'schema': 'plezyng.subtitle-research-review.v1', 'jobId': widget.jobId,
        'inputSha256': widget.inputDigest, 'itemTimeline': result.itemTimeline,
        'status': 'host-observations-before-viewer-edits', 'qualityQualified': false,
        'provenance': result.provenance, 'warnings': result.warnings, 'language': result.language,
        'cues': [for (final cue in result.cues) {'cueId': cue.stableId, 'index': cue.index,
          'startMs': cue.startMs, 'endMs': cue.endMs, 'text': cue.text}],
        'wordTimings': [for (final word in result.wordTimings) {'cueId': word.cueId,
          'startMs': word.startMs, 'endMs': word.endMs, 'text': word.text,
          'confidence': word.confidence, 'unit': word.unit.name}],
        'alternatives': result.alternatives, 'evidence': result.researchEvidence,
        'images': [for (final image in result.images) image.toJson()],
        'artifacts': [for (final artifact in result.artifacts) {'name': artifact.name, 'sha256': artifact.digest,
          'bytes': artifact.bytes, 'mime': artifact.mime}],
      };
      // Compact JSON leaves room for large, bounded motion observations. Image
      // descriptors are included; image pixels use the existing image export.
      final bytes = await compute(_encode, report);
      if (!widget.isCurrent()) throw StateError('The playback item changed');
      final saved = await FilePickerService.instance.saveFile(dialogTitle: 'Export research evidence',
        fileName: 'subtitle-research-${widget.jobId.substring(0, 8)}.json', bytes: bytes,
        type: FileType.custom, allowedExtensions: const ['json']);
      if (mounted) setState(() => _status = saved == null ? 'Export cancelled' : 'Research evidence exported');
    } catch (error) {
      if (mounted) setState(() => _status = error is FormatException ? error.message : 'Could not export this evidence');
    } finally { if (mounted) setState(() => _saving = false); }
  }

  static Uint8List _encode(Map<String, Object?> report) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(report)));
    if (bytes.length > 24 * 1024 * 1024) throw const FormatException('Research report exceeds 24 MiB');
    return bytes;
  }

  Widget _observation(Object? value, int index) {
    final id = value is Map ? value['cueId'] : value is String ? value : null;
    final cue = id is String ? _cues[id] : null;
    final detail = const JsonEncoder.withIndent('  ').convert(value);
    return ExpansionTile(key: ValueKey(index), title: Text(cue == null ? 'Observation ${index + 1}' : 'Cue ${cue.index}'),
      subtitle: cue == null ? null : Text(SubtitleOverlayTrack.plain(cue.text), maxLines: 2, overflow: TextOverflow.ellipsis),
      children: [Padding(padding: const EdgeInsets.all(12), child: SelectableText(
        detail.length <= 12000 ? detail : '${detail.substring(0, 12000)}\n… Export JSON to read the complete observation.'))]);
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result, sections = result.researchEvidence.entries.toList();
    return AlertDialog(title: const Text('Review research evidence'), content: SizedBox(width: 760,
      height: (MediaQuery.sizeOf(context).height * .55).clamp(140.0, 520.0).toDouble(),
      child: ListView(children: [
        const Text('These are unqualified model outputs and measurements. Agreement, scores and region paths do not prove accuracy. '
          'Continue to review the caption wording and timing separately.'),
        const SizedBox(height: 12),
        Text('Clock: ${result.itemTimeline ? 'item timeline' : 'uploaded file timeline'}. '
          'Input SHA-256: ${widget.inputDigest}'),
        ExpansionTile(title: const Text('Model and processing provenance'), children: [
          Padding(padding: const EdgeInsets.all(12), child: SelectableText(const JsonEncoder.withIndent('  ').convert(result.provenance))),
        ]),
        ExpansionTile(title: Text('Review notes (${result.warnings.length})'), children: [
          for (final warning in result.warnings) Padding(padding: const EdgeInsets.all(8), child: Text(warning)),
        ]),
        for (final section in sections) ExpansionTile(title: Text(_labels[section.key] ?? section.key),
          subtitle: Text(section.value is List ? '${(section.value as List).length} observations' : 'Job-level measurements'),
          children: [SizedBox(height: 300, child: section.value is List
            ? ListView.builder(itemCount: (section.value as List).length,
                itemBuilder: (_, index) => _observation((section.value as List)[index], index))
            : SingleChildScrollView(child: _observation(section.value, 0)))]),
        if (_status != null) Text(_status!),
        if (_saving) const LinearProgressIndicator(),
      ])), actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Close')),
        TextButton(onPressed: _saving ? null : _export, child: const Text('Export evidence JSON')),
        FilledButton(onPressed: _saving ? null : () {
          if (widget.isCurrent()) Navigator.pop(context, true);
          else setState(() => _status = 'The playback item changed');
        }, child: const Text('Continue to caption review')),
      ]);
  }
}
