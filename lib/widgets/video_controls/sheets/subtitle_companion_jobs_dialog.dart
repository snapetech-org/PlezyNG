import 'package:flutter/material.dart';

import '../../../services/subtitle_companion_service.dart';

class SubtitleCompanionJobsDialog extends StatefulWidget {
  const SubtitleCompanionJobsDialog({super.key, required this.service, required this.identityKey});
  final SubtitleCompanionService service;
  final String? identityKey;
  @override
  State<SubtitleCompanionJobsDialog> createState() => _SubtitleCompanionJobsDialogState();
}

class _SubtitleCompanionJobsDialogState extends State<SubtitleCompanionJobsDialog> {
  List<Map<String, dynamic>> _jobs = [];
  bool _loading = false;
  String? _error;
  @override
  void initState() { super.initState(); _refresh(); }

  Future<void> _refresh([Future<void> Function()? action]) async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      if (action != null) await action();
      final jobs = await widget.service.jobs();
      if (mounted) setState(() => _jobs = jobs);
    } catch (error) {
      if (mounted) setState(() => _error = error is StateError ? error.message.toString() : 'Companion unavailable. The host retains submitted jobs.');
    } finally { if (mounted) setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Companion jobs'),
    content: SizedBox(width: 650, height: 450, child: ListView(children: [
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      const Text('The host keeps uploaded media until you delete its job. Resume after a host restart is explicit. '
          'Pause/cancel terminates the worker; resume reruns that job.'),
      for (final job in _jobs) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${job['task']} · ${job['state']}', style: Theme.of(context).textTheme.titleMedium),
          if (job['phase'] is String) Text(job['phase'] as String),
          if (job['error'] is String) Text((job['error'] as String).replaceAll('_', ' ')),
          LinearProgressIndicator(value: (job['progress'] is num ? (job['progress'] as num).toDouble() : 0).clamp(0.0, 1.0).toDouble()),
          if (job['identity'] != widget.identityKey) const Text('Open the original media item to review this result.'),
          Wrap(spacing: 8, children: [
            if (const {'running', 'queued'}.contains(job['state']))
              TextButton(onPressed: _loading ? null : () => _refresh(() => widget.service.pause(job['id'] as String)), child: const Text('Pause')),
            if (const {'ready', 'paused', 'failed'}.contains(job['state']))
              TextButton(onPressed: _loading ? null : () => _refresh(() => widget.service.resume(job['id'] as String)), child: const Text('Resume')),
            if (!const {'completed', 'cancelled'}.contains(job['state']))
              TextButton(onPressed: _loading ? null : () => _refresh(() => widget.service.cancel(job['id'] as String)), child: const Text('Cancel')),
            if (job['state'] == 'completed' && job['identity'] == widget.identityKey)
              TextButton(onPressed: _loading ? null : () => Navigator.pop(context, job), child: const Text('Review result')),
            if (!const {'running', 'queued', 'uploading'}.contains(job['state']))
              TextButton(onPressed: _loading ? null : () => _refresh(() => widget.service.delete(job['id'] as String)), child: const Text('Delete media and result')),
          ]),
        ],
      ))),
    ])),
    actions: [
      TextButton(onPressed: _loading ? null : () => _refresh(), child: const Text('Refresh')),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
    ],
  );
}
