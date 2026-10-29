import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_artifact_export.dart';
import '../../../services/subtitle_companion_service.dart';
import '../../../services/subtitle_overlay_service.dart';
import 'subtitle_vocal_notes_dialog.dart';

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

  Translations get _t => Translations.of(context);

  String _sectionLabel(String key) {
    final copy = _t.videoControls.subtitleResearchReview;
    return switch (key) {
      'coverageEvidence' => copy.possibleUncoveredSpeech,
      'ensembleEvidence' => copy.recognitionComparison,
      'soundEvidence' => copy.soundEventsAndMix,
      'lyricTimingEvidence' => copy.lyricBoundaryAgreement,
      'lyricSyllableEvidence' => copy.suppliedSyllableAlignment,
      'lyricPitchEvidence' => copy.pitchCandidates,
      'uncertainCueIds' => copy.noAgreedWordProposal,
      'sceneRegionTracks' => copy.sampledRegionPaths,
      'sceneAudioEvidence' => copy.sceneAudioEvidence,
      'sceneMotionEvidence' => copy.sceneMotionObservations,
      'sceneObjectEvidence' => copy.sceneObjectObservations,
      'soundLocalizationEvidence' => copy.soundLocalizationEvidence,
      'vocalNoteEvidence' => copy.vocalNoteEvidenceSection,
      'synthesisEvidence' => copy.synthesizedLineFit,
      _ => copy.unknownSection(name: key.replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m[1]}')),
    };
  }

  Future<void> _export() async {
    final copy = _t.videoControls.subtitleResearchReview;
    setState(() { _saving = true; _status = null; });
    try {
      if (!widget.isCurrent()) throw StateError(copy.itemChanged);
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
      if (!widget.isCurrent()) throw StateError(copy.itemChanged);
      final saved = await SubtitleArtifactExport.saveFile(dialogTitle: copy.exportTitle,
        fileName: 'subtitle-research-${widget.jobId.substring(0, 8)}.json', bytes: bytes,
        type: FileType.custom, allowedExtensions: const ['json']);
      if (mounted) setState(() => _status = saved == null ? copy.exportCancelled : copy.exported);
    } catch (error) {
      if (mounted) setState(() => _status = error is FormatException ? copy.reportTooLarge
          : error is StateError ? copy.itemChanged : copy.exportFailed);
    } finally { if (mounted) setState(() => _saving = false); }
  }

  static Uint8List _encode(Map<String, Object?> report) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(report)));
    if (bytes.length > 24 * 1024 * 1024) throw const FormatException('Research report exceeds 24 MiB');
    return bytes;
  }

  Widget _observation(Object? value, int index) {
    final copy = _t.videoControls.subtitleResearchReview;
    final id = value is Map ? value['cueId'] : value is String ? value : null;
    final cue = id is String ? _cues[id] : null;
    final detail = const JsonEncoder.withIndent('  ').convert(value);
    return ExpansionTile(key: ValueKey(index), title: Text(cue == null
        ? copy.observation(index: index + 1) : copy.cue(index: cue.index)),
      subtitle: cue == null ? null : Text(SubtitleOverlayTrack.plain(cue.text), maxLines: 2, overflow: TextOverflow.ellipsis),
      children: [Padding(padding: const EdgeInsets.all(12), child: SelectableText(
        detail.length <= 12000 ? detail : '${detail.substring(0, 12000)}\n${copy.truncatedObservation}'))]);
  }

  @override
  Widget build(BuildContext context) {
    final copy = _t.videoControls.subtitleResearchReview;
    final result = widget.result, sections = result.researchEvidence.entries.toList();
    return AlertDialog(title: Text(copy.title), content: SizedBox(width: 760,
      height: (MediaQuery.sizeOf(context).height * .55).clamp(140.0, 520.0).toDouble(),
      child: ListView(children: [
        Text(copy.description),
        if (result.researchEvidence.containsKey('vocalNoteEvidence')) TextButton(onPressed: _saving ? null : () async {
          await showSubtitleVocalNoteReview(context, result: result, jobId: widget.jobId,
            inputDigest: widget.inputDigest, isCurrent: widget.isCurrent);
        }, child: Text(copy.vocalNoteReviewAction)),
        const SizedBox(height: 12),
        Text(copy.clockSummary(clock: result.itemTimeline ? copy.itemTimeline : copy.uploadedFileTimeline,
          digest: widget.inputDigest)),
        ExpansionTile(title: Text(copy.provenance), children: [
          Padding(padding: const EdgeInsets.all(12), child: SelectableText(const JsonEncoder.withIndent('  ').convert(result.provenance))),
        ]),
        ExpansionTile(title: Text(copy.reviewNotes(count: result.warnings.length)), children: [
          for (final warning in result.warnings) Padding(padding: const EdgeInsets.all(8), child: Text(warning)),
        ]),
        for (final section in sections) ExpansionTile(title: Text(_sectionLabel(section.key)),
          subtitle: Text(section.value is List ? copy.observationsCount(count: (section.value as List).length) : copy.jobMeasurements),
          children: [SizedBox(height: 300, child: section.value is List
            ? ListView.builder(itemCount: (section.value as List).length,
                itemBuilder: (_, index) => _observation((section.value as List)[index], index))
            : SingleChildScrollView(child: _observation(section.value, 0)))]),
        if (_status != null) Text(_status!),
        if (_saving) const LinearProgressIndicator(),
      ])), actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: Text(_t.common.close)),
        TextButton(onPressed: _saving ? null : _export, child: Text(copy.exportAction)),
        FilledButton(onPressed: _saving ? null : () {
          if (widget.isCurrent()) Navigator.pop(context, true);
          else setState(() => _status = copy.itemChanged);
        }, child: Text(copy.continueReview)),
      ]);
  }
}
