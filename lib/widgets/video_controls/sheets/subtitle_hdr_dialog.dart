import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../mpv/mpv.dart';
import '../../../services/subtitle_hdr_service.dart';

Future<void> showSubtitleHdrControls(BuildContext context, Player player, bool Function() isCurrent) async {
  final labels = t.videoControls.subtitleHdr;
  SubtitleHdrSession? session;
  try {
    session = await SubtitleHdrSession.open(player, isCurrent);
    if (!context.mounted) return;
    await showDialog<void>(context: context, barrierDismissible: false,
      builder: (_) => _SubtitleHdrDialog(session: session!));
  } catch (error) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
      error is StateError ? error.message.toString() : labels.readFailed)));
  } finally { session?.close(); }
}

class _SubtitleHdrDialog extends StatefulWidget {
  const _SubtitleHdrDialog({required this.session});
  final SubtitleHdrSession session;
  @override
  State<_SubtitleHdrDialog> createState() => _SubtitleHdrDialogState();
}

class _SubtitleHdrDialogState extends State<_SubtitleHdrDialog> {
  final Map<SubtitleHdrChannel, TextEditingController> _inputs = {};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final channel in widget.session.channels) {
      _inputs[channel] = TextEditingController(text: widget.session.value(channel));
    }
  }

  @override
  void dispose() {
    for (final input in _inputs.values) { input.dispose(); }
    super.dispose();
  }

  Future<void> _apply(SubtitleHdrChannel channel, {String? preset, bool restore = false}) async {
    final labels = t.videoControls.subtitleHdr;
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await widget.session.apply(channel, preset ?? _inputs[channel]!.text, restore: restore);
      if (mounted) _inputs[channel]!.text = widget.session.value(channel);
    } catch (error) {
      if (mounted) _error = error is StateError ? error.message.toString()
          : error is FormatException ? error.message : labels.rejected;
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final labels = t.videoControls.subtitleHdr;
    return PopScope(canPop: !_busy, child: AlertDialog(
    title: Text(labels.title),
    content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(labels.description),
        const SizedBox(height: 12),
        Text(labels.lifetime),
        for (final channel in widget.session.channels) ...[
          const Divider(),
          Text(channel == SubtitleHdrChannel.text ? labels.textChannel : labels.bitmapChannel,
            style: Theme.of(context).textTheme.titleMedium),
          Text(labels.currentAndOpening(current: widget.session.value(channel), opening: widget.session.original(channel))),
          TextField(controller: _inputs[channel], enabled: !_busy, maxLength: 32,
            decoration: InputDecoration(labelText: labels.luminanceLabel, helperText: labels.luminanceHint),
            onSubmitted: (_) => _apply(channel)),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _busy ? null : () => _apply(channel), child: Text(labels.apply)),
            TextButton(onPressed: _busy ? null : () => _apply(channel, preset: 'sdr'), child: Text(labels.sdrReference)),
            if (channel == SubtitleHdrChannel.bitmap)
              TextButton(onPressed: _busy ? null : () => _apply(channel, preset: 'video'), child: Text(labels.useVideoMetadata)),
            TextButton(onPressed: _busy ? null : () => _apply(channel, restore: true), child: Text(labels.restoreOpening)),
          ]),
        ],
        if (_error != null) Semantics(liveRegion: true, child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ]))),
    actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(labels.close))],
  ));
  }
}
