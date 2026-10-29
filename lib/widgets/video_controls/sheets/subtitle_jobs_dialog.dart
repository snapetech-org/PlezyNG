import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_job_service.dart';
import '../../../services/subtitle_job_source.dart';

class SubtitleJobsDialog extends StatefulWidget {
  const SubtitleJobsDialog({super.key, required this.identityKey, required this.playheadMs, required this.playbackBusy,
    this.openSource});
  final String? identityKey;
  final int Function() playheadMs;
  final bool Function() playbackBusy;
  final Future<SubtitleJobSource> Function(SubtitleJob)? openSource;

  @override
  State<SubtitleJobsDialog> createState() => _SubtitleJobsDialogState();
}

class _SubtitleJobsDialogState extends State<SubtitleJobsDialog> {
  String? _error;
  bool _working = false;

  Future<void> _action(Future<void> Function() action) async {
    if (_working) return;
    setState(() { _working = true; _error = null; });
    try { await action(); } catch (_) {
      if (mounted) setState(() => _error = Translations.of(context).videoControls.subtitleJobs.actionFailed);
    } finally { if (mounted) setState(() => _working = false); }
  }

  Future<void> _resume(SubtitleJob job) async {
    final source = job.usesSourceDecoder ? await widget.openSource!(job) : null;
    await SubtitleJobService.instance.resume(job, source: source,
      playheadMs: job.identityKey == widget.identityKey ? widget.playheadMs : null,
      playbackBusy: widget.playbackBusy);
  }

  Future<void> _review(SubtitleJob job) async {
    if (job.usesSourceDecoder) {
      final source = await widget.openSource!(job);
      try {
        if (!source.isCurrent || source.bindingKey != job.sourceBindingKey) {
          throw StateError('Open the same source file and audio stream before reviewing.');
        }
      } finally { await source.close(); }
    }
    if (mounted) Navigator.pop(context, job);
  }

  @override
  Widget build(BuildContext context) {
    final service = SubtitleJobService.instance;
    final copy = Translations.of(context).videoControls.subtitleJobs;
    String stateLabel(SubtitleJobState state) => switch (state) {
      SubtitleJobState.queued => copy.stateQueued,
      SubtitleJobState.running => copy.stateRunning,
      SubtitleJobState.paused => copy.statePaused,
      SubtitleJobState.completed => copy.stateCompleted,
      SubtitleJobState.cancelled => copy.stateCancelled,
      SubtitleJobState.failed => copy.stateFailed,
    };
    String jobMessage(String? message) {
      if (message == null) return '';
      final progress = RegExp(r'^.+ · (\d+)/(\d+) windows saved$').firstMatch(message);
      if (progress != null) return copy.progressStatus(
        completed: progress.group(1)!, total: progress.group(2)!);
      return switch (message) {
        'Reopen the original file and audio stream to resume this source job.' => copy.reopenSource,
        'Waiting for playback to stop (reopen this item to report playback state).' => copy.waitingPlayback,
        'Waiting for confirmed external power.' => copy.waitingPower,
        'Preparing transcription' => copy.preparing,
        'All audio windows saved; review before attachment.' => copy.allAudioSaved,
        'This window could not finish. Completed windows are saved; resume to retry.' => copy.windowFailed,
        _ => copy.statusUnavailable,
      };
    }
    String loadMessage(String? message) => switch (message) {
      'A damaged job record was skipped. Other jobs remain available.' => copy.loadDamaged,
      'The transcription queue could not be opened.' => copy.loadFailed,
      null => '',
      _ => copy.loadFailed,
    };
    return AlertDialog(
      title: Text(copy.title),
      content: SizedBox(
        width: 650,
        height: 470,
        child: AnimatedBuilder(
          animation: service,
          builder: (context, _) => ListView(
            children: [
              Text(copy.description),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (service.loadError != null) Text(loadMessage(service.loadError)),
              if (service.jobs.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(copy.noJobs)),
              for (final job in service.jobs) Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(job.title, style: Theme.of(context).textTheme.titleMedium),
                      Text(copy.progress(state: stateLabel(job.state), completed: job.completedChunks, total: job.chunkCount)),
                      if (job.usesSourceDecoder) Text(copy.sourceSummary(ordinal: job.audioOrdinal!)),
                      LinearProgressIndicator(value: job.progress),
                      if (job.message != null) Text(jobMessage(job.message)),
                      if (job.chargingOnly || job.idleOnly)
                        Text([if (job.chargingOnly) copy.externalPowerOnly, if (job.idleOnly) copy.whilePlaybackIdle].join(' · ')),
                      if (job.identityKey != widget.identityKey) Text(copy.openThisMedia),
                      Wrap(spacing: 8, children: [
                        if (job.state == SubtitleJobState.running || job.state == SubtitleJobState.queued)
                          TextButton(onPressed: _working ? null : () => _action(() => service.pause(job)), child: Text(copy.pause)),
                        if (job.state == SubtitleJobState.paused || job.state == SubtitleJobState.failed)
                          TextButton(onPressed: _working || job.usesSourceDecoder &&
                              (widget.openSource == null || job.identityKey != widget.identityKey) ? null
                              : () => _action(() => _resume(job)), child: Text(copy.resume)),
                        if (!job.terminal)
                          TextButton(onPressed: _working ? null : () => _action(() => service.cancel(job)), child: Text(copy.cancel)),
                        if (job.hasResult && job.identityKey == widget.identityKey)
                          TextButton(onPressed: _working || job.usesSourceDecoder && widget.openSource == null ? null
                              : () => _action(() => _review(job)),
                              child: Text(job.state == SubtitleJobState.completed ? copy.reviewResult : copy.reviewSaved)),
                        TextButton(onPressed: _working ? null : () => _action(() => service.delete(job)), child: Text(copy.delete)),
                      ]),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(Translations.of(context).common.close))],
    );
  }
}
