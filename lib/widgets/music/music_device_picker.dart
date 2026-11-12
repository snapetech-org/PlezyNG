import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../providers/companion_remote_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/base_peer_service.dart';
import '../../services/cast_media_service.dart';
import '../../services/companion_remote/companion_remote_host_controller.dart';
import '../../services/companion_remote/remote_pairing_store.dart';
import '../../services/music/music_device_controller.dart';
import '../../services/music/music_device_link.dart';
import '../../services/music/music_playback_output.dart';
import '../../services/music/music_playback_service.dart';
import '../../utils/dialogs.dart';
import '../app_icon.dart';
import '../companion_remote/remote_pairing_dialog.dart';
import '../companion_remote/remote_session_dialog.dart';
import '../dialog_action_button.dart';
import '../focusable_list_tile.dart';

Future<void> showMusicDevicePicker(BuildContext context) async {
  await showScopedDialog<void>(context: context, builder: (_) => const MusicDevicePicker());
}

Future<void> showPlaybackReceiverSettings(BuildContext context) async {
  await showScopedDialog<void>(context: context, builder: (_) => const MusicDevicePicker._receiverSettings());
}

class MusicDeviceButton extends StatelessWidget {
  const MusicDeviceButton({super.key});

  @override
  Widget build(BuildContext context) {
    final companion = context.watch<CompanionRemoteProvider?>();
    if (companion == null) return const SizedBox.shrink();
    final music = context.watch<MusicPlaybackService>();
    if (music.currentTrack == null) return const SizedBox.shrink();
    final output = music is MusicOutputControls ? music as MusicOutputControls : null;
    final name = companion.musicDevices?.active?.name ?? output?.remoteOutputName;
    final label = name == null ? t.musicDevices.playOn : t.musicDevices.playingOn(device: name);
    void open() => unawaited(showMusicDevicePicker(context));
    return FocusableButton(
      autoScroll: false,
      onPressed: open,
      child: IconButton(
        tooltip: label,
        icon: AppIcon(
          Symbols.speaker_group_rounded,
          color: name == null ? null : Theme.of(context).colorScheme.primary,
        ),
        onPressed: open,
      ),
    );
  }
}

class MusicDevicePicker extends StatefulWidget {
  const MusicDevicePicker({super.key}) : receiverSettings = false;
  const MusicDevicePicker._receiverSettings() : receiverSettings = true;

  final bool receiverSettings;

  @override
  State<MusicDevicePicker> createState() => _MusicDevicePickerState();
}

