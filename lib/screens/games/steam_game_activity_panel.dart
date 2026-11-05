import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../focus/focusable_button.dart';
import '../../games/steam_game_activity.dart';
import '../../games/steam_cloud_client.dart';
import '../../games/steam_families_client.dart';
import 'steam_cloud_dialog.dart';
import 'steam_families_dialog.dart';
import '../../i18n/presentation_formats.dart';
import '../../i18n/strings.g.dart';
import '../../services/credential_vault.dart';
import '../../services/trackers/oauth_proxy_client.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/focusable_list_tile.dart';

/// Metadata is fetched on demand and lives only for this profile's detail view.
/// No webview, upstream HTML, arbitrary image URL or unsolicited social lookup.
class SteamGameActivityPanel extends StatefulWidget {
  const SteamGameActivityPanel({
    super.key,
    required this.appId,
    required this.isCurrent,
    required this.onLink,
    this.steamId,
    this.protectedCredential,
  });
  final int appId;
  final String? steamId, protectedCredential;
  final bool Function() isCurrent;
  final VoidCallback onLink;
  @override
  State<SteamGameActivityPanel> createState() => _SteamGameActivityPanelState();
}

class _SteamGameActivityPanelState extends State<SteamGameActivityPanel> {
  final _proxy = OAuthProxyClient();
  final _retired = Completer<void>();
  SteamCloudClient? _cloudClient;
  SteamFamiliesClient? _familiesClient;
  bool _familiesLoading = false;
  bool _cloudLoading = false;
  SteamGameActivity? _activity;
  bool _loading = false, _failed = false, _relink = false, _friends = false;
  int _visible = 20;
  bool get current => mounted && widget.isCurrent();
  @override
  void dispose() {
    _proxy.dispose();
    if (!_retired.isCompleted) _retired.complete();
    unawaited(_cloudClient?.retire());
    unawaited(_familiesClient?.retire());
    super.dispose();
  }

