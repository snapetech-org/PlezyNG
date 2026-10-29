import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../services/settings_service.dart';
import '../../../services/subtitle_selection_rules.dart';

Future<void> showSubtitleRoleDialog(BuildContext context, {String? titleIdentity}) async {
  final translations = Translations.of(context);
  final copy = translations.videoControls.subtitleRoles;
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
      } catch (_) { if (context.mounted) update(() => error = copy.saveFailed); }
      finally { if (context.mounted) update(() => busy = false); }
    }
    return PopScope(canPop: !busy, child: AlertDialog(title: Text(copy.title),
      content: SizedBox(width: 550, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(copy.description),
        if (titleIdentity != null) SwitchListTile(title: Text(copy.titleOverride), value: titleOnly,
          subtitle: Text(copy.titleOverrideHelp),
          onChanged: busy ? null : (value) => update(() {
            titleOnly = value; rules = SubtitleSelectionRules.resolve(titleIdentity: value ? titleIdentity : null);
          })),
        DropdownButtonFormField<SubtitleForcedRule>(key: ValueKey((titleOnly, rules.forced)), initialValue: rules.forced,
          decoration: InputDecoration(labelText: copy.captionRole),
          items: [DropdownMenuItem(value: SubtitleForcedRule.any, child: Text(copy.anyRole)),
            DropdownMenuItem(value: SubtitleForcedRule.full, child: Text(copy.excludeForcedOnly)),
            DropdownMenuItem(value: SubtitleForcedRule.forced, child: Text(copy.forcedOnly))],
          onChanged: busy ? null : (value) => update(() => rules = SubtitleRoleRules(
            forced: value ?? rules.forced, accessibility: rules.accessibility))),
        DropdownButtonFormField<SubtitleAccessRule>(key: ValueKey((titleOnly, rules.accessibility)), initialValue: rules.accessibility,
          decoration: InputDecoration(labelText: copy.accessibilityRole),
          items: [DropdownMenuItem(value: SubtitleAccessRule.any, child: Text(copy.noPreference)),
            DropdownMenuItem(value: SubtitleAccessRule.prefer, child: Text(copy.preferSdh)),
            DropdownMenuItem(value: SubtitleAccessRule.avoid, child: Text(copy.avoidSdh))],
          onChanged: busy ? null : (value) => update(() => rules = SubtitleRoleRules(
            forced: rules.forced, accessibility: value ?? rules.accessibility))),
        Text(copy.limitHelp),
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]))), actions: [
        TextButton(onPressed: busy ? null : () => save(reset: true), child: Text(titleOnly ? copy.removeTitleOverride : copy.resetProfileDefault)),
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: Text(translations.common.cancel)),
        FilledButton(onPressed: busy || profiles.activeId != profile ? null : () => save(), child: Text(translations.common.save)),
      ],
    ));
  }));
}
