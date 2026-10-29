import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/subtitle_language_text.dart';

Future<void> tagSubtitleSelection(BuildContext context, TextEditingController cue) async {
  final t = Translations.of(context);
  final original = cue.text, selection = cue.selection;
  final boundaries = <int>{0};
  var offset = 0;
  for (final cluster in original.characters) { offset += cluster.length; boundaries.add(offset); }
  if (!selection.isValid || selection.isCollapsed || !boundaries.contains(selection.start) || !boundaries.contains(selection.end)) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.videoControls.subtitleLanguageSelectFirst)));
    return;
  }
  final language = TextEditingController();
  String? error;
  try {
    final result = await showDialog<String>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text(t.videoControls.subtitleLanguageDialogTitle),
        content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(original.substring(selection.start, selection.end)),
          TextField(controller: language, maxLength: 24,
            decoration: InputDecoration(labelText: t.videoControls.subtitleLanguageCodeLabel,
              hintText: t.videoControls.subtitleLanguageCodeHint)),
          Text(t.videoControls.subtitleLanguageDescription),
          Text(t.videoControls.subtitleLanguageMarkupHelp),
          if (error != null) Semantics(liveRegion: true, child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          FilledButton(onPressed: () {
            try { Navigator.pop(context, SubtitleLanguageText.annotate(original, selection.start, selection.end, language.text)); }
            on SubtitleLanguageTextException catch (e) {
              final message = switch (e.issue) {
                SubtitleLanguageTextIssue.invalidSelection => t.videoControls.subtitleLanguageSelectFirst,
                SubtitleLanguageTextIssue.invalidCode => t.videoControls.subtitleLanguageInvalidCode,
                SubtitleLanguageTextIssue.markupNotAllowed => t.videoControls.subtitleLanguagePlainTextOnly,
                SubtitleLanguageTextIssue.incompleteCharacter => t.videoControls.subtitleLanguageCompleteCharacters,
                SubtitleLanguageTextIssue.cueLimit => t.videoControls.subtitleLanguageCueLimit,
              };
              update(() => error = message);
            }
          }, child: Text(t.videoControls.subtitleLanguageAddAction))],
      )));
    if (result != null && context.mounted && cue.text == original) {
      cue.value = TextEditingValue(text: result, selection: TextSelection.collapsed(offset: result.length));
    }
  } finally { language.dispose(); }
}
