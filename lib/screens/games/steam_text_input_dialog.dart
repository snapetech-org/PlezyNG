import 'package:flutter/material.dart';
import '../../games/steam_text.dart';
import '../../i18n/strings.g.dart';
import '../../focus/focusable_text_field.dart';
import '../../widgets/dialog_action_button.dart';

/// Compose with the local OS/IME, then explicitly submit committed text. The
/// draft never enters preferences, logging, the clipboard or account services.
class SteamTextInputDialog extends StatefulWidget {
  const SteamTextInputDialog({super.key});
  @override
  State<SteamTextInputDialog> createState() => _SteamTextInputDialogState();
}

class _SteamTextInputDialogState extends State<SteamTextInputDialog> {
  final _text = TextEditingController();
  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  void _changed() => setState(() {});
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final composing = _text.value.composing.isValid && !_text.value.composing.isCollapsed;
    final valid = validSteamInputText(_text.text) && !composing;
    return AlertDialog(
      title: Text(t.games.textInput),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.games.textInputHelp),
            const SizedBox(height: 12),
            FocusableTextField(
              controller: _text,
              autofocus: true,
              maxLength: 512,
              minLines: 1,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: t.games.textInput,
                helperText: t.games.textInputLimit,
                helperMaxLines: 3,
                errorText: _text.text.isNotEmpty && !validSteamInputText(_text.text) ? t.games.textInputInvalid : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        DialogActionButton(label: t.common.cancel, onPressed: () => Navigator.pop(context)),
        DialogActionButton(label: t.games.sendText, onPressed: valid ? () => Navigator.pop(context, _text.text) : null),
      ],
    );
  }
}
