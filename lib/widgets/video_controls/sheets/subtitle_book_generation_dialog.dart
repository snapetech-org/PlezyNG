import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../services/subtitle_ai_service.dart';
import '../../../services/subtitle_book_generation.dart';
import '../../../services/subtitle_book_timeline.dart';
import '../../../services/subtitle_job_service.dart';
import '../../../services/subtitle_revision_service.dart';

class SubtitleBookGenerationDialog extends StatefulWidget {
  const SubtitleBookGenerationDialog({super.key, required this.timeline});
  final SubtitleBookTimeline timeline;
  @override
  State<SubtitleBookGenerationDialog> createState() => _SubtitleBookGenerationDialogState();
}

class _SubtitleBookGenerationDialogState extends State<SubtitleBookGenerationDialog> {
  final _service = SubtitleBookGeneration.instance;
  final _language = TextEditingController();
  late final List<int> _ordinals;
  SubtitleInferenceProvider _provider = SubtitleInferenceProvider.cpu;
  bool _ready = false, _working = false, _confirmed = false, _charging = false, _idle = false;
  String? _error;

  bool get _current {
    try { return widget.timeline.isCurrent(); } catch (_) { return false; }
  }
  @override
  void initState() {
    super.initState(); _ordinals = List.filled(widget.timeline.parts.length, 0);
    unawaited(_action(() async {
      await _service.open(widget.timeline, context.read<ActiveProfileProvider>());
      if (mounted && _current) _ready = true;
    }));
  }
  @override
  void dispose() { _language.dispose(); super.dispose(); }

  Future<void> _action(Future<void> Function() action) async {
    if (_working) return;
    setState(() { _working = true; _error = null; });
    try { await action(); }
    catch (_) {
      if (mounted) _error = Translations.of(context).videoControls.subtitleBook.generationActionFailed;
    } finally { if (mounted) setState(() => _working = false); }
  }

