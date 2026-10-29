import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
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

  Translations get _t => Translations.of(context);

  String _taskLabel(String task) {
    final copy = _t.videoControls.subtitleCompanionJobs;
    return switch (task) {
      'transcribe' => copy.transcribe,
      'align' => copy.align,
      'diarize' => copy.diarize,
      'ocr' => copy.ocr,
      'bitmap_ocr' => copy.bitmapOcr,
      'translate' => copy.translate,
      'translate_model' => copy.translateModel,
      'script_convert' => copy.scriptConvert,
      'reading' => copy.reading,
      'dubbing' => copy.dubbing,
      'ensemble' => copy.ensemble,
      'separate' => copy.separate,
      'sound_events' => copy.soundEvents,
      'completeness' => copy.completeness,
      'extract_text' => copy.extractText,
      'signs' => copy.signs,
      'dub_mix' => copy.dubMix,
      'ocr_auto' => copy.ocrAuto,
      'scene_review' => copy.sceneReview,
      'singing_align' => copy.singingAlign,
      _ => task.replaceAll('_', ' '),
    };
  }

  String _stateLabel(String state) {
    final copy = _t.videoControls.subtitleCompanionJobs;
    final jobs = _t.videoControls.subtitleJobs;
    return switch (state) {
      'queued' => jobs.stateQueued,
      'running' => jobs.stateRunning,
      'paused' => jobs.statePaused,
      'completed' => jobs.stateCompleted,
      'cancelled' => jobs.stateCancelled,
      'failed' => jobs.stateFailed,
      'ready' => copy.ready,
      'awaiting_audio' => copy.awaitingAudio,
      'uploading' => copy.uploading,
      _ => state.replaceAll('_', ' '),
    };
  }

  String _jobTask(Map<String, dynamic> job) => _taskLabel(job['task'] is String ? job['task'] as String : 'unknown');

  String _jobState(Map<String, dynamic> job) => _stateLabel(job['state'] is String ? job['state'] as String : 'unknown');

  Future<void> _refresh([Future<void> Function()? action]) async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      if (action != null) await action();
      final jobs = await widget.service.jobs();
      if (mounted) setState(() => _jobs = jobs);
    } catch (_) {
      if (mounted) setState(() => _error = _t.videoControls.subtitleCompanionJobs.unavailable);
    } finally { if (mounted) setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _t.videoControls.subtitleCompanionJobs;
    final jobs = _t.videoControls.subtitleJobs;
    return AlertDialog(
    title: Text(copy.title),
    content: SizedBox(width: 650, height: 450, child: ListView(children: [
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      Text(copy.description),
      if (!_loading && _jobs.isEmpty) Text(copy.noJobs),
      for (final job in _jobs) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(copy.taskAndState(task: _jobTask(job), state: _jobState(job)),
            style: Theme.of(context).textTheme.titleMedium),
          if (job['phase'] is String) Text(copy.phase(value: job['phase'] as String)),
          if (job['error'] is String) Text(copy.jobError(code: (job['error'] as String).replaceAll('_', ' '))),
          LinearProgressIndicator(value: (job['progress'] is num ? (job['progress'] as num).toDouble() : 0).clamp(0.0, 1.0).toDouble()),
          if (job['identity'] != widget.identityKey) Text(copy.openOriginal),
          Wrap(spacing: 8, children: [
            if (const {'running', 'queued'}.contains(job['state']))
              TextButton(onPressed: _loading ? null : () => _refresh(() => widget.service.pause(job['id'] as String)), child: Text(jobs.pause)),
            if (const {'ready', 'paused', 'failed'}.contains(job['state']))
              TextButton(onPressed: _loading ? null : () => _refresh(() => widget.service.resume(job['id'] as String)), child: Text(jobs.resume)),
            if (!const {'completed', 'cancelled'}.contains(job['state']))
              TextButton(onPressed: _loading ? null : () => _refresh(() => widget.service.cancel(job['id'] as String)), child: Text(jobs.cancel)),
            if (job['state'] == 'completed' && job['identity'] == widget.identityKey)
              TextButton(onPressed: _loading ? null : () => Navigator.pop(context, job), child: Text(jobs.reviewResult)),
            if (!const {'running', 'queued', 'uploading'}.contains(job['state']))
              TextButton(onPressed: _loading ? null : () => _refresh(() => widget.service.delete(job['id'] as String)), child: Text(copy.deleteMediaAndResult)),
          ]),
        ],
      ))),
    ])),
    actions: [
      TextButton(onPressed: _loading ? null : () => _refresh(), child: Text(_t.common.refresh)),
      TextButton(onPressed: () => Navigator.pop(context), child: Text(_t.common.close)),
    ],
  );
  }
}
