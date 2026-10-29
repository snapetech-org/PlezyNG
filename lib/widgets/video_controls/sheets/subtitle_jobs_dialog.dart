import 'package:flutter/material.dart';

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
      if (mounted) setState(() => _error = 'The job could not be updated. Reopen the queue and try again.');
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
    return AlertDialog(
      title: const Text('Transcription jobs'),
      content: SizedBox(
        width: 650,
        height: 470,
        child: AnimatedBuilder(
          animation: service,
          builder: (context, _) => ListView(
            children: [
              const Text('Completed 30-second windows survive restarts. Resume is explicit after restart. '
                  'Pause and cancel discard the current window when native inference returns. '
                  'Source jobs pause when the app leaves the foreground and require the original file/audio to resume or review. '
                  'WAV jobs keep an owned audio copy. Jobs never attach results automatically.'),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (service.loadError != null) Text(service.loadError!),
              if (service.jobs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No jobs in this profile.')),
              for (final job in service.jobs) Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(job.title, style: Theme.of(context).textTheme.titleMedium),
                      Text('${job.state.name} · ${job.completedChunks}/${job.chunkCount} windows'),
                      if (job.usesSourceDecoder) Text('Source decoder · audio ordinal ${job.audioOrdinal} · temporary audio only'),
                      LinearProgressIndicator(value: job.progress),
                      if (job.message != null) Text(job.message!),
                      if (job.chargingOnly || job.idleOnly)
                        Text([if (job.chargingOnly) 'External power only', if (job.idleOnly) 'While playback is idle'].join(' · ')),
                      if (job.identityKey != widget.identityKey) const Text('Open this media item to review or attach its result.'),
                      Wrap(spacing: 8, children: [
                        if (job.state == SubtitleJobState.running || job.state == SubtitleJobState.queued)
                          TextButton(onPressed: _working ? null : () => _action(() => service.pause(job)), child: const Text('Pause')),
                        if (job.state == SubtitleJobState.paused || job.state == SubtitleJobState.failed)
                          TextButton(onPressed: _working || job.usesSourceDecoder &&
                              (widget.openSource == null || job.identityKey != widget.identityKey) ? null
                              : () => _action(() => _resume(job)), child: const Text('Resume')),
                        if (!job.terminal)
                          TextButton(onPressed: _working ? null : () => _action(() => service.cancel(job)), child: const Text('Cancel')),
                        if (job.hasResult && job.identityKey == widget.identityKey)
                          TextButton(onPressed: _working || job.usesSourceDecoder && widget.openSource == null ? null
                              : () => _action(() => _review(job)),
                              child: Text(job.state == SubtitleJobState.completed ? 'Review result' : 'Review saved portion')),
                        TextButton(onPressed: _working ? null : () => _action(() => service.delete(job)), child: const Text('Delete')),
                      ]),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
