import 'package:flutter/material.dart';

import '../../../services/subtitle_job_service.dart';

class SubtitleJobsDialog extends StatefulWidget {
  const SubtitleJobsDialog({super.key, required this.identityKey, required this.playheadMs, required this.playbackBusy});
  final String? identityKey;
  final int Function() playheadMs;
  final bool Function() playbackBusy;

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
                  'Jobs continue while the app is open; the operating system may suspend the app.'),
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
                      LinearProgressIndicator(value: job.progress),
                      if (job.message != null) Text(job.message!),
                      if (job.chargingOnly || job.idleOnly)
                        Text([if (job.chargingOnly) 'External power only', if (job.idleOnly) 'While playback is idle'].join(' · ')),
                      if (job.identityKey != widget.identityKey) const Text('Open this media item to review or attach its result.'),
                      Wrap(spacing: 8, children: [
                        if (job.state == SubtitleJobState.running || job.state == SubtitleJobState.queued)
                          TextButton(onPressed: _working ? null : () => _action(() => service.pause(job)), child: const Text('Pause')),
                        if (job.state == SubtitleJobState.paused || job.state == SubtitleJobState.failed)
                          TextButton(onPressed: _working ? null : () => _action(() => service.resume(job,
                              playheadMs: job.identityKey == widget.identityKey ? widget.playheadMs : null,
                              playbackBusy: widget.playbackBusy)), child: const Text('Resume')),
                        if (!job.terminal)
                          TextButton(onPressed: _working ? null : () => _action(() => service.cancel(job)), child: const Text('Cancel')),
                        if (job.hasResult && job.identityKey == widget.identityKey)
                          TextButton(onPressed: _working ? null : () => Navigator.pop(context, job),
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
