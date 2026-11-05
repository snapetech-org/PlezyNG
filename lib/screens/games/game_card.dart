import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/card_focus_scope.dart';
import '../../focus/focusable_wrapper.dart';
import '../../games/game_artwork.dart';
import '../../games/game_models.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../services/external_access_directory.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_tokens.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/media_grid_delegate.dart';
import '../../widgets/sliver_cross_axis_layout_builder.dart';
import '../external_access_screen.dart';
import 'game_cover.dart';
import 'game_presentation.dart';

/// Games share the media browser's packing, gutters and poster focus treatment.
/// They keep their own model and actions instead of masquerading as films.
class GameCardGrid<T> extends StatelessWidget {
  const GameCardGrid({super.key, required this.games, required this.builder});
  final List<T> games;
  final Widget Function(BuildContext, T) builder;

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    sliver: SliverCrossAxisLayoutBuilder(
      builder: (context, width) {
        final geometry = MediaGridGeometry.resolve(
          context: context,
          crossAxisExtent: width,
          density: SettingsService.instance.read(SettingsService.libraryDensity),
        );
        // Captions grow with the user's font size; posters keep their shape.
        final scaler = MediaQuery.textScalerOf(context);
        final theme = Theme.of(context).textTheme;
        final titleHeight = scaler.scale(theme.bodyMedium?.fontSize ?? 14) * 1.4;
        final hostHeight = scaler.scale(theme.bodySmall?.fontSize ?? 12) * 1.4;
        // Keep at least 6.5 scaled caption ems; large text should reduce the
        // column count instead of leaving every availability label truncated.
        final captionWidth = scaler.scale(theme.bodySmall?.fontSize ?? 12) * 6.5;
        final columns = ((width + geometry.spacing) / (captionWidth + geometry.spacing)).floor().clamp(
          1,
          geometry.columnCount,
        );
        final itemWidth = (width - (columns - 1) * geometry.spacing) / columns;
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: geometry.spacing,
            mainAxisSpacing: geometry.spacing,
            mainAxisExtent: (itemWidth - 12) * 1.5 + titleHeight * 2 + hostHeight * 2 + 22,
          ),
          itemCount: games.length,
          itemBuilder: (context, index) => builder(context, games[index]),
        );
      },
    ),
  );
}

class GameCard extends StatefulWidget {
  const GameCard({
    super.key,
    required this.game,
    this.host,
    this.steamAppId,
    this.subtitle,
    this.onDetails,
    this.playLabel,
    required this.artwork,
    required this.favorite,
    required this.onPlay,
    this.onActivate,
    required this.onFavorite,
    this.onPlayInWorkspace,
    this.onUseAsController,
    this.focusNode,
    this.loadCover,
  });
  final StreamGame game;
  final GameHost? host;
  final int? steamAppId;
  final String? subtitle, playLabel;
  final VoidCallback? onDetails;
  final GameArtworkLoader artwork;
  final bool favorite;
  final VoidCallback? onPlay;

  /// Browse-only devices activate details while retaining a distinct Play menu.
  final VoidCallback? onActivate;
  final VoidCallback? onFavorite;
  final VoidCallback? onPlayInWorkspace;
  final VoidCallback? onUseAsController;
  final FocusNode? focusNode;
  final Future<Uint8List?> Function()? loadCover;

  @override
  State<GameCard> createState() => _GameCardState();
}

class _GameCardState extends State<GameCard> {
  String get _subtitle => widget.subtitle ?? widget.host?.name ?? t.games.steamLibrary;

