import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/subtitle_overlay_service.dart';
import '../../sources/source_controller.dart';
import '../../sources/sync/sync_document.dart';
import '../providers/watch_together_provider.dart';

class WatchSubtitleDialog extends StatefulWidget {
  const WatchSubtitleDialog({super.key, required this.room});
  final WatchTogetherProvider room;
  @override
  State<WatchSubtitleDialog> createState() => _WatchSubtitleDialogState();
}

class _WatchSubtitleDialogState extends State<WatchSubtitleDialog> {
  final _code = TextEditingController();
  bool _confirmedEdition = false, _automatic = false, _starting = false, _reveal = false;
  int _lane = 0;
  String? _error;
  @override
  void dispose() { _code.dispose(); super.dispose(); }

  Future<void> _start() async {
    setState(() { _starting = true; _error = null; });
    try {
      if (!_confirmedEdition) throw StateError('Confirm the same cut, part and audio before starting');
      await widget.room.captionSync.start(sources: context.read<SourceController>(),
        context: () => widget.room.captionContext, code: _code.text.trim(), lane: _lane,
        publish: widget.room.isHost, automatic: _automatic);
    } catch (error) {
      if (mounted) setState(() => _error = error is StateError ? error.message.toString()
          : 'Could not start caption sharing. Check the pairing code and shared cloud folder.');
    } finally { if (mounted) setState(() => _starting = false); }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: widget.room.captionSync, builder: (context, _) {
    final sync = widget.room.captionSync;
    final blocked = _starting || sync.busy;
    return AlertDialog(title: const Text('Watch Together captions'), content: SizedBox(width: 620,
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min, children: [
          const Text('Use the same caption code and shared cloud folder on participating devices. '
            'The host publishes a reviewed app lane; viewers can preview or opt into automatic display. '
            'The code grants read and write access to the encrypted captions. It does not authenticate a sender. '
            'Video, account credentials, fonts and appearance are not shared.'),
          const SizedBox(height: 12),
          TextField(controller: _code, enabled: !sync.running && !blocked, obscureText: !_reveal,
            autocorrect: false, enableSuggestions: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: 'Caption pairing code', suffixIcon: IconButton(
              tooltip: _reveal ? 'Hide caption code' : 'Show caption code',
              onPressed: () => setState(() => _reveal = !_reveal), icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility)))),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: sync.running || blocked ? null : () => setState(() => _code.text = SyncCipher.newCode()),
              child: const Text('New caption code')),
            TextButton(onPressed: _code.text.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: _code.text.trim())),
              child: const Text('Copy caption code')),
          ]),
          DropdownButton<int>(value: _lane, isExpanded: true, items: const [
            DropdownMenuItem(value: 0, child: Text('Primary app lane')),
            DropdownMenuItem(value: 1, child: Text('Secondary app lane')),
          ], onChanged: sync.running || blocked ? null : (value) { if (value != null) setState(() => _lane = value); }),
          CheckboxListTile(value: _confirmedEdition, onChanged: sync.running || blocked ? null
            : (value) => setState(() => _confirmedEdition = value == true),
            title: const Text('We checked the cut, part and audio language'),
            subtitle: const Text('Matching titles or durations alone do not prove identical dialogue. Room offsets are applied once.')),
          if (!widget.room.isHost) SwitchListTile(value: _automatic, onChanged: sync.running || blocked ? null
            : (value) => setState(() => _automatic = value), title: const Text('Automatically display one unambiguous shared revision'),
            subtitle: const Text('Replaces the chosen app lane while connected. Conflicts wait for your choice. Native tracks remain under your control.')),
          const Text('Sharing stops on room/copy/audio/part/offset changes, disconnect, backgrounding or a local lane replacement. '
            'Cloud revisions remain in the shared folder after stopping. Polling starts at 30 seconds and backs off after failures.'),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Text(sync.status),
          if (blocked) const LinearProgressIndicator(),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: blocked || sync.running || !_confirmedEdition ? null : _start,
              child: Text(widget.room.isHost ? 'Share reviewed lane for this room' : 'Receive captions for this room')),
            TextButton(onPressed: sync.running ? () => sync.stop() : null, child: const Text('Stop sharing')),
          ]),
          if (!sync.publishing) for (final choice in sync.choices) Card(child: Padding(padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${choice.digest.substring(0, 12)} · ${(choice.bytes / 1024).ceil()} KiB'),
              if (sync.previews[choice.digest] case final revision?) ...[
                Text('${revision.languageCode ?? 'Unknown language'} · ${revision.cues.length} cues'),
                SizedBox(height: 180, child: ListView.builder(itemCount: revision.cues.length, itemBuilder: (_, index) {
                  final cue = revision.cues[index];
                  return Text('${cue.startMs / 1000}–${cue.endMs / 1000}s  ${SubtitleOverlayTrack.plain(cue.text)}');
                })),
              ],
              Wrap(spacing: 8, children: [
                TextButton(onPressed: blocked ? null : () async {
                  try { await sync.preview(choice); }
                  catch (_) { if (mounted) setState(() => _error = 'Could not download this caption revision.'); }
                }, child: const Text('Download and preview')),
                TextButton(onPressed: blocked || !sync.previews.containsKey(choice.digest) ? null : () {
                  try { sync.accept(choice); }
                  catch (_) { if (mounted) setState(() => _error = 'The room or caption revision changed.'); }
                }, child: const Text('Use this revision locally')),
              ]),
            ]))),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]);
  });
}
