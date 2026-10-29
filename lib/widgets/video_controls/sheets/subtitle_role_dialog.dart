import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../profiles/active_profile_provider.dart';
import '../../../services/settings_service.dart';
import '../../../services/subtitle_selection_rules.dart';

Future<void> showSubtitleRoleDialog(BuildContext context, {String? titleIdentity}) async {
  final profiles = context.read<ActiveProfileProvider>(), profile = context.read<ActiveProfileProvider>().activeId;
  if (profile == null) return;
  SubtitleSelectionRules.bindProfile(profiles);
  await SettingsService.getInstance();
  if (!context.mounted || profiles.activeId != profile) return;
  var titleOnly = titleIdentity != null && SubtitleSelectionRules.hasOverride(titleIdentity);
  var rules = SubtitleSelectionRules.resolve(titleIdentity: titleOnly ? titleIdentity : null);
  var busy = false;
  String? error;
  await showDialog<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, update) {
    Future<void> save({bool reset = false}) async {
      if (busy || profiles.activeId != profile) return;
      update(() { busy = true; error = null; });
      try {
        await SubtitleSelectionRules.save(reset ? null : rules, profileId: profile,
          titleIdentity: titleOnly ? titleIdentity : null);
        if (context.mounted) Navigator.pop(context);
      } catch (_) { if (context.mounted) update(() => error = 'The preferences could not be saved. Check the active profile or remove an earlier title override.'); }
      finally { if (context.mounted) update(() => busy = false); }
    }
    return PopScope(canPop: !busy, child: AlertDialog(title: const Text('Subtitle role preferences'),
      content: SizedBox(width: 550, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Used for automatic fallback and preferred downloads on the next open. Explicit Off, carried track choices '
            'and server-selected tracks keep priority. Language order is unchanged. '
            'Forced and SDH/CC labels use provider flags or explicit title markers; unmarked captions are not verified full dialogue.'),
        if (titleIdentity != null) SwitchListTile(title: const Text('Override for this title'), value: titleOnly,
          subtitle: const Text('Off edits this profile’s default. A title override can explicitly choose “Any”.'),
          onChanged: busy ? null : (value) => update(() {
            titleOnly = value; rules = SubtitleSelectionRules.resolve(titleIdentity: value ? titleIdentity : null);
          })),
        DropdownButtonFormField<SubtitleForcedRule>(key: ValueKey((titleOnly, rules.forced)), initialValue: rules.forced,
          decoration: const InputDecoration(labelText: 'Caption role'),
          items: const [DropdownMenuItem(value: SubtitleForcedRule.any, child: Text('Any role')),
            DropdownMenuItem(value: SubtitleForcedRule.full, child: Text('Exclude forced-only tracks')),
            DropdownMenuItem(value: SubtitleForcedRule.forced, child: Text('Forced-only tracks'))],
          onChanged: busy ? null : (value) => update(() => rules = SubtitleRoleRules(
            forced: value ?? rules.forced, accessibility: rules.accessibility))),
        DropdownButtonFormField<SubtitleAccessRule>(key: ValueKey((titleOnly, rules.accessibility)), initialValue: rules.accessibility,
          decoration: const InputDecoration(labelText: 'SDH / closed captions'),
          items: const [DropdownMenuItem(value: SubtitleAccessRule.any, child: Text('No preference')),
            DropdownMenuItem(value: SubtitleAccessRule.prefer, child: Text('Prefer marked SDH / CC')),
            DropdownMenuItem(value: SubtitleAccessRule.avoid, child: Text('Prefer captions without SDH / CC markers'))],
          onChanged: busy ? null : (value) => update(() => rules = SubtitleRoleRules(
            forced: rules.forced, accessibility: value ?? rules.accessibility))),
        const Text('Up to 200 title overrides per profile. These preferences stay on this device.'),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]))), actions: [
        TextButton(onPressed: busy ? null : () => save(reset: true), child: Text(titleOnly ? 'Remove title override' : 'Reset profile default')),
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: busy || profiles.activeId != profile ? null : () => save(), child: const Text('Save')),
      ],
    ));
  }));
}