  Future<void> _menu() async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final action = await showAdaptiveAppMenu<String>(
      context,
      title: isolateDisplayText(widget.game.name),
      anchorRect: box.localToGlobal(Offset.zero) & box.size,
      focusFirstItem: true,
      entries: [
        if (widget.onDetails != null)
          AppMenuItem(value: 'details', label: t.games.gameDetails, icon: Symbols.info_rounded),
        if (widget.onPlay != null)
          AppMenuItem(value: 'play', label: widget.playLabel ?? t.games.play, icon: Symbols.play_arrow_rounded),
        if (widget.onPlayInWorkspace != null)
          AppMenuItem(
            value: 'play_in_workspace',
            label: t.videoControls.openMiniPlayer,
            icon: Symbols.picture_in_picture_alt_rounded,
          ),
        if (widget.onUseAsController != null)
          AppMenuItem(value: 'use_as_controller', label: t.games.useAsController, icon: Symbols.sports_esports_rounded),
        if (widget.onFavorite != null)
          AppMenuItem(
            value: 'favorite',
            label: widget.favorite ? t.games.unfavorite : t.games.favorite,
            icon: widget.favorite ? Symbols.favorite_rounded : Symbols.favorite_border_rounded,
          ),
        AppMenuItem(value: 'storefronts', label: t.explore.detail.links, icon: Symbols.open_in_new_rounded),
      ],
    );
    if (!mounted) return;
    if (action == 'details') widget.onDetails?.call();
    if (action == 'play') widget.onPlay?.call();
    if (action == 'play_in_workspace') widget.onPlayInWorkspace?.call();
    if (action == 'use_as_controller') widget.onUseAsController?.call();
    if (action == 'favorite') widget.onFavorite?.call();
    if (action == 'storefronts') {
      unawaited(
        Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ExternalAccessScreen(
              title: widget.game.name,
              gamePlatformIds: _steamAppId == null ? const {} : {'steam': '$_steamAppId'},
              categories: const [ExternalAccessCategory.games],
            ),
          ),
        ),
      );
    }
  }

  int? get _steamAppId {
    final suppliedAppId = widget.steamAppId;
    if (suppliedAppId != null) {
      return suppliedAppId > 0 && suppliedAppId <= 0xffffffff ? suppliedAppId : null;
    }
    if (widget.host?.protocol != GameProtocol.steam || !RegExp(r'^[1-9]\d{0,9}$').hasMatch(widget.game.id)) {
      return null;
    }
    final appId = int.tryParse(widget.game.id);
    return appId != null && appId <= 0xffffffff ? appId : null;
  }

  @override
  Widget build(BuildContext context) {
    final radius = tokens(context).radiusSm;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: FocusableWrapper(
        focusNode: widget.focusNode,
        delegateFocusBorder: true,
        borderRadius: radius,
        descendantsAreFocusable: true,
        semanticLabel: '${isolateDisplayText(widget.game.name)}, ${isolateDisplayText(_subtitle)}',
        semanticValue: widget.favorite ? t.games.favorites : null,
        onSelect: widget.onActivate ?? widget.onPlay,
        onLongPress: _menu,
        enableLongPress: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onActivate ?? widget.onPlay,
          onLongPress: _menu,
          onSecondaryTap: _menu,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: CardFocusBorder(
                  borderRadius: radius,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          GameCover(
                            game: widget.game,
                            host: widget.host,
                            steamAppId: widget.steamAppId,
                            artwork: widget.artwork,
                            loadCover: widget.loadCover,
                          ),
                          if (widget.steamAppId != null)
                            const PositionedDirectional(start: 6, top: 6, child: SteamSourceBadge(onArtwork: true)),
                          if (widget.onDetails != null)
                            PositionedDirectional(
                              end: 0,
                              bottom: 0,
                              child: IconButton.filledTonal(
                                tooltip: t.games.gameOptions(game: isolateDisplayText(widget.game.name)),
                                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                                icon: const AppIcon(Symbols.more_horiz_rounded),
                                onPressed: _menu,
                              ),
                            ),
                          if (widget.favorite)
                            PositionedDirectional(
                              start: 6,
                              bottom: 6,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.72),
                                  borderRadius: BorderRadius.circular(radius),
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(5),
                                  child: AppIcon(Symbols.favorite_rounded, size: 16, color: Colors.white),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isolateDisplayText(widget.game.name),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
              Text(
                isolateDisplayText(_subtitle),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
