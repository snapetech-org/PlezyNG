import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/caldera_group.dart';
import '../../services/music/caldera_audio_sink.dart';
import '../../services/music/caldera_audio_source.dart';
import '../../services/music/caldera_native_host.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';

/// Native players retain the audio, queue and synchronization clock. Selection
/// here requests membership; it does not claim to measure acoustic sync.
class CalderaGroupScreen extends StatefulWidget {
  const CalderaGroupScreen({
    super.key,
    required this.current,
    this.audio,
    this.discoveryFactory = CalderaDiscovery.new,
    this.clientFactory = CalderaGroupClient.new,
  });
  final bool Function() current;
  final NativeMusicGroupControls? audio;
  final CalderaDiscovery Function() discoveryFactory;
  final CalderaGroupClient Function() clientFactory;
  @override
  State<CalderaGroupScreen> createState() => _CalderaGroupScreenState();
}

class _CalderaGroupScreenState extends State<CalderaGroupScreen> {
  late final _discovery = widget.discoveryFactory();
  late final _client = widget.clientFactory();
  StreamSubscription<List<CalderaNode>>? _subscription;
  Timer? _refresh;
  final _manual = <String, CalderaNode>{};
  List<CalderaNode> _nodes = [];
  final _members = <String>{};
  String? _source;
  CalderaState? _state;
  bool _busy = false;
  bool _accepted = false;
  double? _volume;

  bool get _current => mounted && widget.current();
  CalderaNode? get _leader => _nodes.where((node) => node.id == _source).firstOrNull;
  bool _valid(CalderaNode node) =>
      _current &&
      _nodes.any(
        (value) => value.id == node.id && value.endpoint == node.endpoint && value.expires.isAfter(DateTime.now()),
      );

