import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/input_mode_tracker.dart';
import '../../games/game_discovery.dart';
import '../../games/game_library_controller.dart';
import '../../games/steam_internet_tunnel.dart';
import '../../games/steam_input_profile.dart';
import '../../games/steam_touch_layout.dart';
import '../../games/game_models.dart';
import '../../games/romm/romm_controller.dart';
import '../../games/romm/romm_models.dart';
import '../../games/romm/romm_link.dart';
import '../../games/romm/romm_text.dart';
import '../../focus/focusable_text_field.dart';
import 'game_card.dart';
import 'romm_connections_screen.dart';
import 'romm_detail_screen.dart';
import 'romm_session_page.dart';
import 'romm_library_filters.dart';
import '../../games/steam_inventory_exchange.dart';
import '../../games/steam_host_actions.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/file_picker_service.dart';
import '../../services/credential_vault.dart';
import '../../games/game_streaming_client.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/refreshable.dart';
import '../../mixins/tab_visibility_aware.dart';
import '../../multiview/steam_game_workspace_surface.dart';
import '../../multiview/workspace_controller.dart';
import '../../multiview/workspace_models.dart';
import '../../profiles/active_profile_provider.dart';
import '../../services/playback_coordinator.dart';
import '../../services/trackers/oauth_proxy_client.dart';
import '../../services/settings_service.dart';
import '../../sources/source_controller.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/dialog_action_button.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../libraries/state_messages.dart';
import 'game_connection_dialogs.dart';
import '../../widgets/oauth_proxy_dialog.dart';
import 'game_library_view.dart';
import 'game_detail_screen.dart';
import 'game_presentation.dart';
import 'game_settings_screen.dart';
import 'steam_game_activity_panel.dart';
import 'steam_stream_diagnostics.dart';
import 'steam_lan_install_dialog.dart';

