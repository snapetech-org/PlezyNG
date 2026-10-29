import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
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
    if (invite != null && !invite.expired) {
      _companion = true; _code.text = invite.encode(); _lane = sync.lane;
      _automatic = sync.automatic; _confirmedEdition = sync.running;
    }
  }
  @override
  void dispose() { _code.dispose(); super.dispose(); }

  Future<void> _start() async {
    final captions = t.watchTogether.captions;
    setState(() { _starting = true; _error = null; });
    try {
      if (!_confirmedEdition) throw StateError(captions.confirmEditionRequired);
      final relay = _companion ? SubtitleCaptionRelayInvite.decode(_code.text.trim()) : null;
      await widget.room.captionSync.start(sources: context.read<SourceController>(),
        context: () => widget.room.captionContext, code: _code.text.trim(), lane: _lane,
        publish: widget.room.isHost, automatic: _automatic, relay: relay);
    } catch (error) {
      final message = error is StateError ? error.message.toString() : null;
      if (mounted) setState(() => _error = message != null && {
        captions.confirmEditionRequired,
        captions.joinPlaybackFirst,
        captions.activeProfileChanged,
        captions.chooseTransport,
        captions.codeWrongRoom,
        captions.roomSessionChanged,
        captions.cloudNotSupported,
      }.contains(message) ? message : error is FormatException ? captions.invalidCaptionCode : captions.couldNotStart);
    } finally { if (mounted) setState(() => _starting = false); }
  }

  Future<void> _channel({bool revoke = false}) async {
    final captions = t.watchTogether.captions;
    setState(() { _starting = true; _error = null; });
    SubtitleCompanionService? service;
    try {
      final sync = widget.room.captionSync, initial = widget.room.captionContext;
      if (!revoke && (initial == null || !initial.host)) throw StateError(captions.hostRequired);
      final profileId = revoke ? sync.relayOwnerProfileId ?? initial?.profileId : initial!.profileId;
      if (profileId == null) throw StateError(captions.profileUnavailable);
      bool current() {
        if (!mounted) return false;
        final now = widget.room.captionContext;
        return revoke ? now == null || now.profileId == profileId
            : now?.localToken == initial?.localToken && widget.room.isHost;
      }
      service = await SubtitleCompanionService.load(profileId);
      if (service == null) throw StateError(captions.companionPairingRequired);
      if (!current()) throw StateError(captions.roomChanged);
      if (revoke) {
        final invite = SubtitleCaptionRelayInvite.decode(_code.text.trim());
        if (invite.endpoint != service.endpoint) throw StateError(captions.originalCompanionRequired);
        final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: Text(captions.confirmRevokeTitle),
          content: Text(captions.confirmRevokeBody),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(captions.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(captions.revoke))]));
        if (accepted != true || !current()) return;
        await service.revokeCaptionChannel(invite.channel);
        if (sync.relayChannel == invite.channel) sync.stop(reason: captions.channelRevoked);
        sync.clearRelayInvite(invite.channel);
        if (mounted) setState(() => _code.clear());
      } else {
        final invite = await SubtitleCaptionRelayInvite.create(service, initial!.scope);
        if (!current()) {
          try { await service.revokeCaptionChannel(invite.channel); } catch (_) { /* The six-hour expiry still applies. */ }
          throw StateError(captions.channelNotReady);
        }
        sync.rememberRelayInvite(invite, ownerProfileId: profileId);
        setState(() => _code.text = invite.encode());
      }
    } catch (error) {
      final message = error is StateError ? error.message.toString() : null;
      if (mounted) setState(() => _error = message != null && {
        captions.hostRequired,
        captions.profileUnavailable,
        captions.companionPairingRequired,
        captions.roomChanged,
        captions.originalCompanionRequired,
        captions.channelNotReady,
      }.contains(message) ? message : error is FormatException ? captions.invalidCompanionCode : captions.channelOperationFailed);
    } finally { service?.close(); if (mounted) setState(() => _starting = false); }
  }

  String? get _destination {
    if (!_companion || _code.text.trim().isEmpty) return null;
    final captions = t.watchTogether.captions;
    try {
      final invite = SubtitleCaptionRelayInvite.decode(_code.text.trim());
      return captions.destination(endpoint: invite.endpoint, expires: invite.expires.toUtc());
    } catch (_) { return captions.invalidCompanionCode; }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: widget.room.captionSync, builder: (context, _) {
    final sync = widget.room.captionSync;
    final captions = t.watchTogether.captions;
    final blocked = _starting || sync.busy;
    return AlertDialog(title: Text(captions.title), content: SizedBox(width: 620,
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min, children: [
          DropdownButton<bool>(value: _companion, isExpanded: true, items: [
            DropdownMenuItem(value: false, child: Text(captions.sharedFolder)),
            DropdownMenuItem(value: true, child: Text(captions.companionChannel)),
          ], onChanged: sync.running || blocked ? null : (value) {
            if (value != null) setState(() {
              _companion = value;
              final invite = value ? sync.relayInvite : null;
              _code.text = invite?.encode() ?? '';
              _confirmedEdition = false;
            });
          }),
          Text(_companion ? captions.companionDescription : captions.cloudDescription),
          const SizedBox(height: 12),
          TextField(controller: _code, enabled: !sync.running && !blocked, obscureText: !_reveal,
            autocorrect: false, enableSuggestions: false, maxLength: _companion ? 4096 : 128,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: captions.captionPairingCode, suffixIcon: IconButton(
              tooltip: _reveal ? captions.hideCaptionCode : captions.showCaptionCode,
              onPressed: () => setState(() => _reveal = !_reveal), icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility)))),
          Wrap(spacing: 8, children: [
            if (!_companion) TextButton(onPressed: sync.running || blocked ? null : () => setState(() => _code.text = SyncCipher.newCode()),
              child: Text(captions.newCaptionCode)),
            if (_companion && widget.room.isHost) ...[
              TextButton(onPressed: sync.running || blocked || _code.text.isNotEmpty ? null : () => _channel(),
                child: Text(captions.createChannel)),
            ],
            if (_companion && (widget.room.isHost || sync.relayOwnerProfileId != null)) ...[
              TextButton(onPressed: blocked || _code.text.isEmpty ? null : () => _channel(revoke: true),
                child: Text(captions.revokeChannel)),
            ],
            TextButton(onPressed: _code.text.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: _code.text.trim())),
              child: Text(captions.copyCaptionCode)),
          ]),
          if (_destination case final destination?) Text(destination),
          DropdownButton<int>(value: _lane, isExpanded: true, items: [
            DropdownMenuItem(value: 0, child: Text(captions.primaryLane)),
            DropdownMenuItem(value: 1, child: Text(captions.secondaryLane)),
          ], onChanged: sync.running || blocked ? null : (value) { if (value != null) setState(() => _lane = value); }),
          CheckboxListTile(value: _confirmedEdition, onChanged: sync.running || blocked ? null
            : (value) => setState(() => _confirmedEdition = value == true),
            title: Text(captions.confirmEditionTitle),
            subtitle: Text(captions.confirmEditionDescription)),
          if (!widget.room.isHost) SwitchListTile(value: _automatic, onChanged: sync.running || blocked ? null
            : (value) => setState(() => _automatic = value), title: Text(captions.automaticDisplay),
            subtitle: Text(captions.automaticDisplayDescription)),
          Text('${captions.sharingStops} ${_companion ? captions.channelExpires : captions.cloudPersists} ${captions.pollingDetails}'),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Text(sync.status),
          if (blocked) const LinearProgressIndicator(),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: blocked || sync.running || !_confirmedEdition ? null : _start,
              child: Text(widget.room.isHost ? captions.shareReviewedLane : captions.receiveCaptions)),
            TextButton(onPressed: sync.running ? () => sync.stop() : null, child: Text(captions.stopSharing)),
          ]),
          if (!sync.publishing) for (final choice in sync.choices) Card(child: Padding(padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${choice.digest.substring(0, 12)} · ${(choice.bytes / 1024).ceil()} KiB'),
              if (sync.previews[choice.digest] case final revision?) ...[
                Text('${revision.languageCode ?? captions.unknownLanguage} · ${captions.captionCueCount(count: revision.cues.length)}'),
                SizedBox(height: 180, child: ListView.builder(itemCount: revision.cues.length, itemBuilder: (_, index) {
                  final cue = revision.cues[index];
                  return Text(captions.captionCueSummary(start: cue.startMs / 1000, end: cue.endMs / 1000,
                    text: SubtitleOverlayTrack.plain(cue.text)));
                })),
              ],
              Wrap(spacing: 8, children: [
                TextButton(onPressed: blocked ? null : () async {
                  try { await sync.preview(choice); }
                  catch (_) { if (mounted) setState(() => _error = captions.couldNotDownload); }
                }, child: Text(captions.downloadAndPreview)),
                TextButton(onPressed: blocked || !sync.previews.containsKey(choice.digest) ? null : () {
                  try { sync.accept(choice); }
                  catch (_) { if (mounted) setState(() => _error = captions.revisionChanged); }
                }, child: Text(captions.useRevisionLocally)),
              ]),
            ]))),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(captions.close))]);
  });
}
