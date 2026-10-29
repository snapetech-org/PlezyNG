import 'package:flutter/material.dart';
import '../../../services/subtitle_retimer.dart';

/// Explicit segmentation only. The host must still measure every boundary.
Future<Map<String, List<String>>?> showSubtitleLyricUnits(BuildContext context,
    List<SubtitleCue> cues, Map<String, List<String>> previous) async {
  if (cues.isEmpty || cues.length > 120) throw const FormatException('Syllable editing requires 1–120 lyric cues.');
  String plain(String text) => text
    .replaceAll(RegExp(r'<(?:rt|rp)\s*>[\s\S]*?</(?:rt|rp)\s*>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<[^>]{0,160}>|\{[^}]{0,160}\}'), '').replaceAll(r'\N', ' ').trim();
  final sources = {for (final cue in cues) cue.stableId: plain(cue.text)};
  final controllers = {for (final cue in cues) cue.stableId: TextEditingController(
    text: previous[cue.stableId]?.join('|') ?? sources[cue.stableId])};
  String? error;
  try {
    return await showDialog<Map<String, List<String>>>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: const Text('Supply sung syllable groups'),
        content: SizedBox(width: 700, height: (MediaQuery.sizeOf(context).height * .6).clamp(180.0, 600.0).toDouble(),
          child: Column(children: [
            const Text('Insert | between the groups you want timed, for example Hel|lo world. Keep every original character, '
              'space and punctuation mark. Unchanged lines keep word timing. The host proposes a group only when its characters align in both audio views.'),
            Expanded(child: ListView.builder(itemCount: cues.length, itemBuilder: (context, index) {
              final cue = cues[index], source = sources[cue.stableId]!;
              return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: TextField(
                controller: controllers[cue.stableId], minLines: 1, maxLines: 4, maxLength: 4127,
                enabled: !source.contains('|'),
                decoration: InputDecoration(labelText: 'Cue ${cue.index}',
                  helperText: source.contains('|') ? 'This line already contains | and keeps word timing.' : null)));
            })),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            final result = <String, List<String>>{};
            var total = 0;
            for (final cue in cues) {
              final source = sources[cue.stableId]!;
              if (source.contains('|')) continue;
              if (controllers[cue.stableId]!.text == source) continue;
              final parts = controllers[cue.stableId]!.text.split('|');
              if (parts.join() != source || parts.length > 128 || parts.any((part) =>
                  !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(part))) {
                update(() => error = 'Cue ${cue.index}: preserve the exact text and put letters or numbers in each group (up to 128).');
                return;
              }
              if (parts.length > 1) { result[cue.stableId] = parts; total += parts.length; }
            }
            if (total > 4096) { update(() => error = 'Use at most 4096 syllable groups per job.'); return; }
            Navigator.pop(context, result);
          }, child: const Text('Use these groups'))],
      )));
  } finally { for (final controller in controllers.values) { controller.dispose(); } }
}
