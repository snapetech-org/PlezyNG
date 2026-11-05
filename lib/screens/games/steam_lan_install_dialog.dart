import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../games/game_models.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/dialog_action_button.dart';

/// Inventory is evidence of installation at a point in time, never proof of
/// LAN proximity, online state, entitlement or Steam's donor selection.
class SteamLanInstallDialog extends StatelessWidget {
  const SteamLanInstallDialog({super.key, required this.target, required this.game, required this.isCurrent});
  final GameHost target;
  final LibraryGame? game;
  final bool Function() isCurrent;

  @override
  Widget build(BuildContext context) {
    final candidates = <String, GameRoute>{
      for (final route in game?.routes ?? <GameRoute>[])
        if (route.host.key != target.key &&
            route.host.protocol == GameProtocol.steam &&
            route.installation == GameInstallation.installed)
          route.host.key: route,
    }.values.toList()..sort((a, b) => a.host.name.toLowerCase().compareTo(b.host.name.toLowerCase()));
    return AlertDialog(
      title: Text(t.games.lanInstallTitle),
      scrollable: true,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (game != null) Text(isolateDisplayText(game!.name), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(t.games.lanInstallHelp),
          const SizedBox(height: 12),
          Text(candidates.isEmpty ? t.games.lanInstallNoCandidates : t.games.lanInstallCandidates),
          for (final candidate in candidates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const AppIcon(Symbols.computer_rounded),
              title: Text(isolateDisplayText(candidate.host.name)),
              subtitle: candidate.observedAt == null
                  ? null
                  : Text(
                      t.games.inventoryChecked(
                        date: MaterialLocalizations.of(context).formatCompactDate(candidate.observedAt!),
                      ),
                    ),
            ),
          const SizedBox(height: 12),
          Text(t.games.hostActionConfirm(computer: isolateDisplayText(target.name))),
        ],
      ),
      actions: [
        DialogActionButton(label: t.common.cancel, onPressed: () => Navigator.pop(context, false)),
        DialogActionButton(
          label: t.games.lanInstallTarget(computer: isolateDisplayText(target.name)),
          onPressed: () => Navigator.pop(context, isCurrent()),
        ),
      ],
    );
  }
}