  Future<void> _review(int index) => _action(() async {
    final revision = await _service.result(index);
    if (!mounted || !_current) return;
    final copy = Translations.of(context).videoControls.subtitleBook;
    if (revision == null) {
      await showDialog<void>(context: context, builder: (context) => AlertDialog(
        title: Text(copy.noCuesTitle),
        content: Text(copy.noCuesBody),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(Translations.of(context).common.close))]));
      return;
    }
    final part = widget.timeline.parts[index];
    // Reject damaged or mismatched file clocks before displaying/accepting.
    widget.timeline.useRevision(part, revision, bookClock: false);
    var confirmed = false;
    final accept = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text(copy.reviewGeneratedFile(file: part.title)),
        content: SizedBox(width: 700, height: (MediaQuery.sizeOf(context).height - 180).clamp(240.0, 620.0).toDouble(),
          child: CustomScrollView(slivers: [SliverToBoxAdapter(child: Column(children: [
            Text(copy.unreviewedGeneratedHelp),
            CheckboxListTile(value: confirmed, title: Text(copy.confirmGeneratedReview),
              onChanged: (value) => update(() => confirmed = value == true)),
          ])), SliverList(delegate: SliverChildBuilderDelegate((context, cueIndex) {
            final cue = revision.cues[cueIndex];
            return ListTile(title: SelectableText(cue.text),
              subtitle: Text('${Duration(milliseconds: cue.startMs)} – ${Duration(milliseconds: cue.endMs)}'));
          }, childCount: revision.cues.length))])),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(Translations.of(context).common.close)),
          FilledButton(onPressed: confirmed && _current ? () => Navigator.pop(context, true) : null,
            child: Text(copy.saveAcceptedGeneration))],
      )));
    if (accept != true || !_current) return;
    await SubtitleRevisionService.saveRevision(identity: part.identity, operation: 'Book transcription',
      languageCode: revision.languageCode, cues: revision.cues, wordTimings: revision.wordTimings);
  });

  Future<void> _delete() => _action(() async {
    final copy = Translations.of(context).videoControls.subtitleBook;
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(copy.deleteGenerationTitle),
      content: Text(copy.deleteGenerationHelp),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(Translations.of(context).common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(copy.deleteBatchAction))]));
    if (accepted == true && _current) await _service.delete();
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _service, builder: (context, _) {
    final translations = Translations.of(context);
    final copy = translations.videoControls.subtitleBook;
    final jobsCopy = translations.videoControls.subtitleJobs;
    final current = _current, enabled = _ready && !_working && current;
    final existing = _service.hasStoredBatch;
    String batchMessage(String? message) {
      if (message == null) return '';
      final progress = RegExp(r'^(\d+)/(\d+) files saved · (.+)$').firstMatch(message);
      if (progress != null) return copy.generationProgress(
        completed: progress.group(1)!, total: progress.group(2)!, file: progress.group(3)!);
      return switch (message) {
        'All selected files have saved results. Review before use.' ||
        'All files have saved results. Review before use.' => copy.generationComplete,
        'Saved batch paused. Resume explicitly with this book open.' => copy.generationPaused,
        'This batch record could not be opened. Delete this batch before creating another; reviewed history is separate.' => copy.generationRecordUnavailable,
        'Preparing the next incomplete file.' => copy.preparingNextFile,
        'Book, order, edition or profile changed. Reopen the original book to resume.' => copy.bookGenerationChanged,
        'Paused outside the foreground. Resume explicitly.' => copy.pausedOutsideForeground,
        'The active file job was removed. Resume again to create a new job for that file.' => copy.generationJobMissing,
        'This saved file job does not match the book.' => copy.generationJobMismatch,
        'The file job paused or failed. Resume explicitly to retry its incomplete window.' => copy.retryGenerationWindow,
        'The file job was cancelled. Delete it in Transcription jobs, then resume this batch to retry.' => copy.generationJobCancelled,
        'This batch reached its 64 MiB result limit. The completed file job is retained for review.' => copy.generationResultLimit,
        'The batch paused. Completed files and windows are retained; check Transcription jobs, reopen the source and resume. Cancelled jobs must be deleted before retry; a full queue or result store must be cleared first.' => copy.generationPausedWithDetails,
        'Batch results deleted. Reviewed revision history is unchanged.' => copy.generationDeleted,
        _ => copy.generationStatusUnavailable,
      };
    }
    String jobState(SubtitleJobState state) => switch (state) {
      SubtitleJobState.queued => jobsCopy.stateQueued,
      SubtitleJobState.running => jobsCopy.stateRunning,
      SubtitleJobState.paused => jobsCopy.statePaused,
      SubtitleJobState.completed => jobsCopy.stateCompleted,
      SubtitleJobState.cancelled => jobsCopy.stateCancelled,
      SubtitleJobState.failed => jobsCopy.stateFailed,
    };
    String jobMessage(String? message) {
      if (message == null) return '';
      final progress = RegExp(r'^.+ · (\d+)/(\d+) windows saved$').firstMatch(message);
      if (progress != null) return jobsCopy.progressStatus(
        completed: progress.group(1)!, total: progress.group(2)!);
      return switch (message) {
        'Reopen the original file and audio stream to resume this source job.' => jobsCopy.reopenSource,
        'Waiting for playback to stop (reopen this item to report playback state).' => jobsCopy.waitingPlayback,
        'Waiting for confirmed external power.' => jobsCopy.waitingPower,
        'Preparing transcription' => jobsCopy.preparing,
        'All audio windows saved; review before attachment.' => jobsCopy.allAudioSaved,
        'This window could not finish. Completed windows are saved; resume to retry.' => jobsCopy.windowFailed,
        _ => jobsCopy.statusUnavailable,
      };
    }
    return PopScope(canPop: !_working, child: AlertDialog(title: Text(copy.generationTitle),
      content: SizedBox(width: 740, height: (MediaQuery.sizeOf(context).height - 180).clamp(300.0, 680.0).toDouble(),
        child: CustomScrollView(slivers: [SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(copy.generationDescription),
          if (!current) Text(copy.bookGenerationChanged),
          if (!_ready) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_service.message != null) Semantics(liveRegion: true, child: Text(batchMessage(_service.message))),
          if (existing) ...[
            Text(copy.generationSavedFiles(completed: _service.completedFiles, total: widget.timeline.parts.length)),
            if (_service.activeJob case final job?) ...[
              LinearProgressIndicator(value: job.progress),
              Text(jobsCopy.progress(state: jobState(job.state), completed: job.completedChunks, total: job.chunkCount)),
              if (job.message != null) Text(jobMessage(job.message)),
            ],
          ] else ...[
            DropdownButtonFormField<SubtitleInferenceProvider>(initialValue: _provider,
              decoration: InputDecoration(labelText: copy.localSpeechProvider),
              items: [for (final provider in SubtitleAiService.availableProviderRequests)
                DropdownMenuItem(value: provider, child: Text(provider.displayName))],
              onChanged: !enabled ? null : (value) => setState(() => _provider = value ?? _provider)),
            TextField(controller: _language, maxLength: 3,
              decoration: InputDecoration(labelText: copy.spokenLanguage),
              enabled: enabled),
            SwitchListTile(title: Text(jobsCopy.externalPower), value: _charging,
              onChanged: !enabled ? null : (value) => setState(() => _charging = value)),
            SwitchListTile(title: Text(jobsCopy.playbackIdle), value: _idle,
              onChanged: !enabled ? null : (value) => setState(() => _idle = value)),
            CheckboxListTile(value: _confirmed, title: Text(copy.confirmEveryFileStream),
              onChanged: !enabled ? null : (value) => setState(() => _confirmed = value == true)),
          ],
          Text(copy.generationLimits),
        ])), SliverList(delegate: SliverChildBuilderDelegate((context, index) {
          final part = widget.timeline.parts[index];
          return ListTile(title: Text(part.title), subtitle: Text('${Duration(milliseconds: part.durationMs)}'),
            trailing: existing ? (_service.completedIndices.contains(index)
              ? TextButton(onPressed: enabled ? () => _review(index) : null, child: Text(jobsCopy.reviewResult)) : Text(copy.generationPending))
              : SizedBox(width: 85, child: TextFormField(initialValue: '${_ordinals[index]}', enabled: enabled,
                  keyboardType: TextInputType.number, decoration: InputDecoration(labelText: copy.audioOrdinal),
                  onChanged: (value) { _ordinals[index] = int.tryParse(value) ?? -1; _confirmed = false; setState(() {}); })));
        }, childCount: widget.timeline.parts.length))])),
      actions: [
        if (existing) ...[
          TextButton(onPressed: enabled && !_service.busy ? _delete : null, child: Text(copy.deleteBatchAction)),
          if (!_service.complete) FilledButton(onPressed: !enabled || _service.busy ? null
              : () => _action(_service.running ? _service.pause : _service.resume),
            child: Text(_service.running ? jobsCopy.pause : jobsCopy.resume)),
        ] else FilledButton(onPressed: !enabled || !_confirmed ? null : () => _action(() async {
          final language = _language.text.trim().toLowerCase();
          await _service.create(ordinals: _ordinals, provider: _provider, language: language.isEmpty ? null : language,
            chargingOnly: _charging, idleOnly: _idle);
        }), child: Text(copy.startGeneration)),
        TextButton(onPressed: _working ? null : () => Navigator.pop(context), child: Text(translations.common.close)),
      ],
    ));
  });
}