class _MusicDevicePickerState extends State<MusicDevicePicker> {
  late final CompanionRemoteProvider _companion;
  final _address = TextEditingController();
  final _relay = TextEditingController();
  StreamSubscription<List<DiscoveredHost>>? _discovery;
  List<DiscoveredHost> _nearby = const [];
  List<DiscoveredHost> _remembered = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _companion = context.read<CompanionRemoteProvider>();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      if (!_companion.isCryptoReady) await ensureCompanionRemoteCryptoFromContext(context);
      if (widget.receiverSettings) {
        await _companion.loadMusicRelayConfiguration();
        if (!mounted) return;
        _relay.text = _companion.musicRelayUrl;
        setState(() => _loading = false);
        return;
      }
      final remembered = await _companion.rememberedMusicDevices();
      if (!mounted) return;
      _discovery = _companion.discoverMusicDevices()?.listen((devices) {
        if (mounted) setState(() => _nearby = devices);
      });
      setState(() {
        _remembered = remembered;
        _loading = false;
        if (!_companion.isCryptoReady) _error = t.musicDevices.moveFailed;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = t.musicDevices.moveFailed;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = t.musicDevices.moveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _move(MusicDeviceLink? target) async {
    final music = context.read<MusicPlaybackService>();
    if (music.currentTrack == null) return;
    if (target == null && music is MusicOutputControls && _companion.musicDevices?.active == null) {
      final outputs = music as MusicOutputControls;
      if (outputs.remoteOutputName != null && !await outputs.selectOutput(null)) {
        throw StateError('Local audio output unavailable');
      }
    }
    final result = await _companion.playMusicOn(target);
    if (!mounted) return;
    setState(
      () => _error = switch (result) {
        MusicDeviceMoveResult.completed => null,
        MusicDeviceMoveResult.rejected => t.musicDevices.moveFailed,
        MusicDeviceMoveResult.uncertain => t.musicDevices.uncertain,
      },
    );
  }

  Future<void> _connect(Future<MusicDeviceLink> Function(String? code) connect) async {
    MusicDeviceLink target;
    try {
      target = await connect(null);
    } catch (error) {
      if (error is! RemotePairingRequired && !(error is PeerError && error.type == PeerErrorType.authFailed)) {
        rethrow;
      }
      if (!mounted) return;
      final code = await RemotePairingDialog.show(context);
      if (code == null || !mounted) return;
      target = await connect(code);
    }
    final remembered = await _companion.rememberedMusicDevices();
    if (!mounted) return;
    setState(() => _remembered = remembered);
    await _move(target);
  }

  Future<void> _forget(DiscoveredHost host) => _run(() async {
    await _companion.forgetMusicDevice(host);
    final devices = await _companion.rememberedMusicDevices();
    if (mounted) setState(() => _remembered = devices);
  });

  Future<void> _configureRelay(bool enabled) => _run(() async {
    try {
      await _companion.configureMusicRelay(_relay.text.trim(), enabled);
    } catch (_) {
      if (mounted) setState(() => _error = t.musicDevices.relayInvalid);
    }
  });

  Future<void> _cast() => _run(() async {
    final music = context.read<MusicPlaybackService>();
    if (music is! MusicOutputControls || music.currentTrack == null) return;
    final receiver = await CastMediaService.instance.connectMusicOutput(
      context,
      context.read<MultiServerProvider>().serverManager,
    );
    if (receiver == null) return;
    if (!mounted ||
        music.currentTrack == null ||
        (_companion.musicDevices?.active != null &&
            await _companion.playMusicOn(null) != MusicDeviceMoveResult.completed)) {
      await receiver.player.dispose();
      return;
    }
    _companion.leaveMusicGroup();
    if (!await (music as MusicOutputControls).selectOutput(receiver)) {
      throw StateError('Cast receiver unavailable');
    }
  });

  @override
  void dispose() {
    _discovery?.cancel();
    if (!widget.receiverSettings) _companion.stopMusicDiscovery();
    _address.dispose();
    _relay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final companion = context.watch<CompanionRemoteProvider>();
    final music = widget.receiverSettings ? null : context.watch<MusicPlaybackService>();
    final active = companion.musicDevices?.active;
    final outputs = music is MusicOutputControls ? music as MusicOutputControls : null;
    final activeName = active?.name ?? outputs?.remoteOutputName;
    final busy = _busy || companion.musicDeviceBusy;
    final ids = _nearby.map((host) => '${host.authContextId}:${host.clientId}').toSet();
    final remembered = _remembered.where((host) => !ids.contains('${host.authContextId}:${host.clientId}'));
    final paired = companion.pairedMusicDevice;
    return AlertDialog(
      title: Text(widget.receiverSettings ? t.musicDevices.receive : t.musicDevices.playOn),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.65),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (busy || _loading) const LinearProgressIndicator(),
                if (!widget.receiverSettings) ...[
                  if (activeName != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(t.musicDevices.playingOn(device: activeName)),
                    ),
                  if (active != null && !active.connected)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Semantics(liveRegion: true, child: Text(t.companionRemote.remote.reconnecting)),
                    ),
                  FocusableListTile(
                    autofocus: true,
                    selected: activeName == null,
                    enabled: !busy,
                    leading: const AppIcon(Symbols.devices_rounded),
                    title: Text(t.musicDevices.thisDevice),
                    trailing: activeName == null ? const AppIcon(Symbols.check_rounded) : null,
                    onTap: () => unawaited(_run(() => _move(null))),
                  ),
                  if (paired != null && paired.connected)
                    FocusableListTile(
                      enabled: !busy,
                      selected: identical(active, paired),
                      leading: const AppIcon(Symbols.speaker_rounded),
                      title: Text(paired.name),
                      onTap: () => unawaited(_run(() => _move(paired))),
                    ),
                  if (_nearby.isNotEmpty) _heading(t.companionRemote.pairing.availableDevices),
                  for (final host in _nearby) _device(host, busy),
                  if (remembered.isNotEmpty) _heading(t.musicDevices.remembered),
                  for (final host in remembered) _device(host, busy),
                  if (!_loading && _nearby.isEmpty && remembered.isEmpty && paired?.connected != true)
                    ListTile(
                      title: Text(t.companionRemote.pairing.noDevicesFound),
                      subtitle: Text('${t.settings.title} → ${t.musicDevices.receive}'),
                    ),
                  if (CastMediaService.isSupportedPlatform && outputs != null)
                    FocusableListTile(
                      enabled: !busy,
                      leading: const AppIcon(Symbols.cast_rounded),
                      title: Text(t.cast.chooseDevice),
                      onTap: _cast,
                    ),
                  ExpansionTile(
                    title: Text(t.companionRemote.pairing.manualConnection),
                    children: [
                      FocusableTextField(
                        controller: _address,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: t.companionRemote.session.hostAddress,
                          hintText: t.companionRemote.pairing.hostAddressHint,
                        ),
                        onSubmitted: (_) {
                          if (!busy) {
                            unawaited(
                              _run(
                                () => _connect(
                                  (code) => companion.connectMusicAddress(_address.text.trim(), pairingCode: code),
                                ),
                              ),
                            );
                          }
                        },
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => unawaited(
                                _run(
                                  () => _connect(
                                    (code) => companion.connectMusicAddress(_address.text.trim(), pairingCode: code),
                                  ),
                                ),
                              ),
                        child: Text(t.common.connect),
                      ),
                    ],
                  ),
                ] else ...[
                  FocusableListTile(
                    enabled: !busy,
                    leading: const AppIcon(Symbols.devices_rounded),
                    title: Text(t.companionRemote.title),
                    subtitle: Text(t.musicDevices.receiverHint),
                    onTap: () => unawaited(RemoteSessionDialog.show(context)),
                  ),
                  ExpansionTile(
                    title: Text(t.musicDevices.away),
                    children: [
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.musicDevices.relayHint)),
                      FocusableTextField(
                        controller: _relay,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(labelText: t.musicDevices.relay, hintText: 'https://music.example'),
                      ),
                      FocusableListTile(
                        enabled: !busy,
                        title: Text(t.musicDevices.away),
                        subtitle: companion.musicRelayEnabled
                            ? Text(
                                companion.musicRelayConnected
                                    ? t.companionRemote.session.connected
                                    : t.companionRemote.remote.reconnecting,
                              )
                            : null,
                        trailing: Switch(
                          value: companion.musicRelayEnabled,
                          onChanged: busy ? null : (enabled) => unawaited(_configureRelay(enabled)),
                        ),
                        onTap: () => unawaited(_configureRelay(!companion.musicRelayEnabled)),
                      ),
                      TextButton(
                        onPressed: busy ? null : () => unawaited(_configureRelay(companion.musicRelayEnabled)),
                        child: Text(t.common.save),
                      ),
                    ],
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [DialogActionButton(onPressed: () => Navigator.of(context).pop(), label: t.common.close)],
    );
  }

  Widget _heading(String label) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _device(DiscoveredHost host, bool busy) => FocusableListTile(
    enabled: !busy,
    leading: const AppIcon(Symbols.speaker_rounded),
    title: Text(host.name),
    subtitle: Text(host.platform),
    trailing: IconButton(
      tooltip: t.musicDevices.forget,
      icon: const AppIcon(Symbols.close_rounded),
      onPressed: busy ? null : () => unawaited(_forget(host)),
    ),
    onTap: () => unawaited(_run(() => _connect((code) => _companion.connectMusicDevice(host, pairingCode: code)))),
  );
}