  Future<void> _load() async {
    if (!current || _loading) return;
    final encrypted = widget.protectedCredential, id = widget.steamId;
    if (encrypted == null || id == null) {
      widget.onLink();
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _relink = false;
    });
    try {
      final credential = await CredentialVault.reveal(encrypted);
      if (!current) return;
      if (credential == null) throw const SteamCatalogRelinkRequired();
      final activity = await _proxy.steamGameActivity(
        credential,
        appId: widget.appId,
        steamId: id,
        includeFriends: _friends,
      );
      if (current) setState(() => _activity = activity);
    } on SteamCatalogRelinkRequired {
      if (current) setState(() => _relink = true);
    } catch (_) {
      if (current) setState(() => _failed = true);
    } finally {
      if (current) setState(() => _loading = false);
    }
  }

  Future<void> _cloud() async {
    if (!current || _cloudLoading) return;
    final encrypted = widget.protectedCredential, steamId = widget.steamId;
    if (encrypted == null || steamId == null) {
      widget.onLink();
      return;
    }
    setState(() => _cloudLoading = true);
    final client = SteamCloudClient();
    _cloudClient = client;
    try {
      final catalog = await CredentialVault.reveal(encrypted);
      if (!current) return;
      if (catalog == null) {
        widget.onLink();
        return;
      }
      final capabilities = await client.capabilities(catalog, widget.appId);
      if (!current) return;
      if (!capabilities.read) {
        await _open(SteamDestination.cloudFiles);
        return;
      }
      if (!mounted) return;
      await showScopedDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SteamCloudDialog(
          client: client,
          capabilities: capabilities,
          catalog: catalog,
          appId: widget.appId,
          steamId: steamId,
          isCurrent: () => current,
          retired: _retired.future,
        ),
      );
    } catch (_) {
      if (mounted && current) showErrorSnackBar(context, t.games.unavailable);
    } finally {
      await client.retire();
      if (identical(_cloudClient, client)) _cloudClient = null;
      if (current) setState(() => _cloudLoading = false);
    }
  }

  Future<void> _families() async {
    if (!current || _familiesLoading) return;
    final encrypted = widget.protectedCredential, id = widget.steamId;
    if (encrypted == null || id == null) {
      widget.onLink();
      return;
    }
    setState(() => _familiesLoading = true);
    SteamFamiliesClient? client;
    try {
      final catalog = await CredentialVault.reveal(encrypted);
      if (!current) return;
      if (catalog == null) {
        widget.onLink();
        return;
      }
      client = SteamFamiliesClient(catalog: catalog, steamId: id);
      _familiesClient = client;
      final available = await client.available();
      if (!current) return;
      if (!available) {
        await _open(SteamDestination.families);
        return;
      }
      if (!mounted) return;
      final activeClient = client;
      await showScopedDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SteamFamiliesDialog(
          client: activeClient,
          appId: widget.appId,
          isCurrent: () => current,
          retired: _retired.future,
        ),
      );
    } catch (_) {
      if (mounted && current) showErrorSnackBar(context, t.games.unavailable);
    } finally {
      await client?.retire();
      if (identical(_familiesClient, client)) _familiesClient = null;
      if (current) setState(() => _familiesLoading = false);
    }
  }

  Future<void> _open(SteamDestination destination) async {
    final uri = steamDestination(widget.appId, destination);
    final confirmed = await showConfirmDialog(
      context,
      title: t.games.openSteamPage,
      message: switch (destination) {
        SteamDestination.cloudFiles => t.games.steamCloudHelp,
        SteamDestination.families => t.games.steamFamiliesHelp,
        _ => t.games.openSteamPageHelp,
      },
      confirmText: t.games.openSteamPage,
    );
    if (!confirmed || !current) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted && widget.isCurrent()) {
        showErrorSnackBar(context, t.games.unavailable);
      }
    } catch (_) {
      if (mounted && widget.isCurrent()) showErrorSnackBar(context, t.games.unavailable);
    }
  }

  Widget _button(String label, VoidCallback? action, {IconData? icon}) => FocusableButton(
    onPressed: action,
    child: TextButton.icon(onPressed: action, icon: AppIcon(icon ?? Symbols.refresh_rounded), label: Text(label)),
  );

  @override
  Widget build(BuildContext context) {
    final data = _activity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Semantics(header: true, child: Text(t.games.steamActivity, style: Theme.of(context).textTheme.titleLarge)),
        const SizedBox(height: 8),
        Text(t.games.steamActivityPrivacy),
        FocusableSwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.games.includeFriends),
          subtitle: Text(t.games.includeFriendsHelp),
          value: _friends,
          onChanged: _loading
              ? null
              : (value) => setState(() {
                  _friends = value;
                  // Turning social context off immediately hides its current snapshot.
                }),
        ),
        if (_loading) Semantics(liveRegion: true, child: Text(t.games.activityLoading)),
        if (_failed) Text(t.games.activityUnavailable),
        _button(
          _relink || widget.protectedCredential == null ? t.games.linkSteamAccount : t.games.loadSteamActivity,
          _loading ? null : (_relink ? widget.onLink : _load),
          icon: _relink || widget.protectedCredential == null ? Symbols.link_rounded : Symbols.refresh_rounded,
        ),
        if (data != null) ...[
          ExpansionTile(
            leading: const AppIcon(Symbols.emoji_events_rounded),
            title: Text(t.games.achievements),
            subtitle: Text(
              data.achievementsAvailable
                  ? t.games.achievementProgress(
                      unlocked: data.achievements.where((a) => a.unlocked).length,
                      total: data.achievements.length,
                    )
                  : t.games.activityPrivate,
            ),
            children: [
              if (data.achievementsAvailable) ...[
                for (final achievement in data.achievements.take(_visible))
                  ListTile(
                    leading: AppIcon(achievement.unlocked ? Symbols.emoji_events_rounded : Symbols.lock_rounded),
                    title: Text(achievement.hidden ? t.games.hiddenAchievement : isolateDisplayText(achievement.name)),
                    subtitle: Text(
                      '${achievement.unlocked ? t.games.achievementUnlocked : t.games.achievementLocked}\n'
                      '${achievement.hidden ? t.games.hiddenAchievementHelp : isolateDisplayText(achievement.description)}',
                    ),
                  ),
                if (_visible < data.achievements.length)
                  _button(
                    t.games.moreAchievements,
                    () => setState(() => _visible += 20),
                    icon: Symbols.expand_more_rounded,
                  ),
              ],
            ],
          ),
          ExpansionTile(
            leading: const AppIcon(Symbols.newspaper_rounded),
            title: Text(t.games.gameNews),
            children: [
              if (!data.newsAvailable)
                Padding(padding: const EdgeInsets.all(16), child: Text(t.games.activityUnavailable))
              else if (data.news.isEmpty)
                Padding(padding: const EdgeInsets.all(16), child: Text(t.games.noGameNews))
              else
                for (final news in data.news)
                  FocusableListTile(
                    title: Text(isolateDisplayText(news.title)),
                    subtitle: Text(
                      '${isolateDisplayText(news.feed)} · ${MaterialLocalizations.of(context).formatCompactDate(news.date.toLocal())}',
                    ),
                    trailing: const AppIcon(Symbols.open_in_new_rounded),
                    onTap: () => _open(SteamDestination.news),
                  ),
            ],
          ),
          if (_friends && data.friendsRequested)
            ExpansionTile(
              leading: const AppIcon(Symbols.people_rounded),
              title: Text(t.games.friendsPlaying),
              children: [
                if (!data.friendsAvailable)
                  Padding(padding: const EdgeInsets.all(16), child: Text(t.games.activityPrivate))
                else if (data.friends.isEmpty)
                  Padding(padding: const EdgeInsets.all(16), child: Text(t.games.noFriendsPlaying))
                else
                  for (final friend in data.friends)
                    ListTile(
                      leading: const AppIcon(Symbols.person_rounded),
                      title: Text(isolateDisplayText(friend.name)),
                    ),
              ],
            ),
          if (data.truncated) Text(t.games.activityTruncated),
        ],
        if (widget.steamId != null && widget.protectedCredential != null)
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _button(t.games.steamCloudFiles, _cloudLoading ? null : _cloud, icon: Symbols.cloud_rounded),
              _button(
                t.games.steamFamilies,
                _familiesLoading ? null : _families,
                icon: Symbols.family_restroom_rounded,
              ),
            ],
          ),
        AppMenuButton<SteamDestination>(
          tooltip: t.games.openInSteam,
          adaptiveSheet: true,
          entriesBuilder: (_) => [
            AppMenuItem(value: SteamDestination.store, label: t.games.steamStore, icon: Symbols.storefront_rounded),
            AppMenuItem(value: SteamDestination.community, label: t.games.steamCommunity, icon: Symbols.forum_rounded),
            AppMenuItem(
              value: SteamDestination.workshop,
              label: t.games.steamWorkshop,
              icon: Symbols.extension_rounded,
            ),
            AppMenuItem(value: SteamDestination.news, label: t.games.gameNews, icon: Symbols.newspaper_rounded),
            const AppMenuDivider(),
            AppMenuItem(
              value: SteamDestination.cloudFiles,
              label: t.games.steamCloudFiles,
              icon: Symbols.cloud_rounded,
            ),
            AppMenuItem(
              value: SteamDestination.families,
              label: t.games.steamFamilies,
              icon: Symbols.family_restroom_rounded,
            ),
          ],
          onSelected: _open,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(t.games.openInSteam)),
                const SizedBox(width: 8),
                const AppIcon(Symbols.expand_more_rounded, size: 18),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
