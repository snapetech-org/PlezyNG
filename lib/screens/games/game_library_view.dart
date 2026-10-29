import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../games/game_artwork.dart';
import '../../games/game_models.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import 'game_card.dart';
import 'game_presentation.dart';

/// Production library presentation, separate from profile-owned side effects.
class GameLibraryView extends StatefulWidget {
  const GameLibraryView({
    super.key,
    required this.library,
    required this.artwork,
    required this.firstFocus,
    required this.onConnections,
    required this.onSettings,
    required this.onHelp,
    required this.onLink,
    required this.onRefresh,
    required this.onPlay,
    required this.onDetails,
    required this.onFavorite,
    required this.onMiniPlayer,
    this.onUseAsController,
    this.loading = false,
    this.busy = false,
    this.available = true,
    this.catalogNotices = const [],
  });
  final GameLibrary library;
  final GameArtworkLoader artwork;
  final FocusNode firstFocus;
  final VoidCallback onConnections, onSettings, onHelp, onLink, onRefresh;
  final void Function(LibraryGame) onPlay, onDetails, onFavorite, onMiniPlayer;
  final void Function(LibraryGame)? onUseAsController;
  final bool loading, busy, available;
  final List<Widget> catalogNotices;
  @override
  State<GameLibraryView> createState() => _GameLibraryViewState();
}

