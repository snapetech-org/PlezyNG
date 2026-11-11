import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/base_peer_service.dart';
import '../../services/companion_remote/remote_pairing_store.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/companion_remote/discovery_view.dart';
import '../../widgets/companion_remote/remote_pairing_dialog.dart';
import '../../profiles/active_profile_provider.dart';
import 'caldera_group_screen.dart';

class MusicGroupScreen extends StatefulWidget {
  const MusicGroupScreen({super.key});

  @override
  State<MusicGroupScreen> createState() => _MusicGroupScreenState();
}

class _MusicGroupScreenState extends State<MusicGroupScreen> {
  late final CompanionRemoteProvider _remote = context.read<CompanionRemoteProvider>();
  StreamSubscription<List<DiscoveredHost>>? _discovery;
  List<DiscoveredHost> _hosts = [];
  final Set<String> _busy = {};
  bool _ownsDiscovery = false;
  bool _primaryBusy = false;

  @override
  void initState() {
    super.initState();
    _ownsDiscovery = !_remote.isDiscoveringHosts;
    _discovery = _remote.discoverHosts()?.listen(
      (hosts) {
        if (mounted) setState(() => _hosts = hosts);
      },
      onError: (Object _) {
        if (mounted) showErrorSnackBar(context, t.musicExperience.error);
      },
    );
  }

  String _key(DiscoveredHost host) => '${host.authContextId}:${host.clientId}';

  Future<void> _add(DiscoveredHost host) async {
    final key = _key(host);
    if (!_busy.add(key)) return;
    setState(() {});
    try {
      bool joined;
      try {
        joined = await _remote.addMusicGroupEndpoint(host);
      } catch (error) {
        final needsCode =
            error is RemotePairingRequired || (error is PeerError && error.type == PeerErrorType.authFailed);
        if (!needsCode || !mounted) rethrow;
        final code = await RemotePairingDialog.show(context);
        if (code == null || !mounted) return;
        joined = await _remote.addMusicGroupEndpoint(host, pairingCode: code);
      }
      if (mounted && !joined) showErrorSnackBar(context, t.musicExperience.error);
    } catch (error) {
      if (mounted) showErrorSnackBar(context, companionRemotePairingErrorMessage(error));
    } finally {
      _busy.remove(key);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    unawaited(_discovery?.cancel());
    if (_ownsDiscovery) _remote.stopDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = context.watch<CompanionRemoteProvider>();
    final endpoints = remote.musicGroupEndpoints;
    final selected = endpoints.map(_key).toSet();
    final available = _hosts.where((host) => !selected.contains(_key(host)) && !remote.isOwnMusicEndpoint(host));
    return Scaffold(
      appBar: AppBar(
        title: Text(t.homeLayout.sync),
        actions: [
          if (remote.musicGroupActive)
            IconButton(
              tooltip: t.common.cancel,
              icon: const AppIcon(Symbols.stop_circle_rounded),
              onPressed: remote.leaveMusicGroup,
            ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const AppIcon(Symbols.speaker_group_rounded),
            title: const Text('Caldera / Plexamp'),
            subtitle: Text(t.homeLayout.sync),
            onTap: () {
              final active = context.read<ActiveProfileProvider>();
              final profile = active.activeId;
              unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CalderaGroupScreen(current: () => profile != null && active.activeId == profile),
                  ),
                ),
              );
            },
          ),
          if (remote.supportsMusicGroup)
            ListTile(
              leading: const AppIcon(Symbols.speaker_group_rounded),
              title: Text(remote.connectedDevice?.name ?? t.companionRemote.unknownDevice),
              subtitle: Text(
                remote.primaryMusicGroupActive ? t.watchTogether.connected : t.companionRemote.pairing.availableDevices,
              ),
              trailing: _primaryBusy ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator()) : null,
              onTap: _primaryBusy
                  ? null
                  : () async {
                      if (remote.primaryMusicGroupActive) {
                        remote.leavePrimaryMusicGroup();
                        return;
                      }
                      setState(() => _primaryBusy = true);
                      try {
                        final joined = await remote.startMusicGroup();
                        if (context.mounted && !joined) showErrorSnackBar(context, t.musicExperience.error);
                      } finally {
                        if (mounted) setState(() => _primaryBusy = false);
                      }
                    },
            ),
          for (final host in endpoints)
            ListTile(
              key: ValueKey('joined:${_key(host)}'),
              leading: const AppIcon(Symbols.speaker_rounded),
              title: Text(host.name),
              subtitle: Text(
                remote.musicGroupEndpointJoined(host)
                    ? t.watchTogether.connected
                    : t.companionRemote.pairing.connecting,
              ),
              trailing: IconButton(
                tooltip: t.common.cancel,
                icon: const AppIcon(Symbols.remove_circle_rounded),
                onPressed: () => remote.removeMusicGroupEndpoint(host),
              ),
            ),
          Padding(padding: const EdgeInsets.all(16), child: Text(t.companionRemote.pairing.availableDevices)),
          if (available.isEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text(t.companionRemote.pairing.noDevicesFound)),
          for (final host in available)
            ListTile(
              key: ValueKey('available:${_key(host)}'),
              leading: const AppIcon(Symbols.speaker_group_rounded),
              title: Text(host.name),
              subtitle: Text(host.platform),
              trailing: _busy.contains(_key(host))
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator())
                  : const AppIcon(Symbols.add_circle_rounded),
              onTap: remote.canManageMusicGroups && !_busy.contains(_key(host)) ? () => _add(host) : null,
            ),
        ],
      ),
    );
  }
}