  @override
  void initState() {
    super.initState();
    if (widget.audio case final Listenable audio) audio.addListener(_audioChanged);
    _subscription = _discovery.changes.listen(
      _received,
      onError: (Object _) {
        if (mounted && _current) showErrorSnackBar(context, t.musicExperience.error);
      },
    );
    unawaited(
      _discovery.start().catchError((Object _) {
        if (mounted && _current) showErrorSnackBar(context, t.musicExperience.error);
      }),
    );
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      final leader = _leader;
      if (!_busy && leader != null) unawaited(_run(() => _read(leader)));
    });
  }

  void _audioChanged() {
    if (mounted) setState(() {});
  }

  void _received(List<CalderaNode> discovered) {
    if (!_current) return;
    final previous = _leader;
    final nodes = <String, CalderaNode>{..._manual, for (final node in discovered) node.id: node};
    setState(() {
      _nodes = nodes.values.where((node) => node.expires.isAfter(DateTime.now())).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final next = _leader;
      if (next == null || previous != null && previous.endpoint != next.endpoint) {
        _source = null;
        _state = null;
        _accepted = false;
      }
      _members.removeWhere((id) => !_nodes.any((node) => node.id == id));
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (_) {
      if (mounted && _current) showErrorSnackBar(context, t.musicExperience.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read(CalderaNode node) async {
    final state = await _client.state(node, current: () => _valid(node));
    if (!_valid(node) || node.id != _source) return;
    if (_state != null && _state!.player != state.player) {
      setState(() {
        _source = null;
        _state = null;
        _accepted = false;
      });
      throw StateError('Native player identity changed');
    }
    setState(() {
      _state = state;
      _volume = state.volume.toDouble();
    });
  }

  Future<void> _manualConnection() async {
    var entered = '';
    final endpoint = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.companionRemote.pairing.manualConnection),
        content: TextField(
          onChanged: (value) => entered = value,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(hintText: '192.168.1.100:32500'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, entered), child: Text(t.common.connect)),
        ],
      ),
    );
    if (endpoint == null || !_current) return;
    await _run(() async {
      final node = await _client.inspect(endpoint.trim(), current: () => _current);
      if (!_current) return;
      _manual[node.id] = node;
      _received(_discovery.nodes);
    });
  }

  Future<void> _transport(String action) async {
    final leader = _leader, state = _state;
    if (leader == null || state == null) return;
    await _run(() async {
      await _client.transport(leader, state, action, current: () => _valid(leader));
      await _read(leader);
    });
  }

  @override
  void dispose() {
    if (widget.audio case final Listenable audio) audio.removeListener(_audioChanged);
    _refresh?.cancel();
    unawaited(_subscription?.cancel());
    _discovery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final leader = _leader, state = _state;
    final controls = !_busy && _current && leader != null && state != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Caldera / Plexamp'),
        actions: [
          IconButton(
            tooltip: t.companionRemote.pairing.manualConnection,
            onPressed: _busy ? null : _manualConnection,
            icon: const AppIcon(Symbols.add_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.audio case final NativeMusicGroupAvailabilityControls availability)
            SwitchListTile.adaptive(
              title: Text(t.musicDevices.receive),
              subtitle: Text(t.watchTogether.anyoneCanControl),
              value: availability.nativeMusicGroupAvailable,
              onChanged: _busy || !_current
                  ? null
                  : (value) => unawaited(
                      _run(() async {
                        await availability.setNativeMusicGroupAvailable(value, current: widget.current);
                        if (mounted) setState(() {});
                      }),
                    ),
            ),
          DropdownButtonFormField<String>(
            key: ValueKey(_source),
            initialValue: _source,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.musicExperience.source),
            items: [
              for (final node in _nodes)
                DropdownMenuItem(
                  value: node.id,
                  child: Text(node.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    setState(() {
                      _source = value;
                      _state = null;
                      _volume = null;
                      _accepted = false;
                      _members.remove(value);
                    });
                    final selected = _leader;
                    if (selected != null) unawaited(_run(() => _read(selected)));
                  },
          ),
          if (widget.audio != null && leader != null)
            ListTile(
              leading: const AppIcon(Symbols.speaker_rounded),
              title: Text(t.musicDevices.thisDevice),
              subtitle: Text(leader.name),
              trailing: IconButton(
                tooltip: widget.audio!.receivingNativeMusicGroup ? t.music.stopPlayback : t.common.play,
                icon: AppIcon(
                  widget.audio!.receivingNativeMusicGroup ? Symbols.stop_rounded : Symbols.play_arrow_rounded,
                ),
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _run(() async {
                          if (widget.audio!.receivingNativeMusicGroup) {
                            await widget.audio!.leaveNativeMusicGroup();
                          } else {
                            await widget.audio!.receiveNativeMusicGroup(leader, current: widget.current);
                          }
                          if (mounted) setState(() {});
                        }),
                      ),
              ),
            ),
          if (widget.audio case final NativeMusicGroupSourceControls source)
            ListTile(
              leading: const AppIcon(Symbols.speaker_group_rounded),
              title: Text(t.musicDevices.playOn),
              subtitle: Text(
                [
                  for (final node in _nodes)
                    if (node.id == _source || _members.contains(node.id)) node.name,
                ].join(', '),
              ),
              trailing: IconButton(
                tooltip: source.sendingNativeMusicGroup ? t.music.stopPlayback : t.common.play,
                icon: AppIcon(source.sendingNativeMusicGroup ? Symbols.stop_rounded : Symbols.play_arrow_rounded),
                onPressed: _busy || leader == null
                    ? null
                    : () => unawaited(
                        _run(() async {
                          if (source.sendingNativeMusicGroup) {
                            await widget.audio!.leaveNativeMusicGroup();
                          } else {
                            await source.sendNativeMusicGroup([
                              for (final node in _nodes)
                                if (node.id == _source || _members.contains(node.id)) node,
                            ], current: widget.current);
                          }
                          if (mounted) setState(() {});
                        }),
                      ),
              ),
            ),
          if (state != null) ...[
            const SizedBox(height: 12),
            Text(state.title),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                IconButton(
                  tooltip: t.music.previousTrack,
                  onPressed: controls ? () => _transport('skipPrevious') : null,
                  icon: const AppIcon(Symbols.skip_previous_rounded),
                ),
                IconButton(
                  tooltip: state.state == 'playing' ? t.common.pause : t.common.play,
                  onPressed: controls ? () => _transport(state.state == 'playing' ? 'pause' : 'play') : null,
                  icon: AppIcon(state.state == 'playing' ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                ),
                IconButton(
                  tooltip: t.music.nextTrack,
                  onPressed: controls ? () => _transport('skipNext') : null,
                  icon: const AppIcon(Symbols.skip_next_rounded),
                ),
                IconButton(
                  tooltip: t.music.stopPlayback,
                  onPressed: controls ? () => _transport('stop') : null,
                  icon: const AppIcon(Symbols.stop_rounded),
                ),
              ],
            ),
            Slider(
              value: _volume ?? state.volume.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: '${(_volume ?? state.volume).round()}',
              onChanged: controls ? (value) => setState(() => _volume = value) : null,
              onChangeEnd: !controls
                  ? null
                  : (value) => _run(() async {
                      await _client.volume(leader, state, value.round(), current: () => _valid(leader));
                      await _read(leader);
                    }),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(t.companionRemote.pairing.availableDevices),
          ),
          if (_nodes.isEmpty) Text(t.companionRemote.pairing.noDevicesFound),
          for (final node in _nodes.where((node) => node.id != _source))
            CheckboxListTile(
              title: Text(node.name),
              subtitle: Text(node.endpoint),
              value: _members.contains(node.id),
              onChanged: _busy
                  ? null
                  : (selected) => setState(() {
                      if (selected == true) {
                        _members.add(node.id);
                      } else {
                        _members.remove(node.id);
                      }
                      _accepted = false;
                    }),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator())
                : AppIcon(_accepted ? Symbols.check_rounded : Symbols.speaker_group_rounded),
            label: Text(t.common.save),
            onPressed: !controls
                ? null
                : () => _run(() async {
                    final sinks = _nodes.where((node) => _members.contains(node.id)).toList();
                    if (sinks.length != _members.length) throw StateError('Native group member unavailable');
                    await _client.group(leader, state, sinks, current: () => _valid(leader) && sinks.every(_valid));
                    if (_current) setState(() => _accepted = true);
                  }),
          ),
        ],
      ),
    );
  }
}
