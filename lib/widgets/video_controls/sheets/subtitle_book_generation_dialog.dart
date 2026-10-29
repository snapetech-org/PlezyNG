import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../profiles/active_profile_provider.dart';
import '../../../services/subtitle_ai_service.dart';
import '../../../services/subtitle_book_generation.dart';
import '../../../services/subtitle_book_timeline.dart';
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
      if (mounted) _error = 'This action could not finish. Confirm the source, file durations, available job slots and storage, then retry.';
    } finally { if (mounted) setState(() => _working = false); }
  }

  Future<void> _review(int index) => _action(() async {
    final revision = await _service.result(index);
    if (!mounted || !_current) return;
    if (revision == null) {
      await showDialog<void>(context: context, builder: (context) => AlertDialog(
        title: const Text('No recognized cues'),
        content: const Text('Every window was processed without producing a cue. This does not prove there was no speech.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]));
      return;
    }
    final part = widget.timeline.parts[index];
    // Reject damaged or mismatched file clocks before displaying/accepting.
    widget.timeline.useRevision(part, revision, bookClock: false);
    var confirmed = false;
    final accept = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text('Review ${part.title}'),
        content: SizedBox(width: 700, height: (MediaQuery.sizeOf(context).height - 180).clamp(240.0, 620.0).toDouble(),
          child: CustomScrollView(slivers: [SliverToBoxAdapter(child: Column(children: [
            const Text('Generated text is unreviewed. Times below are local to this file. '
                'Saving adds a separate revision; it does not select or attach captions. '
                'You can edit the saved revision through the file’s subtitle history.'),
            CheckboxListTile(value: confirmed, title: const Text('I reviewed the text and confirmed this narration, file and clock'),
              onChanged: (value) => update(() => confirmed = value == true)),
          ])), SliverList(delegate: SliverChildBuilderDelegate((context, cueIndex) {
            final cue = revision.cues[cueIndex];
            return ListTile(title: SelectableText(cue.text),
              subtitle: Text('${Duration(milliseconds: cue.startMs)} – ${Duration(milliseconds: cue.endMs)}'));
          }, childCount: revision.cues.length))])),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
          FilledButton(onPressed: confirmed && _current ? () => Navigator.pop(context, true) : null,
            child: const Text('Save accepted revision'))],
      )));
    if (accept != true || !_current) return;
    await SubtitleRevisionService.saveRevision(identity: part.identity, operation: 'Book transcription',
      languageCode: revision.languageCode, cues: revision.cues, wordTimings: revision.wordTimings);
  });

  Future<void> _delete() => _action(() async {
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Delete this generation batch?'),
      content: const Text('This removes unaccepted batch results and its active file job. Accepted revisions remain in file history.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete batch'))]));
    if (accepted == true && _current) await _service.delete();
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _service, builder: (context, _) {
    final current = _current, enabled = _ready && !_working && current;
    final existing = _service.hasStoredBatch;
    return PopScope(canPop: !_working, child: AlertDialog(title: const Text('Generate the whole book'),
      content: SizedBox(width: 740, height: (MediaQuery.sizeOf(context).height - 180).clamp(300.0, 680.0).toDouble(),
        child: CustomScrollView(slivers: [SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Process each file in this book through its source transport, one file at a time. '
              'Playback is unchanged. This uses bandwidth and may download the speech model on first use. '
              'Choose the file-order audio stream for every file; matching stream numbers do not prove the same language. '
              'The batch continues with the book open while the app stays in the foreground, even after this dialog closes. '
              'Completed files and window checkpoints survive restarts; resume is explicit.'),
          if (!current) const Text('The book changed. Reopen its transcript tools.'),
          if (!_ready) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_service.message != null) Semantics(liveRegion: true, child: Text(_service.message!)),
          if (existing) ...[
            Text('${_service.completedFiles}/${widget.timeline.parts.length} files saved'),
            if (_service.activeJob case final job?) ...[
              LinearProgressIndicator(value: job.progress),
              Text('${job.completedChunks}/${job.chunkCount} windows · ${job.message ?? job.state.name}'),
            ],
          ] else ...[
            DropdownButtonFormField<SubtitleInferenceProvider>(initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Local speech provider'),
              items: [for (final provider in SubtitleAiService.availableProviderRequests)
                DropdownMenuItem(value: provider, child: Text(provider.displayName))],
              onChanged: !enabled ? null : (value) => setState(() => _provider = value ?? _provider)),
            TextField(controller: _language, maxLength: 3,
              decoration: const InputDecoration(labelText: 'Spoken language (two/three-letter code; blank for automatic)'),
              enabled: enabled),
            SwitchListTile(title: const Text('Only on external power'), value: _charging,
              onChanged: !enabled ? null : (value) => setState(() => _charging = value)),
            SwitchListTile(title: const Text('Only while playback is idle'), value: _idle,
              onChanged: !enabled ? null : (value) => setState(() => _idle = value)),
            CheckboxListTile(value: _confirmed, title: const Text('I confirmed every file’s audio stream and want local generation'),
              onChanged: !enabled ? null : (value) => setState(() => _confirmed = value == true)),
          ],
          const Text('Limits: 256 files, eight hours per file, seven days per book; four retained batches and 64 MiB per batch. '
              'A batch uses one slot in the twelve-job queue. Runtime and recognition quality remain unqualified.'),
        ])), SliverList(delegate: SliverChildBuilderDelegate((context, index) {
          final part = widget.timeline.parts[index];
          return ListTile(title: Text(part.title), subtitle: Text('${Duration(milliseconds: part.durationMs)}'),
            trailing: existing ? (_service.completedIndices.contains(index)
              ? TextButton(onPressed: enabled ? () => _review(index) : null, child: const Text('Review')) : const Text('Pending'))
              : SizedBox(width: 85, child: TextFormField(initialValue: '${_ordinals[index]}', enabled: enabled,
                  keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Audio 0–63'),
                  onChanged: (value) { _ordinals[index] = int.tryParse(value) ?? -1; _confirmed = false; setState(() {}); })));
        }, childCount: widget.timeline.parts.length))])),
      actions: [
        if (existing) ...[
          TextButton(onPressed: enabled && !_service.busy ? _delete : null, child: const Text('Delete batch')),
          if (!_service.complete) FilledButton(onPressed: !enabled || _service.busy ? null
              : () => _action(_service.running ? _service.pause : _service.resume),
            child: Text(_service.running ? 'Pause' : 'Resume')),
        ] else FilledButton(onPressed: !enabled || !_confirmed ? null : () => _action(() async {
          final language = _language.text.trim().toLowerCase();
          await _service.create(ordinals: _ordinals, provider: _provider, language: language.isEmpty ? null : language,
            chargingOnly: _charging, idleOnly: _idle);
        }), child: const Text('Start generation')),
        TextButton(onPressed: _working ? null : () => Navigator.pop(context), child: const Text('Close')),
      ],
    ));
  });
}
