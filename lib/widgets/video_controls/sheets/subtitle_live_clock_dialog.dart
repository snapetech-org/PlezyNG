import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../mpv/mpv.dart';
import '../../../services/subtitle_manual_live_clock.dart';

Future<SubtitleManualLiveClock?> showSubtitleLiveClockAnchor(BuildContext context, Player player,
    bool Function() isCurrent) async {
  final t = Translations.of(context);
  final copy = t.videoControls.subtitleLive;
  if (player.state.playing || !isCurrent()) {
    throw StateError(copy.pauseKnownUtcFrame);
  }
  final position = player.currentPosition.inMilliseconds;
  final input = TextEditingController();
  String? error;
  try {
    return await showDialog<SubtitleManualLiveClock>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text(copy.anchorTitle),
        content: SizedBox(width: 540, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(copy.anchorDescription),
          const SizedBox(height: 12),
          Text(copy.pausedPosition(milliseconds: position)),
          TextField(controller: input, maxLength: 32, decoration: InputDecoration(
            labelText: copy.utcTimestamp, hintText: copy.utcTimestampHint)),
          Text(copy.anchorExpiryHelp),
          if (error != null) Semantics(liveRegion: true, child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          FilledButton(onPressed: () {
            try {
              final text = input.text.trim();
              final utc = DateTime.tryParse(text);
              if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$').hasMatch(text) || utc == null ||
                  // DateTime.parse normalizes invalid calendar days; reject
                  // normalization rather than silently anchoring another date.
                  utc.toIso8601String().substring(0, 19) != text.substring(0, 19)) {
                throw FormatException(copy.invalidUtc);
              }
              final clock = SubtitleManualLiveClock.anchor(player, utc, pausedPositionMs: position, isCurrent: isCurrent);
              Navigator.pop(context, clock);
            } catch (e) { update(() => error = e is FormatException ? e.message : copy.playbackChanged); }
          }, child: Text(copy.useAnchor))],
      )));
  } finally { input.dispose(); }
}
