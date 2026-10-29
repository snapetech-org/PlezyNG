import 'package:flutter/material.dart';

import '../../../mpv/mpv.dart';
import '../../../services/subtitle_hdr_service.dart';

Future<void> showSubtitleHdrControls(BuildContext context, Player player, bool Function() isCurrent) async {
  SubtitleHdrSession? session;
  try {
    session = await SubtitleHdrSession.open(player, isCurrent);
    if (!context.mounted) return;
    await showDialog<void>(context: context, barrierDismissible: false,
      builder: (_) => _SubtitleHdrDialog(session: session!));
  } catch (error) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
      error is StateError ? error.message.toString() : 'Could not read native HDR caption controls.')));
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
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await widget.session.apply(channel, preset ?? _inputs[channel]!.text, restore: restore);
      if (mounted) _inputs[channel]!.text = widget.session.value(channel);
    } catch (error) {
      if (mounted) _error = error is StateError ? error.message.toString()
          : error is FormatException ? error.message : 'MPV rejected the change. Reopen to check its current value.';
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) => PopScope(canPop: !_busy, child: AlertDialog(
    title: const Text('Native HDR caption brightness'),
    content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('These controls set diffuse-white luminance for the active MPV gpu-next renderer. '
          'Their visible effect depends on the output, tone mapping and display. Values are not a display measurement. '
          'Text brightness also changes native on-screen messages (OSD). App caption overlays keep their SDR colors.'),
        const SizedBox(height: 12),
        const Text('Changes stay with this player until it closes. Restore returns one option to its value when this dialog opened. '
          'Each change is read back from MPV before it is reported as accepted.'),
        for (final channel in widget.session.channels) ...[
          const Divider(),
          Text(channel == SubtitleHdrChannel.text ? 'Native text subtitles and OSD' : 'Native bitmap subtitles',
            style: Theme.of(context).textTheme.titleMedium),
          Text('Current: ${widget.session.value(channel)} · Opening value: ${widget.session.original(channel)}'),
          TextField(controller: _inputs[channel], enabled: !_busy, maxLength: 32,
            decoration: const InputDecoration(labelText: 'Diffuse white (10–10000 nits)',
              helperText: 'Enter a numeric luminance, or use a preset below.'),
            onSubmitted: (_) => _apply(channel)),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _busy ? null : () => _apply(channel), child: const Text('Apply')),
            TextButton(onPressed: _busy ? null : () => _apply(channel, preset: 'sdr'), child: const Text('SDR reference (203 nits)')),
            if (channel == SubtitleHdrChannel.bitmap)
              TextButton(onPressed: _busy ? null : () => _apply(channel, preset: 'video'), child: const Text('Use video metadata')),
            TextButton(onPressed: _busy ? null : () => _apply(channel, restore: true), child: const Text('Restore opening value')),
          ]),
        ],
        if (_error != null) Semantics(liveRegion: true, child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ]))),
    actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Close'))],
  ));
}
