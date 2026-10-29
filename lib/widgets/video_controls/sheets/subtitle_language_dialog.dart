import 'package:flutter/material.dart';

import '../../../services/subtitle_language_text.dart';

Future<void> tagSubtitleSelection(BuildContext context, TextEditingController cue) async {
  final original = cue.text, selection = cue.selection;
  final boundaries = <int>{0};
  var offset = 0;
  for (final cluster in original.characters) { offset += cluster.length; boundaries.add(offset); }
  if (!selection.isValid || selection.isCollapsed || !boundaries.contains(selection.start) || !boundaries.contains(selection.end)) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select the words in the cue text first.')));
    return;
  }
  final language = TextEditingController();
  String? error;
  try {
    final result = await showDialog<String>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: const Text('Language of selected words'),
        content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(original.substring(selection.start, selection.end)),
          TextField(controller: language, maxLength: 24,
            decoration: const InputDecoration(labelText: 'Language code', hintText: 'en, ja, ar, zh-Hant-TW')),
          const Text('This is your language annotation, not automatic recognition. It does not change the track language. '
            'Horizontal app captions use it for glyph locale and accessibility. JSON revisions and WebVTT sharing retain it; '
            'SRT/native snapshots flatten it. Ruby readings and vertical span shaping are not combined with these labels.'),
          const Text('The helper accepts plain text. For additional spans or existing markup, edit balanced '
            '<lang code>words</lang> tags directly in the cue editor.'),
          if (error != null) Semantics(liveRegion: true, child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            try { Navigator.pop(context, SubtitleLanguageText.annotate(original, selection.start, selection.end, language.text)); }
            on FormatException catch (e) { update(() => error = e.message); }
          }, child: const Text('Add language annotation'))],
      )));
    if (result != null && context.mounted && cue.text == original) {
      cue.value = TextEditingValue(text: result, selection: TextSelection.collapsed(offset: result.length));
    }
  } finally { language.dispose(); }
}
