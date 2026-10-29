import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../games/game_models.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../theme/mono_tokens.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_section.dart';

/// Factual source attribution, not Valve's licensed logo or a certification.
/// Never takes the place of the action icon or a connection-state label.
class SteamSourceBadge extends StatelessWidget {
  const SteamSourceBadge({super.key, this.onArtwork = false});
  final bool onArtwork;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: onArtwork ? const Color(0xED101820) : colors.surfaceContainerHighest,
        border: Border.all(color: onArtwork ? Colors.white38 : colors.outlineVariant),
        borderRadius: BorderRadius.circular(Theme.of(context).extension<MonoTokens>()?.radiusSm ?? 8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Semantics(
          label: t.games.steamSource,
          excludeSemantics: true,
          child: Text(
            'Steam',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: onArtwork ? Colors.white : colors.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

String gameInstallationLabel(GameInstallation installation) => switch (installation) {
  GameInstallation.installed => t.games.installed,
  GameInstallation.incomplete => t.games.installationIncomplete,
  GameInstallation.notInstalled => t.games.notInstalled,
  GameInstallation.unknown => t.games.installationUnknown,
};

/// Installed is an inventory observation. It never means online or playable.
String gameAvailabilityLabel(LibraryGame game) {
  final installed = game.routes.where((r) => r.installation == GameInstallation.installed).toList();
  if (installed.length == 1) return t.games.installedOn(computer: isolateDisplayText(installed.single.host.name));
  if (installed.length > 1) return t.games.installedComputers(n: installed.length);
  if (game.routes.isEmpty) return t.games.connectToPlayShort;
  if (game.routes.length == 1) {
    return '${isolateDisplayText(game.routes.single.host.name)} · ${gameInstallationLabel(game.routes.single.installation)}';
  }
  return t.games.savedComputers(n: game.routes.length);
}

class GameNotice extends StatelessWidget {
  const GameNotice({
    super.key,
    required this.title,
    required this.message,
    this.icon = Symbols.info_rounded,
    this.actionLabel,
    this.onAction,
    this.live = false,
    this.actionFocusNode,
  });
  final String title, message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool live;
  final FocusNode? actionFocusNode;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: live,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: AppIcon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(message, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 8),
            FocusableButton(
              focusNode: actionFocusNode,
              onPressed: onAction,
              child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ),
          ],
        ],
      ),
    ),
  );
}

class GameSetupPanel extends StatelessWidget {
  const GameSetupPanel({super.key, this.onConnect, this.onLink, this.accountLinked = false, this.firstFocus});
  final VoidCallback? onConnect, onLink;
  final bool accountLinked;
  final FocusNode? firstFocus;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(t.games.setupTitle, style: Theme.of(context).textTheme.headlineSmall),
              ),
              const SizedBox(height: 8),
              Text(t.games.setupHelp),
              const SizedBox(height: 20),
            ],
          ),
        ),
        SettingsGroup(
          children: [
            GameNotice(
              title: t.games.computerSetupTitle,
              message: t.games.computerSetupHelp,
              icon: Symbols.computer_rounded,
              actionLabel: t.games.findComputers,
              onAction: onConnect,
              actionFocusNode: firstFocus,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SteamSourceBadge()),
                  GameNotice(
                    title: accountLinked ? t.games.accountLinked : t.games.accountSetupTitle,
                    message: t.games.accountSetupHelp,
                    icon: Symbols.library_books_rounded,
                    actionLabel: accountLinked ? t.games.refreshSteamAccount : t.games.linkSteamAccount,
                    onAction: onLink,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Shared between the detail screen and the play-on-computer chooser.
class GameComputerTile extends StatelessWidget {
  const GameComputerTile({super.key, required this.route, this.preferred = false, this.onPlay, this.actions});
  final GameRoute route;
  final bool preferred;
  final VoidCallback? onPlay;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FocusableListTile(
        dense: false,
        selected: preferred,
        leading: AppIcon(switch (route.installation) {
          GameInstallation.installed => Symbols.check_circle_rounded,
          GameInstallation.incomplete => Symbols.downloading_rounded,
          GameInstallation.notInstalled => Symbols.download_rounded,
          GameInstallation.unknown => Symbols.computer_rounded,
        }),
        title: Text(isolateDisplayText(route.host.name)),
        subtitle: Text(
          [
            gameInstallationLabel(route.installation),
            route.host.protocol == GameProtocol.steam ? t.games.steamSource : t.games.moonlight,
            if (preferred) t.games.preferredComputer,
          ].join(' · '),
        ),
        onTap: onPlay,
        trailing: actions,
      ),
      if (route.observedAt != null)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 12),
          child: Text(
            t.games.inventoryChecked(date: MaterialLocalizations.of(context).formatCompactDate(route.observedAt!)),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
    ],
  );
}
