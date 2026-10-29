import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/subtitle_overlay_service.dart';
import '../../services/subtitle_caption_relay.dart';
import '../../services/subtitle_companion_service.dart';
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
  bool _companion = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final sync = widget.room.captionSync, invite = widget.room.captionSync.relayInvite;
    if (invite != null) {
      _companion = true; _code.text = invite.encode(); _lane = sync.lane;
      _automatic = sync.automatic; _confirmedEdition = sync.running;
    }
  }
  @override
  void dispose() { _code.dispose(); super.dispose(); }

  Future<void> _start() async {
    setState(() { _starting = true; _error = null; });
    try {
      if (!_confirmedEdition) throw StateError('Confirm the same cut, part and audio before starting');
      final relay = _companion ? SubtitleCaptionRelayInvite.decode(_code.text.trim()) : null;
      await widget.room.captionSync.start(sources: context.read<SourceController>(),
        context: () => widget.room.captionContext, code: _code.text.trim(), lane: _lane,
        publish: widget.room.isHost, automatic: _automatic, relay: relay);
    } catch (error) {
      if (mounted) setState(() => _error = error is StateError ? error.message.toString()
          : error is FormatException ? error.message : 'Could not start caption sharing. Check the code and selected transport.');
    } finally { if (mounted) setState(() => _starting = false); }
  }

  Future<void> _channel({bool revoke = false}) async {
    setState(() { _starting = true; _error = null; });
    SubtitleCompanionService? service;
    try {
      final initial = widget.room.captionContext;
      if (initial == null || !initial.host) throw StateError('Join room playback as host first.');
      bool current() => mounted && widget.room.captionContext?.localToken == initial.localToken && widget.room.isHost;
      service = await SubtitleCompanionService.load(initial.profileId);
      if (service == null) throw StateError('Pair your companion in Subtitle tools before creating a caption channel.');
      if (!current()) throw StateError('The room changed.');
      if (revoke) {
        final invite = SubtitleCaptionRelayInvite.decode(_code.text.trim());
        if (invite.endpoint != service.endpoint) throw StateError('Pair the original companion before revoking this channel.');
        final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: const Text('Revoke this caption channel?'),
          content: const Text('Delete its encrypted captions from the companion and disconnect participants using this code.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Revoke'))]));
        if (accepted != true || !current()) return;
        await service.revokeCaptionChannel(invite.channel);
        if (widget.room.captionSync.relayChannel == invite.channel) widget.room.captionSync.stop(reason: 'Caption channel revoked');
        if (mounted) setState(() => _code.clear());
      } else {
        final invite = await SubtitleCaptionRelayInvite.create(service, initial.scope);
        if (!current()) {
          try { await service.revokeCaptionChannel(invite.channel); } catch (_) { /* The six-hour expiry still applies. */ }
          throw StateError('The room changed before the channel was ready.');
        }
        setState(() => _code.text = invite.encode());
      }
    } catch (error) {
      if (mounted) setState(() => _error = error is StateError ? error.message.toString()
          : error is FormatException ? error.message : 'The companion channel operation failed.');
    } finally { service?.close(); if (mounted) setState(() => _starting = false); }
  }

  String? get _destination {
    if (!_companion || _code.text.trim().isEmpty) return null;
    try {
      final invite = SubtitleCaptionRelayInvite.decode(_code.text.trim());
      return 'Companion: ${invite.endpoint}\nExpires: ${invite.expires.toUtc()}';
    } catch (_) { return 'Paste a valid, unexpired companion caption code.'; }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: widget.room.captionSync, builder: (context, _) {
    final sync = widget.room.captionSync;
    final blocked = _starting || sync.busy;
    return AlertDialog(title: const Text('Watch Together captions'), content: SizedBox(width: 620,
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min, children: [
          DropdownButton<bool>(value: _companion, isExpanded: true, items: const [
            DropdownMenuItem(value: false, child: Text('Shared cloud folder')),
            DropdownMenuItem(value: true, child: Text('Expiring companion channel')),
          ], onChanged: sync.running || blocked ? null : (value) {
            if (value != null) setState(() { _companion = value; _code.clear(); _confirmedEdition = false; });
          }),
          Text(_companion ? 'The host creates a channel on its paired companion and shares the caption code explicitly. '
            'Every participant must be able to reach the displayed HTTPS host. No shared cloud folder is required. '
            'The code grants read/write access to this encrypted channel, without the companion administration token. '
            'It does not authenticate a sender. Video, account credentials, fonts and appearance are not shared.'
            : 'Use the same caption code and shared cloud folder on participating devices. '
            'The host publishes a reviewed app lane; viewers can preview or opt into automatic display. '
            'The code grants read and write access to the encrypted captions. It does not authenticate a sender. '
            'Video, account credentials, fonts and appearance are not shared.'),
          const SizedBox(height: 12),
          TextField(controller: _code, enabled: !sync.running && !blocked, obscureText: !_reveal,
            autocorrect: false, enableSuggestions: false, maxLength: _companion ? 4096 : 128,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: 'Caption pairing code', suffixIcon: IconButton(
              tooltip: _reveal ? 'Hide caption code' : 'Show caption code',
              onPressed: () => setState(() => _reveal = !_reveal), icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility)))),
          Wrap(spacing: 8, children: [
            if (!_companion) TextButton(onPressed: sync.running || blocked ? null : () => setState(() => _code.text = SyncCipher.newCode()),
              child: const Text('New caption code')),
            if (_companion && widget.room.isHost) ...[
              TextButton(onPressed: sync.running || blocked || _code.text.isNotEmpty ? null : () => _channel(),
                child: const Text('Create 6-hour channel')),
              TextButton(onPressed: blocked || _code.text.isEmpty ? null : () => _channel(revoke: true),
                child: const Text('Revoke companion channel')),
            ],
            TextButton(onPressed: _code.text.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: _code.text.trim())),
              child: const Text('Copy caption code')),
          ]),
          if (_destination case final destination?) Text(destination),
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
          Text('Sharing stops on room/copy/audio/part/offset changes, disconnect, backgrounding or a local lane replacement. '
            '${_companion ? 'Channel access expires after six hours, revocation, or server restart. Expired data is cleared from companion memory within 30 seconds.' : 'Cloud revisions remain in the shared folder after stopping.'} '
            'Polling starts at 30 seconds and backs off after failures.'),
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
