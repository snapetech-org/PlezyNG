import 'package:flutter/material.dart';

import '../../../mpv/mpv.dart';
import '../../../services/subtitle_manual_live_clock.dart';

Future<SubtitleManualLiveClock?> showSubtitleLiveClockAnchor(BuildContext context, Player player,
    bool Function() isCurrent) async {
  if (player.state.playing || !isCurrent()) {
    throw StateError('Pause a live frame with a known UTC program timestamp before starting source analysis.');
  }
  final position = player.currentPosition.inMilliseconds;
  final input = TextEditingController();
  String? error;
  try {
    return await showDialog<SubtitleManualLiveClock>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: const Text('Anchor this live frame to UTC'),
        content: SizedBox(width: 540, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('This standalone source exposes no automatic program clock. Enter the actual UTC program '
            'timestamp of the currently paused frame. Use a timestamp supplied by the program or another known reference. '
            'The current wall clock and the playlist edge do not identify this frame.'),
          const SizedBox(height: 12),
          Text('Paused player position: ${position} ms'),
          TextField(controller: input, maxLength: 32, decoration: const InputDecoration(
            labelText: 'UTC program timestamp', hintText: '2026-10-29T12:34:56.000Z')),
          const Text('This estimated mapping expires after 15 minutes and is invalidated by a seek, source change, '
            'timeline offset change or detected clock jump. Caption timing follows your anchor. '
            'No DVR bounds or automatic delay hold are inferred. Resume playback after starting analysis.'),
          if (error != null) Semantics(liveRegion: true, child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            try {
              final text = input.text.trim();
              final utc = DateTime.tryParse(text);
              if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$').hasMatch(text) || utc == null ||
                  // DateTime.parse normalizes invalid calendar days; reject
                  // normalization rather than silently anchoring another date.
                  utc.toIso8601String().substring(0, 19) != text.substring(0, 19)) {
                throw const FormatException('Use an actual UTC date and time ending in Z.');
              }
              final clock = SubtitleManualLiveClock.anchor(player, utc, pausedPositionMs: position, isCurrent: isCurrent);
              Navigator.pop(context, clock);
            } catch (e) { update(() => error = e is FormatException ? e.message : 'Playback changed. Pause the frame and reopen this dialog.'); }
          }, child: const Text('Use this program-time anchor'))],
      )));
  } finally { input.dispose(); }
}