class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key, this.initialRommLink});
  final RommLink? initialRommLink;
  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> with FocusableTab, TabVisibilityAware {
  GameLibraryController? _controller;
  RommController? _romm;
  Timer? _rommSearch;
  bool _initialRommLinkOpened = false;
  bool _rommLoadError = false;
  MultiviewWorkspaceController? _workspaceController;
  final Map<String, SteamGameWorkspaceSession> _workspaceGameSessions = <String, SteamGameWorkspaceSession>{};
  final _presentationRevision = ValueNotifier<int>(0);
  final _pages = <Route<dynamic>>{};
  final _pageContexts = <Route<dynamic>, BuildContext>{};
  ScopedDialogHandle<void>? _accountLinkDialog;
  VoidCallback? _cancelAccountLink;
  BuildContext get _actionContext => _pageContexts.values.lastOrNull ?? context;
  final _firstFocus = FocusNode(debugLabel: 'First Games action');
  final _addFocus = FocusNode(debugLabel: 'Add gaming computer');
  final _scanFocus = FocusNode(debugLabel: 'Find gaming computers');
  String? _profile;
  int? _sourceGeneration;
  int _epoch = 0;
  bool _loading = true;
  bool _loadFailed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = context.watch<ActiveProfileProvider>().activeId;
    // select is only supported during build; dependency changes also deliver
    // profile/source retirement before a pushed Games page can act again.
    final generation = context.watch<SourceController>().generation;
    if (id == _profile && generation == _sourceGeneration && _controller != null) {
      return;
    }
    _profile = id;
    _sourceGeneration = generation;
    _retire();
    final epoch = ++_epoch;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(id, epoch));
  }

  Future<void> _load(String? id, int epoch) async {
    if (!mounted || epoch != _epoch || id == null) {
      return;
    }
    if (!PlatformDetector.supportsGameLibrary()) {
      setState(() => _loading = false);
      return;
    }
    final sources = context.read<SourceController>();
    try {
      await sources.ready;
      if (!mounted || epoch != _epoch) {
        return;
      }
      sources.requireSession();
      if (sources.profileId != id) {
        return;
      }
      final generation = sources.generation;
      final controller = GameLibraryController(
        repository: sources.repository,
        profileId: id,
        sessionCurrent: () =>
            mounted &&
            epoch == _epoch &&
            sources.current(generation) &&
            !sources.blocked &&
            context.read<ActiveProfileProvider>().activeId == id &&
            (widget.initialRommLink != null ||
                SettingsService.instance.read(SettingsService.showGamesTabForProfile(id))),
        client: NativeGameStreamingClient(),
      );
      _controller = controller;
      controller.addListener(_changed);
      await controller.load();
      if (!controller.current) {
        return;
      }
      final romm = _romm = RommController(
        repository: sources.repository,
        profileId: id,
        sessionCurrent: () => controller.current,
      );
      romm.addListener(_changed);
      try {
        await romm.load();
        if (romm.current && romm.connections.isNotEmpty) {
          unawaited(romm.refresh());
        }
      } catch (_) {
        romm.removeListener(_changed);
        romm.dispose();
        if (mounted && epoch == _epoch && identical(_romm, romm)) {
          _romm = null;
          _rommLoadError = true;
        }
      }
      if (mounted && controller.current) {
        setState(() {
          _loading = false;
          _loadFailed = false;
        });
        if (PlatformDetector.supportsEmbeddedGameStreaming()) {
          unawaited(_scan());
        }
        if (!_initialRommLinkOpened && widget.initialRommLink != null) {
          _initialRommLinkOpened = true;
          unawaited(_rommLink(widget.initialRommLink));
        }
      }
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
      _presentationRevision.value++;
    }
  }

  void _retire() {
    _cancelAccountLink?.call();
    _cancelAccountLink = null;
    final accountDialog = _accountLinkDialog;
    _accountLinkDialog = null;
    final retiring = _pages.toList();
    _pages.clear();
    _pageContexts.clear();
    if (retiring.isNotEmpty || accountDialog != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        accountDialog?.close();
        for (final route in retiring.reversed) {
          dismissDialogsOwnedBy(route);
          if (route.isActive) {
            route.navigator?.removeRoute(route);
          }
        }
      });
    }
    final workspace = _workspaceController;
    for (final entry in _workspaceGameSessions.entries.toList()) {
      workspace?.unregister(entry.key);
      entry.value.dispose();
    }
    _workspaceGameSessions.clear();
    _workspaceController = null;
    _rommSearch?.cancel();
    _rommSearch = null;
    _romm?.removeListener(_changed);
    _romm?.dispose();
    _romm = null;
    _rommLoadError = false;
    _controller?.removeListener(_changed);
    _controller?.dispose();
    _controller = null;
    _loading = true;
    _loadFailed = false;
  }

  void _retryLoad() {
    final id = _profile;
    if (!mounted || id == null) {
      return;
    }
    _retire();
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    unawaited(_load(id, epoch));
  }

  @override
  void dispose() {
    _epoch++;
    _retire();
    _firstFocus.dispose();
    _addFocus.dispose();
    _scanFocus.dispose();
    _presentationRevision.dispose();
    super.dispose();
  }

  @override
  void focusActiveTabIfReady() {
    _firstFocus.requestFocus();
  }

  @override
  void onTabHidden() {
    _controller?.stopScan();
  }

  @override
  void onTabShown() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _run(Future<void> Function(GameLibraryController) work) async {
    final c = _controller;
    if (c == null || !c.current || c.busy) {
      return false;
    }
    try {
      await c.action(() => work(c));
      return true;
    } catch (error) {
      if (!mounted || !c.current) {
        return false;
      }
      final failure = error is GameClientException ? error.failure : null;
      if (failure == GameClientFailure.cancelled) {
        return false;
      }
      showErrorSnackBar(
        context,
        failure == GameClientFailure.pairingRequired
            ? t.games.pairHelp
            : failure == GameClientFailure.timedOut
            ? t.games.timeout
            : t.games.unavailable,
      );
      return false;
    }
  }

  Future<void> _linkSteamAccount() => _run((c) async {
    final proxy = OAuthProxyClient();
    try {
      final start = await proxy.start('steam');
      c.requireCurrent();
      if (!mounted) {
        return;
      }
      final cancelled = Completer<void>();
      var dialogClosedByFlow = false;
      void cancel() {
        if (!cancelled.isCompleted) {
          cancelled.complete();
        }
      }

      _cancelAccountLink = cancel;
      final dialog = _accountLinkDialog = openScopedDialog<void>(
        context: _actionContext,
        barrierDismissible: false,
        builder: (_) => OAuthProxyDialog(
          start: start,
          serviceName: 'Steam',
          onCancel: () {
            if (dialogClosedByFlow) {
              return;
            }
            cancel();
          },
        ),
      );
      unawaited(
        dialog.closed.then((_) {
          if (!dialogClosedByFlow) {
            cancel();
          }
        }),
      );
      OAuthProxyResult? result;
      try {
        result = await proxy.poll(
          start.session,
          shouldCancel: () => cancelled.isCompleted || !c.current,
          onCancel: cancelled.future,
        );
      } finally {
        dialogClosedByFlow = true;
        dialog.close();
        await dialog.closed;
        if (identical(_accountLinkDialog, dialog)) {
          _accountLinkDialog = null;
        }
        if (identical(_cancelAccountLink, cancel)) {
          _cancelAccountLink = null;
        }
      }
      c.requireCurrent();
      final linked = result;
      if (cancelled.isCompleted || linked == null || linked.steamId == null) {
        return;
      }
      final catalog = linked.steamGames.map(SteamCatalogGame.fromJson).toList(growable: false);
      String? protectedCredential, sessionCredential;
      final token = linked.steamCatalogToken;
      if (token != null) {
        try {
          protectedCredential = await CredentialVault.protect(token);
        } catch (_) {
          // A missing/locked OS keystore must neither block browsing nor cause
          // plaintext persistence. This grant lives only in this profile owner.
          sessionCredential = token;
        }
      }
      c.requireCurrent();
      await c.saveSteamCatalog(
        protectedCredential: protectedCredential,
        sessionCredential: sessionCredential,
        replaceCredential: true,
        steamId: linked.steamId!,
        games: catalog,
        catalogAvailable: linked.steamLibraryAvailable,
        catalogTruncated: linked.steamCatalogTruncated,
      );
      if (mounted && c.current) {
        showSuccessSnackBar(
          context,
          sessionCredential != null
              ? t.games.steamSessionSignIn
              : linked.steamLibraryAvailable
              ? t.games.steamAccountLinked
              : t.games.steamLibraryPrivate,
        );
      }
    } finally {
      proxy.dispose();
    }
  });

  Future<void> _refreshSteamAccount() async {
    final c = _controller;
    if (c == null || !c.current || c.busy) {
      return;
    }
    final encrypted = c.catalogCredential;
    if (encrypted == null) {
      await _linkSteamAccount();
      return;
    }
    var relink = false;
    await _run((c) async {
      final proxy = OAuthProxyClient();
      try {
        final credential = await CredentialVault.reveal(encrypted);
        c.requireCurrent();
        if (credential == null) {
          relink = true;
          return;
        }
        final result = await proxy.refreshSteamCatalog(credential);
        c.requireCurrent();
        if (result.steamId != c.library.steamAccountId) {
          throw const OAuthProxyException('Steam identity mismatch');
        }
        await c.saveSteamCatalog(
          steamId: result.steamId!,
          games: result.steamGames.map(SteamCatalogGame.fromJson).toList(),
          catalogAvailable: result.steamLibraryAvailable,
          catalogTruncated: result.steamCatalogTruncated,
        );
      } on SteamCatalogRelinkRequired {
        relink = true;
      } finally {
        proxy.dispose();
      }
    });
    if (relink && mounted && c.current) {
      await _linkSteamAccount();
    }
  }

  Future<void> _unlinkSteamAccount() async {
    final c = _controller;
    if (c == null || !c.current || c.busy) {
      return;
    }
    final confirmed = await showConfirmDialog(
      _actionContext,
      title: t.games.unlinkSteamAccount,
      message: t.games.unlinkSteamAccountConfirm,
      confirmText: t.games.unlinkSteamAccount,
      isDestructive: true,
    );
    if (confirmed && mounted && c == _controller) {
      await _run((active) async {
        final encrypted = active.catalogCredential;
        await active.unlinkSteamAccount();
        if (encrypted != null) {
          final proxy = OAuthProxyClient();
          try {
            final credential = await CredentialVault.reveal(encrypted);
            active.requireCurrent();
            if (credential != null) {
              await proxy.revokeSteamCatalog(credential);
            }
          } catch (_) {
            /* Local unlink succeeds offline; server grants expire. */
          } finally {
            proxy.dispose();
          }
        }
      });
    }
  }

  Future<void> _scan() async {
    final c = _controller;
    if (c == null || !c.current) {
      return;
    }
    try {
      await c.scan();
    } catch (_) {
      /* Manual entry remains available. */
    }
  }

  Future<void> _add() async {
    final c = _controller;
    final host = await showScopedDialog<GameHost>(
      context: _actionContext,
      builder: (_) => const AddGameComputerDialog(),
    );
    if (host == null || !mounted || c != _controller) {
      return;
    }
    if (!await _run((c) => c.saveHost(host))) {
      return;
    }
    if (mounted && c == _controller && PlatformDetector.supportsEmbeddedGameStreaming()) {
      await _connect(host);
    }
  }

  Future<void> _connect(GameHost host, {bool forcePair = false}) => _run((c) async {
    final capability = await c.client.capabilities(host);
    c.requireCurrent();
    if (!mounted) {
      return;
    }
    if (!capability.available || !capability.inlinePairing) {
      await _engineUnavailable(host);
      return;
    }
    final selected = host.protocol == GameProtocol.steam
        ? await identifySteamHost(host)
        : await identifyGameStreamHost(host);
    c.requireCurrent();
    if (selected.key != host.key) {
      await c.removeHost(host);
    }
    await c.saveHost(selected);
    // Already authorized computers open their library without another prompt.
    try {
      if (!forcePair) {
        await c.refreshGames(selected);
        return;
      }
    } on GameClientException catch (error) {
      if (error.failure != GameClientFailure.pairingRequired) {
        rethrow;
      }
    }
    c.requireCurrent();
    if (!mounted) {
      return;
    }
    final paired = await showScopedDialog<bool>(
      context: _actionContext,
      barrierDismissible: false,
      builder: (_) => PairGameComputerDialog(host: selected, client: c.client, isCurrent: () => c.current),
    );
    c.requireCurrent();
    if (paired == true) {
      await c.refreshGames(selected);
    }
  }).then<void>((_) {});
  Future<void> _open(GameHost host, StreamGame game) async {
    if (!PlatformDetector.supportsEmbeddedGameStreaming()) {
      await _engineUnavailable(host);
      return;
    }
    if (PlatformDetector.supportsEmbeddedGameStreaming() && host.protocol == GameProtocol.steam) {
      await _openInWorkspace(host, game, fullscreen: true);
      return;
    }
    await _run((c) async {
      final capability = await c.client.capabilities(host);
      c.requireCurrent();
      if (!capability.available) {
        await _engineUnavailable(host);
        return;
      }
      await PlaybackCoordinator.instance.claimVideo();
      await PlaybackCoordinator.instance.shutdownVideo();
      c.requireCurrent();
      await c.client.open(
        host,
        game: game,
        touchControls:
            !PlatformDetector.isTV() &&
            SettingsService.instance.read(SettingsService.gameTouchControlsForProfile(c.profileId)),
        pyrowave:
            host.protocol == GameProtocol.steam &&
            SettingsService.instance.read(SettingsService.gamePyrowaveForProfile(c.profileId)),
      );
      c.requireCurrent();
      // Opening an Activity is not evidence of a connected stream.
    });
  }

  Future<void> _openLibraryGame(
    LibraryGame game, {
    bool choose = false,
    bool mini = false,
    bool controllerOnly = false,
  }) async {
    final c = _controller;
    if (c == null || !c.current || c.busy) {
      return;
    }
    if (game.romm != null) {
      await _details(game);
      return;
    }
    if (!PlatformDetector.supportsEmbeddedGameStreaming()) {
      await _details(game);
      return;
    }
    final routes = controllerOnly
        ? game.routes.where((route) => route.host.protocol == GameProtocol.steam).toList()
        : game.routes;
    if (routes.isEmpty) {
      await _details(game);
      return;
    }
    var route = controllerOnly
        ? (routes.length == 1 ? routes.first : null)
        : (choose ? null : game.preferredRoute(c.library));
    route ??= await showScopedDialog<GameRoute>(
      context: _actionContext,
      builder: (dialogContext) => SimpleDialog(
        title: Text(t.games.chooseComputer),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(t.games.inventorySnapshotHelp),
          ),
          for (final choice in routes)
            GameComputerTile(
              route: choice,
              preferred: (c.library.routeSelections[game.key] ?? c.library.preferredRoutes[game.key]) == choice.key,
              onPlay: () => Navigator.pop(dialogContext, choice),
            ),
        ],
      ),
    );
    if (route == null || !mounted || !c.current) {
      return;
    }
    if (controllerOnly) {
      await _openInWorkspace(route.host, route.game, fullscreen: true, controllerOnly: true);
    } else if (mini) {
      await _openInWorkspace(route.host, route.game);
    } else {
      await _open(route.host, route.game);
    }
  }

  Future<T?> _page<T>(WidgetBuilder builder) async {
    final c = _controller;
    if (c == null || !c.current) {
      return null;
    }
    final ownership = Listenable.merge([
      _presentationRevision,
      context.read<ActiveProfileProvider>(),
      context.read<SourceController>(),
    ]);
    late MaterialPageRoute<T> route;
    route = MaterialPageRoute<T>(
      builder: (pageContext) {
        _pageContexts[route] = pageContext;
        return ListenableBuilder(
          listenable: ownership,
          builder: (_, _) => c.current ? builder(pageContext) : const SizedBox.shrink(),
        );
      },
    );
    _pages.add(route);
    try {
      return await Navigator.of(context).push(route);
    } finally {
      _pages.remove(route);
      _pageContexts.remove(route);
    }
  }

  Future<void> _details(LibraryGame initial) async {
    if (initial.romm != null) {
      final romm = _romm;
      if (romm != null && romm.current) {
        await rommPush<void>(
          context,
          romm,
          RommDetailScreen(controller: romm, game: initial.romm!),
          connectionId: initial.romm!.connectionId,
        );
      }
      return;
    }
    final c = _controller;
    if (c == null || !c.current) {
      return;
    }
    final activityIdentity = c.library.steamAccountId;
    final activityCredential = c.catalogCredential;
    final choice = await _page<Object>((pageContext) {
      final game = c.library.entries.where((g) => g.key == initial.key).firstOrNull;
      if (game == null) {
        return FocusedScrollScaffold(
          title: Text(t.games.gameDetails),
          slivers: [
            SliverToBoxAdapter(
              child: GameNotice(title: t.games.emptyLibraryTitle, message: t.games.emptyLibraryHelp),
            ),
          ],
        );
      }
      final enabled = !c.busy;
      return GameDetailScreen(
        canStream: PlatformDetector.supportsEmbeddedGameStreaming(),
        game: game,
        artwork: c.artwork,
        favorite: c.library.favoriteKeys.contains(game.key),
        preferredRouteKey: (c.library.routeSelections[game.key] ?? c.library.preferredRoutes[game.key]),
        onFavorite: enabled ? () => _run((c) => c.toggleLibraryFavorite(game)) : null,
        onPlay: enabled && PlatformDetector.supportsEmbeddedGameStreaming()
            ? () => Navigator.pop(pageContext, game.routes.isEmpty ? 'add' : 'play')
            : null,
        onChooseComputer: enabled && PlatformDetector.supportsEmbeddedGameStreaming()
            ? () => Navigator.pop(pageContext, 'choose')
            : null,
        onPlayRoute: enabled && PlatformDetector.supportsEmbeddedGameStreaming()
            ? (route) => Navigator.pop(pageContext, route)
            : null,
        onMiniPlayer:
            enabled &&
                PlatformDetector.supportsEmbeddedGameStreaming() &&
                game.routes.any((r) => r.host.protocol == GameProtocol.steam)
            ? () => Navigator.pop(pageContext, 'mini')
            : null,
        onUseAsController:
            enabled &&
                (Platform.isAndroid || Platform.isIOS) &&
                !PlatformDetector.isTV() &&
                game.routes.any((r) => r.host.protocol == GameProtocol.steam)
            ? () => Navigator.pop(pageContext, 'controller')
            : null,
        routeActions: (route) => _routeActions(game, route),
        activity: game.steamAppId == null
            ? null
            : SteamGameActivityPanel(
                appId: game.steamAppId!,
                steamId: activityIdentity,
                protectedCredential: activityCredential,
                isCurrent: () =>
                    c.current &&
                    c.library.steamAccountId == activityIdentity &&
                    c.catalogCredential == activityCredential,
                onLink: () => Navigator.pop(pageContext, 'link'),
              ),
        sessions: [
          for (final entry in _workspaceGameSessions.entries.where(
            (entry) => game.routes.any((route) => route.game.key == entry.value.game.key),
          ))
            FocusableListTile(
              leading: const AppIcon(Symbols.monitoring_rounded),
              title: Text(t.games.streamDetails),
              subtitle: Text(isolateDisplayText(entry.value.host.name)),
              onTap: () => Navigator.pop(pageContext, 'metrics:${entry.key}'),
            ),
        ],
      );
    });
    if (!mounted || !c.current) {
      return;
    }
    final game = c.library.entries.where((g) => g.key == initial.key).firstOrNull;
    if (game == null) {
      return;
    }
    if (choice is GameRoute && game.routes.any((r) => r.key == choice.key)) {
      await _open(choice.host, choice.game);
    }
    if (choice == 'play' || choice == 'choose' || choice == 'mini') {
      await _openLibraryGame(game, choose: choice == 'choose', mini: choice == 'mini');
    }
    if (choice == 'controller') {
      await _openLibraryGame(game, controllerOnly: true);
    }
    if (choice == 'add') {
      await _add();
    }
    if (choice == 'link') {
      await _linkSteamAccount();
    }
    if (choice is String && choice.startsWith('metrics:')) {
      final session = _workspaceGameSessions[choice.substring(8)];
      await session?.withInputSuspended(() async {
        if (!mounted || !c.current) {
          return;
        }
        await showScopedDialog<void>(
          context: context,
          builder: (_) => SteamStreamDiagnostics(readMetrics: session.readMetrics),
        );
      });
    }
  }

  Future<void> _openInWorkspace(
    GameHost host,
    StreamGame game, {
    bool fullscreen = false,
    bool controllerOnly = false,
  }) => _run((c) async {
    final capability = await c.client.capabilities(host);
    if (!mounted || !c.current) {
      return;
    }
    if (!capability.embeddedSurface ||
        host.protocol != GameProtocol.steam ||
        !PlatformDetector.supportsEmbeddedGameStreaming()) {
      await _engineUnavailable(host);
      return;
    }

    final workspace = context.read<MultiviewWorkspaceController>();
    _workspaceController = workspace;
    final sessionId = 'game:${game.key}${controllerOnly ? ':controller' : ''}';
    final existing = workspace.session(sessionId);
    if (existing != null) {
      workspace.showSessionInWorkspace(sessionId, fullscreen: fullscreen);
      workspace.focus(sessionId);
      return;
    }

    final settings = SettingsService.instance;
    final remote = context.read<CompanionRemoteProvider>();
    Future<SteamInternetTunnel?> connectInternet() async {
      if (!c.current || await steamHostReachable(host)) return null;
      c.requireCurrent();
      if (!settings.read(SettingsService.steamInternetForProfile(c.profileId))) return null;
      final inventory = c.library.inventories.where((entry) => entry.hostKey == host.key).firstOrNull;
      if (inventory == null) return null;
      return remote.openSteamInternet(inventory.peerId, isCurrent: () => c.current);
    }

    final tunnel = await connectInternet();
    if (!mounted || !c.current) {
      tunnel?.close();
      tunnel?.path.dispose();
      return;
    }
    final session = SteamGameWorkspaceSession(
      controllerOnly: controllerOnly,
      internetTunnel: tunnel,
      connectInternet: connectInternet,
      touchOpacity: settings.read(SettingsService.steamTouchOpacityForProfile(c.profileId)),
      swapTouchSides: settings.read(SettingsService.steamSwapTouchSidesForProfile(c.profileId)),
      controllerRumble: settings.read(SettingsService.steamControllerRumbleForProfile(c.profileId)),
      motionController: settings.read(SettingsService.steamMotionControllerForProfile(c.profileId)),
      inputProfile: SteamInputProfile.restore(settings.read(SettingsService.steamInputForGame(c.profileId, game.id))),
      persistInputProfile: (value) => settings.write(
        SettingsService.steamInputForGame(c.profileId, game.id),
        value.encode(),
        checkCurrent: c.requireCurrent,
      ),
      touchLayout: SteamTouchLayout.restore(
        settings.read(SettingsService.steamTouchLayoutForGame(c.profileId, game.id)),
      ),
      persistTouchLayout: (value) => settings.write(
        SettingsService.steamTouchLayoutForGame(c.profileId, game.id),
        value.encode(),
        checkCurrent: c.requireCurrent,
      ),
      onFirstFrame: () {
        if (c.current && game.id != '0') {
          unawaited(c.connected(GameRoute(host: host, game: game)).catchError((Object _) {}));
        }
      },
      pyrowave: SettingsService.instance.read(SettingsService.gamePyrowaveForProfile(c.profileId)),
      quality: SettingsService.instance.read(SettingsService.steamQualityForProfile(c.profileId)),
      codec: SettingsService.instance.read(SettingsService.steamCodecForProfile(c.profileId)),
      controllerCount: SettingsService.instance.read(SettingsService.steamControllerCountForProfile(c.profileId)),
      audio: SettingsService.instance.read(SettingsService.steamAudioForProfile(c.profileId)),
      host: host,
      game: game,
      touchControls:
          !PlatformDetector.isTV() &&
          SettingsService.instance.read(SettingsService.gameTouchControlsForProfile(c.profileId)),
    );
    final registration = WorkspaceSurfaceRegistration(
      descriptor: WorkspaceSessionDescriptor(
        id: sessionId,
        kind: MultiviewMediaKind.game,
        title: game.name,
        subtitle: host.name,
        mediaKey: game.key,
        hasAudio: true,
        hasVideo: true,
        acceptsInput: true,
        openedAt: DateTime.now(),
      ),
      buildSurface: (_) => session.workspaceSurface(),
      onRestore: () {
        workspace.showSessionInWorkspace(sessionId, fullscreen: true);
      },
      onClose: () {
        _workspaceGameSessions.remove(sessionId)?.dispose();
      },
      onAudioOwnershipChanged: session.setAudioEnabled,
      onInputOwnershipChanged: session.setInputEnabled,
    );

    if (!workspace.register(registration)) {
      session.dispose();
      showErrorSnackBar(context, t.videoControls.pipFailed);
      return;
    }
    _workspaceGameSessions[sessionId] = session;
    workspace.showSessionInWorkspace(sessionId, fullscreen: fullscreen);
  }).then<void>((_) {});
  Future<void> _engineUnavailable(GameHost host) async {
    if (!mounted) {
      return;
    }
    await showScopedDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.games.engineUnavailable),
        scrollable: true,
        content: Text(host.protocol == GameProtocol.steam ? t.games.steamEnginePending : t.games.nativeEnginePending),
        actions: [
          DialogActionButton(
            autofocus: InputModeTracker.isKeyboardMode(dialogContext, listen: false),
            onPressed: () => Navigator.pop(dialogContext),
            label: t.common.ok,
          ),
        ],
      ),
    );
  }

  Future<void> _showHelp() => showScopedDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(t.games.help),
      scrollable: true,
      content: Text(t.games.helpBody),
      actions: [
        DialogActionButton(
          autofocus: InputModeTracker.isKeyboardMode(dialogContext, listen: false),
          onPressed: () => Navigator.pop(dialogContext),
          label: t.common.ok,
        ),
      ],
    ),
  );

  Future<void> _importInventory(GameHost host) async {
    final c = _controller;
    if (c == null || !c.current) {
      return;
    }
    final remote = context.read<CompanionRemoteProvider>();
    final peerId = remote.gameInventoryPeerId;
    if (peerId == null || !remote.supportsGameInventory) {
      showErrorSnackBar(context, t.games.inventoryConnectHelp);
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: t.games.importInstalledGames,
      confirmText: t.games.importInstalledGames,
      message: t.games.inventoryConfirm(peer: remote.connectedDevice?.name ?? t.games.computers, computer: host.name),
    );
    if (!confirmed || !mounted || !c.current || remote.gameInventoryPeerId != peerId) {
      return;
    }
    await _run((c) async {
      try {
        final inventory = await remote.requestGameInventory();
        c.requireCurrent();
        if (remote.gameInventoryPeerId != peerId) {
          throw const SteamInventoryUnavailable();
        }
        await c.saveInventory(
          SteamHostInventory(
            hostKey: host.key,
            peerId: peerId,
            observedAt: DateTime.now(),
            games: inventory.games,
            complete: inventory.complete,
          ),
        );
        if (mounted && c.current) {
          showSuccessSnackBar(context, t.games.inventoryImported);
        }
      } on SteamInventoryUnavailable {
        if (mounted && c.current) {
          showErrorSnackBar(context, t.games.inventoryConnectHelp);
        }
      }
    });
  }

  Future<void> _chooseSteamFolder() async {
    final c = _controller;
    if (c == null || !c.current) {
      return;
    }
    final path = await FilePickerService.instance.getDirectoryPath(dialogTitle: t.games.steamInstallFolder);
    if (path == null || !mounted || !c.current) {
      return;
    }
    await SettingsService.instance.write(
      SettingsService.steamInstallRootForProfile(c.profileId),
      path,
      checkCurrent: c.requireCurrent,
    );
    if (mounted && c.current) {
      setState(() {});
    }
  }

  Future<void> _remoteHostAction(GameHost host, SteamHostAction action, {int? appId, LibraryGame? game}) async {
    final c = _controller;
    if (c == null || !c.current || c.busy) {
      return;
    }
    final remote = context.read<CompanionRemoteProvider>();
    final snapshot = c.library.inventories.where((i) => i.hostKey == host.key).firstOrNull;
    final peer = remote.gameActionPeerId;
    // A discovered name or matching IP cannot authorize a remote command.
    if (snapshot == null || peer == null || snapshot.peerId != peer || !remote.supportsGameAction(action)) {
      showErrorSnackBar(context, t.games.hostActionPairingHelp);
      return;
    }
    final label = switch (action) {
      SteamHostAction.launch => t.games.launchOnComputer,
      SteamHostAction.install => t.games.installOnComputer,
      SteamHostAction.library => t.games.hostLibrary,
      SteamHostAction.downloads => t.games.hostDownloads,
      SteamHostAction.inputConfiguration => t.games.inputOnComputer,
      SteamHostAction.properties => t.games.propertiesOnComputer,
    };
    final confirmed = action == SteamHostAction.install
        ? await showScopedDialog<bool>(
                context: context,
                builder: (_) => SteamLanInstallDialog(target: host, game: game, isCurrent: () => c.current),
              ) ==
              true
        : await showConfirmDialog(
            context,
            title: label,
            message: t.games.hostActionConfirm(computer: isolateDisplayText(host.name)),
            confirmText: label,
          );
    if (!confirmed || !mounted || !c.current || remote.gameActionPeerId != peer) {
      return;
    }
    await _run((c) async {
      final result = await remote.requestGameAction(action, appId: appId);
      if (!mounted || !c.current || remote.gameActionPeerId != peer) {
        return;
      }
      if (result == SteamHostActionResult.submitted) {
        showSuccessSnackBar(context, t.games.hostActionSubmitted);
      } else {
        showErrorSnackBar(
          context,
          result == SteamHostActionResult.denied ? t.games.hostActionDenied : t.games.unavailable,
        );
      }
    });
  }

  Future<void> _hostAction(String action, GameHost host) async {
    switch (action) {
      case 'hostLibrary':
        await _remoteHostAction(host, SteamHostAction.library);
      case 'hostDownloads':
        await _remoteHostAction(host, SteamHostAction.downloads);
      case 'inventory':
        await _importInventory(host);
      case 'library':
        await _open(host, StreamGame(hostKey: host.key, id: '0', name: t.games.steamLibrary));
      case 'pair':
        await _connect(host, forcePair: true);
      case 'refresh':
        await _run((c) => c.refreshGames(host));
      case 'wake':
        await _run((c) async {
          await wakeGameHost(host);
          if (mounted && c.current) {
            showSuccessSnackBar(context, t.games.wakeSent);
          }
        });
      case 'forget':
        final c = _controller;
        if (await showConfirmDialog(
              context,
              title: t.games.forget,
              message: t.games.forgetDescription,
              confirmText: t.games.forget,
              isDestructive: true,
            ) &&
            mounted &&
            c == _controller) {
          await _run((c) => c.removeHost(host));
        }
      case 'add':
        final c = _controller;
        final game = await showScopedDialog<StreamGame>(
          context: context,
          builder: (_) => AddGameShortcutDialog(host: host),
        );
        if (game != null && mounted && c == _controller) {
          await _run((c) => c.saveGame(game));
        }
    }
  }

  Widget _host(GameHost host) => FocusableListTile(
    leading: AppIcon(
      host.protocol == GameProtocol.steam ? Symbols.sports_esports_rounded : Symbols.desktop_windows_rounded,
    ),
    title: Text(isolateDisplayText(host.name)),
    subtitle: Text(
      '${isolateDisplayText(host.address)} · ${host.protocol == GameProtocol.steam ? t.games.steam : t.games.moonlight}',
    ),
    onTap: _controller!.busy ? null : () => _connect(host),
    trailing: AppMenuButton<String>(
      tooltip: t.games.computers,
      icon: const AppIcon(Symbols.more_vert_rounded),
      adaptiveSheet: true,
      enabled: !_controller!.busy,
      entriesBuilder: (_) => [
        if (host.protocol == GameProtocol.steam)
          AppMenuItem(value: 'inventory', label: t.games.importInstalledGames, icon: Symbols.download_rounded),
        if (host.protocol == GameProtocol.steam)
          AppMenuItem(value: 'library', label: t.games.steamLibrary, icon: Symbols.apps_rounded),
        if (host.protocol == GameProtocol.steam) ...[
          AppMenuItem(value: 'hostLibrary', label: t.games.hostLibrary, icon: Symbols.desktop_windows_rounded),
          AppMenuItem(value: 'hostDownloads', label: t.games.hostDownloads, icon: Symbols.download_rounded),
        ],
        AppMenuItem(value: 'pair', label: t.games.pair, icon: Symbols.link_rounded),
        AppMenuItem(value: 'refresh', label: t.games.refreshGames, icon: Symbols.refresh_rounded),
        AppMenuItem(value: 'add', label: t.games.addGame, icon: Symbols.add_rounded),
        if (host.mac != null) AppMenuItem(value: 'wake', label: t.games.wake, icon: Symbols.power_settings_new_rounded),
        AppMenuItem(value: 'forget', label: t.games.forget, icon: Symbols.delete_rounded, destructive: true),
      ],
      onSelected: (value) => _hostAction(value, host),
    ),
  );

  Widget _routeActions(LibraryGame game, GameRoute route) => AppMenuButton<SteamHostAction>(
    tooltip: t.games.computers,
    icon: const AppIcon(Symbols.more_vert_rounded),
    adaptiveSheet: true,
    enabled: _controller?.busy == false && route.host.protocol == GameProtocol.steam,
    entriesBuilder: (_) => [
      for (final item in <(SteamHostAction, String, IconData)>[
        (SteamHostAction.launch, t.games.launchOnComputer, Symbols.play_arrow_rounded),
        (SteamHostAction.install, t.games.installOnComputer, Symbols.download_rounded),
        (SteamHostAction.library, t.games.hostLibrary, Symbols.apps_rounded),
        (SteamHostAction.downloads, t.games.hostDownloads, Symbols.download_rounded),
        (SteamHostAction.inputConfiguration, t.games.inputOnComputer, Symbols.gamepad_rounded),
        (SteamHostAction.properties, t.games.propertiesOnComputer, Symbols.settings_rounded),
      ])
        if (context.read<CompanionRemoteProvider>().supportsGameAction(item.$1))
          AppMenuItem(value: item.$1, label: item.$2, icon: item.$3),
    ],
    onSelected: (action) => _remoteHostAction(route.host, action, appId: game.steamAppId, game: game),
  );

  Future<void> _computers() async {
    final c = _controller;
    if (c == null || !c.current) {
      return;
    }
    await _page<void>(
      (_) => FocusedScrollScaffold(
        title: Text(t.games.computers),
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(onPressed: c.busy ? null : _add, child: Text(t.games.addComputer)),
                    TextButton(onPressed: c.busy || c.scanning ? null : _scan, child: Text(t.games.findComputers)),
                    if (c.library.steamAccountId != null)
                      TextButton(
                        onPressed: c.busy ? null : _unlinkSteamAccount,
                        child: Text(t.games.unlinkSteamAccount),
                      ),
                  ],
                ),
                for (final host in c.library.hosts) _host(host),
                for (final host in c.nearby.where((h) => !c.library.hosts.any((saved) => saved.key == h.key)))
                  _host(host),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rommConnections() async {
    final romm = _romm;
    if (romm == null || !romm.current) {
      return;
    }
    await rommPush<void>(context, romm, RommConnectionsScreen(controller: romm));
  }

  Future<void> _rommLink([RommLink? supplied]) async {
    final romm = _romm;
    if (romm == null || !romm.current) {
      return;
    }
    RommLink? link = supplied;
    if (link == null) {
      final input = TextEditingController();
      try {
        final text = await rommDialog<String>(
          context: context,
          controller: romm,
          builder: (dialog) => AlertDialog(
            title: Text(rommText(dialog, 'openLink')),
            content: FocusableTextField(controller: input, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog), child: Text(t.common.cancel)),
              TextButton(onPressed: () => Navigator.pop(dialog, input.text), child: Text(t.common.confirm)),
            ],
          ),
        );
        if (text == null || !mounted || !romm.current) {
          return;
        }
        final uri = Uri.tryParse(text.trim());
        link = uri == null ? null : RommLink.parse(uri);
      } finally {
        input.dispose();
      }
    }
    if (link == null || !mounted || !romm.current) {
      return;
    }
    final source = romm.connections.where((entry) => entry.base == link!.server).firstOrNull;
    if (source == null) {
      await _rommConnections();
      return;
    }
    try {
      var game = romm.visibleGames.where((game) => game.connectionId == source.id && link!.matches(game)).firstOrNull;
      if (game == null && link.romId > 0) {
        game = await romm.detail(RommGame.fromJson(source.id, {'id': link.romId}));
      }
      if (!mounted || !romm.current || game == null || !link.matches(game)) {
        return;
      }
      await _details(LibraryGame(key: game.key, name: game.name, routes: const [], romm: game));
    } catch (_) {
      if (mounted && romm.current) {
        showErrorSnackBar(context, rommText(context, 'connectionFailed'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadFailed) {
      return FocusedScrollScaffold(
        title: Text(t.games.title),
        automaticallyImplyLeading: false,
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorStateWidget(
              message: t.errors.unableToLoad(context: t.games.title),
              onRetry: _retryLoad,
              actionAutofocus: PlatformDetector.isTV(),
            ),
          ),
        ],
      );
    }
    final c = _controller, romm = _romm;
    if (c == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final roms = romm?.visibleGames ?? const <RommGame>[];
    return GameLibraryView(
      library: c.library,
      artwork: c.artwork,
      firstFocus: _firstFocus,
      loading: _loading,
      busy: c.busy,
      available: c.current,
      canStream: PlatformDetector.supportsEmbeddedGameStreaming(),
      onConnections: _computers,
      onSettings: () =>
          _page<void>((_) => GameSettingsScreen(profileId: c.profileId, onChooseFolder: _chooseSteamFolder)),
      onHelp: _showHelp,
      onLink: _linkSteamAccount,
      onRefresh: () {
        unawaited(_refreshSteamAccount());
        if (romm != null && romm.current) {
          unawaited(romm.refresh());
        }
      },
      onPlay: _openLibraryGame,
      onDetails: _details,
      onFavorite: (game) {
        if (game.romm != null && romm != null) {
          unawaited(romm.favorite(game.romm!));
        } else {
          unawaited(_run((c) => c.toggleLibraryFavorite(game)));
        }
      },
      onMiniPlayer: (game) => _openLibraryGame(game, mini: true),
      onUseAsController: (game) => _openLibraryGame(game, controllerOnly: true),
      additionalGames: [
        for (final game in roms) LibraryGame(key: game.key, name: game.name, routes: const [], romm: game),
      ],
      additionalFavorites: romm?.favorites ?? const {},
      additionalRecent: romm?.recent ?? const [],
      additionalInstalled: {
        if (romm != null)
          for (final game in roms)
            if (romm.storage.available(game)) game.key,
      },
      sourceFilters: romm == null
          ? null
          : RommLibraryFilters(controller: romm, onConnections: _rommConnections, onLink: _rommLink),
      onSearchChanged: (query) {
        _rommSearch?.cancel();
        _rommSearch = Timer(const Duration(milliseconds: 250), () {
          if (romm != null && romm.current) {
            unawaited(
              romm.refresh(
                changeFilter: true,
                search: query,
                connectionId: romm.source,
                platform: romm.platformId,
                list: romm.collection,
              ),
            );
          }
        });
      },
      catalogNotices: [
        if (_rommLoadError) GameNotice(title: t.games.title, message: rommText(context, 'connectionFailed')),
      ],
      additionalCardBuilder: (entry, focus) {
        final game = entry.romm!;
        return GameCard(
          key: ValueKey(game.key),
          game: StreamGame(hostKey: game.connectionId, id: game.id.toString(), name: game.name),
          artwork: c.artwork,
          favorite: romm!.favorites.contains(game.key),
          focusNode: focus,
          subtitle: game.platformName,
          loadCover: () => romm.cover(game),
          playLabel: t.games.gameDetails,
          onPlay: () => _details(entry),
          onDetails: () => _details(entry),
          onFavorite: () => romm.favorite(game),
        );
      },
    );
  }
}
