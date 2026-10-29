import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../focus/focusable_button.dart';
import '../../games/game_artwork.dart';
import '../../games/game_models.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../theme/mono_tokens.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/settings_section.dart';
import 'game_cover.dart';
import 'game_presentation.dart';

/// A normal PlezyNG detail route. Account activity stays lazy and profile owned.
class GameDetailScreen extends StatelessWidget {
  const GameDetailScreen({
    super.key,
    required this.game,
    required this.artwork,
    required this.favorite,
    required this.onFavorite,
    required this.onPlay,
    required this.onChooseComputer,
    required this.onPlayRoute,
    required this.routeActions,
    this.preferredRouteKey,
    this.activity,
    this.sessions = const [],
    this.onMiniPlayer,
    this.onUseAsController,
  });
  final LibraryGame game;
  final GameArtworkLoader artwork;
  final bool favorite;
  final String? preferredRouteKey;
  final VoidCallback? onFavorite, onPlay, onChooseComputer, onMiniPlayer, onUseAsController;
  final void Function(GameRoute)? onPlayRoute;
  final Widget Function(GameRoute) routeActions;
  final Widget? activity;
  final List<Widget> sessions;

  @override
  Widget build(BuildContext context) {
    final first = game.routes.firstOrNull;
    final theme = Theme.of(context);
    final cover = SizedBox(
      width: MediaQuery.sizeOf(context).width < 680
          ? (MediaQuery.textScalerOf(context).scale(16) >= 28 ? 108 : 148)
          : 180,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(tokens(context).radiusSm),
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: GameCover(
            game: first?.game ?? StreamGame(hostKey: 'catalog', id: game.key, name: game.name),
            host: first?.host,
            steamAppId: game.steamAppId,
            cacheWidth: 480,
            artwork: artwork,
          ),
        ),
      ),
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (game.steamAppId != null) ...[const SteamSourceBadge(), const SizedBox(height: 12)],
        Semantics(header: true, child: Text(isolateDisplayText(game.name), style: theme.textTheme.headlineMedium)),
        const SizedBox(height: 12),
        Text(gameAvailabilityLabel(game), style: theme.textTheme.titleMedium),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FocusableButton(
              onPressed: onPlay,
              useBackgroundFocus: true,
              child: FilledButton.icon(
                onPressed: onPlay,
                icon: AppIcon(game.routes.isEmpty ? Symbols.add_rounded : Symbols.play_arrow_rounded),
                label: Text(game.routes.isEmpty ? t.games.connectComputer : t.games.play),
              ),
            ),
            if (game.routes.isNotEmpty)
              FocusableButton(
                onPressed: onChooseComputer,
                child: OutlinedButton.icon(
                  onPressed: onChooseComputer,
                  icon: const AppIcon(Symbols.computer_rounded),
                  label: Text(t.games.chooseComputer),
                ),
              ),
            FocusableButton(
              onPressed: onFavorite,
              child: OutlinedButton.icon(
                onPressed: onFavorite,
                icon: AppIcon(favorite ? Symbols.favorite_rounded : Symbols.favorite_border_rounded),
                label: Text(favorite ? t.games.unfavorite : t.games.favorite),
              ),
            ),
            if (onUseAsController != null)
              FocusableButton(
                onPressed: onUseAsController,
                child: TextButton.icon(
                  onPressed: onUseAsController,
                  icon: const AppIcon(Symbols.sports_esports_rounded),
                  label: Text(t.games.useAsController),
                ),
              ),
            if (onMiniPlayer != null)
              FocusableButton(
                onPressed: onMiniPlayer,
                child: TextButton.icon(
                  onPressed: onMiniPlayer,
                  icon: const AppIcon(Symbols.picture_in_picture_alt_rounded),
                  label: Text(t.videoControls.openMiniPlayer),
                ),
              ),
          ],
        ),
        if (onUseAsController != null) ...[
          const SizedBox(height: 8),
          Text(t.games.controllerOnlyHelp, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 8),
        Text(
          game.routes.isEmpty ? t.games.connectToPlay : t.games.inventorySnapshotHelp,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
    return FocusedScrollScaffold(
      title: Text(t.games.gameDetails),
      focusableAppBarActions: true,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  constraints.maxWidth >= 680 && MediaQuery.textScalerOf(context).scale(16) < 28
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cover,
                        const SizedBox(width: 32),
                        Expanded(child: info),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(child: cover),
                        const SizedBox(height: 24),
                        info,
                      ],
                    ),
            ),
          ),
        ),
        if (game.routes.isNotEmpty)
          SliverToBoxAdapter(
            child: SettingsGroup(
              title: t.games.computers,
              children: [
                for (final route in game.routes)
                  GameComputerTile(
                    route: route,
                    preferred: preferredRouteKey == route.key,
                    onPlay: onPlayRoute == null ? null : () => onPlayRoute!(route),
                    actions: routeActions(route),
                  ),
              ],
            ),
          ),
        if (sessions.isNotEmpty)
          SliverToBoxAdapter(
            child: SettingsGroup(title: t.games.streamDetails, children: sessions),
          ),
        if (activity != null)
          SliverToBoxAdapter(
            child: Padding(padding: const EdgeInsets.all(24), child: activity),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}
