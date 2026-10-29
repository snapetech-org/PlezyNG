import 'package:flutter/material.dart';
import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_retimer.dart';

/// Explicit segmentation only. The host must still measure every boundary.
Future<Map<String, List<String>>?> showSubtitleLyricUnits(BuildContext context,
    List<SubtitleCue> cues, Map<String, List<String>> previous) async {
  final t = Translations.of(context);
  final copy = t.videoControls.subtitleLyrics;
  if (cues.isEmpty || cues.length > 120) throw FormatException(copy.cueLimit);
  String plain(String text) => text
    .replaceAll(RegExp(r'<(?:rt|rp)\s*>[\s\S]*?</(?:rt|rp)\s*>', caseSensitive: false), '')
    .replaceAll(RegExp(r'<[^>]{0,160}>|\{[^}]{0,160}\}'), '').replaceAll(r'\N', ' ').trim();
  final sources = {for (final cue in cues) cue.stableId: plain(cue.text)};
  final controllers = {for (final cue in cues) cue.stableId: TextEditingController(
    text: previous[cue.stableId]?.join('|') ?? sources[cue.stableId])};
  String? error;
  try {
    return await showDialog<Map<String, List<String>>>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text(copy.title),
        content: SizedBox(width: 700, height: (MediaQuery.sizeOf(context).height * .6).clamp(180.0, 600.0).toDouble(),
          child: Column(children: [
            Text(copy.description),
            Expanded(child: ListView.builder(itemCount: cues.length, itemBuilder: (context, index) {
              final cue = cues[index], source = sources[cue.stableId]!;
              return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: TextField(
                controller: controllers[cue.stableId], minLines: 1, maxLines: 4, maxLength: 4127,
                enabled: !source.contains('|'),
                decoration: InputDecoration(labelText: copy.cueLabel(cue: cue.index),
                  helperText: source.contains('|') ? copy.delimiterPresent : null)));
            })),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
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
                update(() => error = copy.invalidCue(cue: cue.index));
                return;
              }
              if (parts.length > 1) { result[cue.stableId] = parts; total += parts.length; }
            }
            if (total > 4096) { update(() => error = copy.groupLimit); return; }
            Navigator.pop(context, result);
          }, child: Text(copy.useGroups))],
      )));
  } finally { for (final controller in controllers.values) { controller.dispose(); } }
}
