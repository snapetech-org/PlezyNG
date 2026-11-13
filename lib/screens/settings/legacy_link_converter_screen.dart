import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/deep_links/legacy_link_converter.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/settings_page.dart';

class LegacyLinkConverterScreen extends StatefulWidget {
  const LegacyLinkConverterScreen({super.key});

  @override
  State<LegacyLinkConverterScreen> createState() => _LegacyLinkConverterScreenState();
}

class _LegacyLinkConverterScreenState extends State<LegacyLinkConverterScreen> {
  final _inputController = TextEditingController();
  LegacyLinkConversionResult? _preview;
  String? _message;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _inputChanged(String _) {
    setState(() {
      _preview = null;
      _message = null;
    });
  }

  Future<void> _paste() async {
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _message = t.deepLinks.legacyConverterClipboardUnavailable;
      });
      return;
    }
    if (!mounted) return;
    final pasted = data?.text;
    if (pasted == null || pasted.trim().isEmpty) {
      setState(() {
        _preview = null;
        _message = t.deepLinks.invalid;
      });
      return;
    }

    _inputController.value = TextEditingValue(
      text: pasted,
      selection: TextSelection.collapsed(offset: pasted.length),
    );
    setState(() {
      _preview = null;
      _message = null;
    });
  }

  void _makePreview() {
    final result = previewLegacyLink(_inputController.text);
    setState(() {
      _preview = result.isSuccess ? result : null;
      _message = switch (result.error) {
        null => null,
        LegacyLinkConversionError.empty || LegacyLinkConversionError.invalidUri => t.deepLinks.invalid,
        LegacyLinkConversionError.unsupportedScheme => t.deepLinks.legacyConverterUnsupportedScheme,
        LegacyLinkConversionError.unsupportedRoute => t.deepLinks.legacyConverterUnsupportedRoute,
      };
    });
  }

  Future<void> _copyPreview() async {
    final output = _preview?.output;
    if (output == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: output));
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = t.deepLinks.legacyConverterClipboardUnavailable);
      return;
    }
    if (!mounted) return;
    showSuccessSnackBar(context, t.deepLinks.copied);
  }

  @override
  Widget build(BuildContext context) {
    final result = _preview;
    final error = _message;
    final theme = Theme.of(context);
    return SettingsPage(
      title: Text(t.deepLinks.legacyConverterTitle),
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.deepLinks.legacyConverterDescription, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 24),
              TextField(
                key: const ValueKey('legacy-link-converter-input'),
                controller: _inputController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(labelText: t.deepLinks.dialogTitle),
                onChanged: _inputChanged,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('legacy-link-converter-paste'),
                    onPressed: _paste,
                    icon: const AppIcon(Symbols.content_paste_rounded),
                    label: Text(t.watchTogether.paste),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('legacy-link-converter-preview'),
                    onPressed: _makePreview,
                    icon: const AppIcon(Symbols.visibility_rounded),
                    label: Text(t.common.preview),
                  ),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(
                  error,
                  key: const ValueKey('legacy-link-converter-message'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (result?.output case final output?) ...[
                const SizedBox(height: 24),
                Text(t.common.preview, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: SelectableText(
                        output,
                        key: const ValueKey('legacy-link-converter-output'),
                        style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton.icon(
                    key: const ValueKey('legacy-link-converter-copy'),
                    onPressed: _copyPreview,
                    icon: const AppIcon(Symbols.content_copy_rounded),
                    label: Text(t.deepLinks.copy),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