class _GameLibraryViewState extends State<GameLibraryView> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _computerFilter;
  bool _installedOnly = false;
  @override
  void didUpdateWidget(GameLibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_computerFilter != null && !widget.library.hosts.any((h) => h.key == _computerFilter)) _computerFilter = null;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _heading(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(label, style: Theme.of(context).textTheme.titleLarge),
  );
  Widget _grid(List<LibraryGame> games, {bool first = false}) => GameCardGrid<LibraryGame>(
    games: games,
    builder: (context, game) {
      final route = game.preferredRoute(widget.library);
      final cardGame = StreamGame(
        hostKey: route?.host.key ?? 'catalog',
        id: route?.game.id ?? game.key,
        name: game.name,
      );
      return GameCard(
        key: ValueKey(game.key),
        game: cardGame,
        host: route?.host,
        steamAppId: game.steamAppId,
        artwork: widget.artwork,
        subtitle: gameAvailabilityLabel(game),
        favorite: widget.library.favoriteKeys.contains(game.key),
        focusNode: first && game == games.first ? widget.firstFocus : null,
        playLabel: game.routes.isEmpty ? t.games.gameDetails : t.games.play,
        onPlay: widget.busy || !widget.available ? null : () => widget.onPlay(game),
        onDetails: widget.busy || !widget.available ? null : () => widget.onDetails(game),
        onPlayInWorkspace:
            widget.busy || !widget.available || !game.routes.any((r) => r.host.protocol == GameProtocol.steam)
            ? null
            : () => widget.onMiniPlayer(game),
        onUseAsController:
            widget.busy ||
                !widget.available ||
                widget.onUseAsController == null ||
                !game.routes.any((r) => r.host.protocol == GameProtocol.steam)
            ? null
            : () => widget.onUseAsController!(game),
        onFavorite: widget.busy || !widget.available ? null : () => widget.onFavorite(game),
      );
    },
  );

  void _clearFilters() => setState(() {
    _query = '';
    _searchController.clear();
    _computerFilter = null;
    _installedOnly = false;
  });

  @override
  Widget build(BuildContext context) {
    final state = widget.library;
    final entries = state.entries;
    final byKey = {for (final game in entries) game.key: game};
    final filtered = entries.where((game) {
      if (!game.name.toLowerCase().contains(_query.trim().toLowerCase())) return false;
      if (game.routes.isEmpty) return _computerFilter == null && !_installedOnly;
      return game.routes.any(
        (route) =>
            (_computerFilter == null || route.host.key == _computerFilter) &&
            (!_installedOnly || route.installation == GameInstallation.installed),
      );
    }).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final recent = _query.isEmpty
        ? state.recentKeys.map((key) => byKey[key]).whereType<LibraryGame>().where(filtered.contains).take(6).toList()
        : <LibraryGame>[];
    final favorites = _query.isEmpty
        ? state.favoriteKeys.map((key) => byKey[key]).whereType<LibraryGame>().where(filtered.contains).toList()
        : <LibraryGame>[];
    final enabled = !widget.busy && widget.available;
    return FocusedScrollScaffold(
      title: Text(t.games.title),
      automaticallyImplyLeading: false,
      focusableAppBarActions: true,
      actions: [
        FocusableButton(
          autoScroll: false,
          onPressed: enabled ? widget.onConnections : null,
          child: IconButton(
            tooltip: t.games.connections,
            icon: const AppIcon(Symbols.devices_rounded),
            onPressed: enabled ? widget.onConnections : null,
          ),
        ),
        FocusableButton(
          autoScroll: false,
          onPressed: enabled ? widget.onSettings : null,
          child: IconButton(
            tooltip: t.games.streamSettings,
            icon: const AppIcon(Symbols.tune_rounded),
            onPressed: enabled ? widget.onSettings : null,
          ),
        ),
        FocusableButton(
          autoScroll: false,
          onPressed: widget.onHelp,
          child: IconButton(
            tooltip: t.games.help,
            icon: const AppIcon(Symbols.help_outline_rounded),
            onPressed: widget.onHelp,
          ),
        ),
      ],
      slivers: [
        if (widget.loading || widget.busy)
          SliverToBoxAdapter(
            child: Semantics(liveRegion: true, label: t.games.connecting, child: const LinearProgressIndicator()),
          ),
        if (!widget.loading && !widget.available)
          SliverToBoxAdapter(
            child: GameNotice(title: t.games.title, message: t.games.nativeEnginePending),
          ),
        if (!widget.loading && entries.isEmpty) ...[
          SliverToBoxAdapter(
            child: GameSetupPanel(
              firstFocus: widget.firstFocus,
              accountLinked: state.steamAccountId != null,
              onConnect: enabled ? widget.onConnections : null,
              onLink: enabled ? (state.steamAccountId == null ? widget.onLink : widget.onRefresh) : null,
            ),
          ),
          if (state.hosts.isNotEmpty)
            SliverToBoxAdapter(
              child: GameNotice(
                title: t.games.emptyLibraryTitle,
                message: t.games.emptyConnectedHelp,
                actionLabel: t.games.manageConnections,
                onAction: enabled ? widget.onConnections : null,
              ),
            ),
        ],
        if (entries.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: FocusableTextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: t.games.search,
                  prefixIcon: const AppIcon(Symbols.search_rounded),
                ),
                onChanged: (value) => setState(() => _query = value),
                onSubmitted: (_) => widget.firstFocus.requestFocus(),
                onNavigateDown: widget.firstFocus.requestFocus,
              ),
            ),
          ),
          if (state.hosts.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      label: Text(t.games.installed),
                      selected: _installedOnly,
                      onSelected: (selected) => setState(() => _installedOnly = selected),
                    ),
                    ChoiceChip(
                      label: Text(t.games.allComputers),
                      selected: _computerFilter == null,
                      onSelected: (_) => setState(() => _computerFilter = null),
                    ),
                    for (final host in state.hosts)
                      ChoiceChip(
                        label: Text(isolateDisplayText(host.name)),
                        selected: _computerFilter == host.key,
                        onSelected: (_) => setState(() => _computerFilter = host.key),
                      ),
                  ],
                ),
              ),
            ),
        ],
        if (recent.isNotEmpty) ...[SliverToBoxAdapter(child: _heading(t.games.recent)), _grid(recent, first: true)],
        if (favorites.isNotEmpty) ...[
          SliverToBoxAdapter(child: _heading(t.games.favorites)),
          _grid(favorites, first: recent.isEmpty),
        ],
        if (filtered.isNotEmpty) ...[
          SliverToBoxAdapter(child: _heading(t.games.allGames)),
          _grid(filtered, first: recent.isEmpty && favorites.isEmpty),
        ] else if (entries.isNotEmpty)
          SliverToBoxAdapter(
            child: GameNotice(
              title: t.games.noMatches,
              message: t.games.filterEmptyHelp,
              icon: Symbols.search_rounded,
              actionLabel: t.games.clearGameFilters,
              actionFocusNode: widget.firstFocus,
              onAction: _clearFilters,
            ),
          ),
        ...widget.catalogNotices,
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}
