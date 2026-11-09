import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_audio_policy.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_playback_service.dart';
import '../../utils/snackbar_helper.dart';

class MusicAudioScreen extends StatefulWidget {
  const MusicAudioScreen({super.key});
  @override
  State<MusicAudioScreen> createState() => _MusicAudioScreenState();
}

class _MusicAudioScreenState extends State<MusicAudioScreen> {
  late final MusicPlaybackService _music = context.read<MusicPlaybackService>();
  late final MusicAudioControls? _audio = _music is MusicAudioControls ? _music as MusicAudioControls : null;
  late MusicAudioPolicy _policy = _audio?.audioPolicy ?? const MusicAudioPolicy();
  late List<double> _bands = List.of(_policy.bands);
  late MusicLeveling _leveling = _policy.leveling;
  late double _preamp = _policy.preampDb;
  late int _rate = _policy.sampleRate, _cache = _policy.cacheMiB, _buffer = _policy.bufferSeconds;
  late bool _exclusive = _policy.exclusive;
  late final _output = TextEditingController(text: _policy.output);
  final _name = TextEditingController(), _graphicEq = TextEditingController();
  List<Map<String, dynamic>> _presets = [];
  bool _busy = false, _loaded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final values = await context.read<MusicExperience>().store.documents('eqPreset');
    if (mounted) setState(() => _presets = values);
  }

  @override
  void dispose() {
    _output.dispose();
    _name.dispose();
    _graphicEq.dispose();
    super.dispose();
  }

  Future<void> _apply({bool savePreset = false}) async {
    setState(() => _busy = true);
    try {
      final policy = MusicAudioPolicy(
        leveling: _leveling,
        bands: List.of(_bands),
        preampDb: _preamp,
        sampleRate: _rate,
        exclusive: _exclusive,
        output: _output.text.trim(),
        cacheMiB: _cache,
        bufferSeconds: _buffer,
      );
      await _audio?.setAudioPolicy(policy);
      if (!mounted) return;
      if (savePreset && _name.text.trim().isNotEmpty) {
        await context.read<MusicExperience>().store.saveDocument('eqPreset', _name.text.trim(), {
          'name': _name.text.trim(),
          'policy': policy.toJson(),
        });
        if (mounted) await _load();
      }
      if (mounted) showAppSnackBar(context, t.musicExperience.ready);
    } catch (_) {
      if (mounted) showAppSnackBar(context, t.musicExperience.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _choose(MusicAudioPolicy p) => setState(() {
    _policy = p;
    _bands = List.of(p.bands);
    _preamp = p.preampDb;
    _leveling = p.leveling;
    _rate = p.sampleRate;
    _exclusive = p.exclusive;
    _output.text = p.output;
    _cache = p.cacheMiB;
    _buffer = p.bufferSeconds;
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t.settings.audio)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(t.musicExperience.normalization, style: Theme.of(context).textTheme.titleLarge),
        DropdownButton<MusicLeveling>(
          isExpanded: true,
          value: _leveling,
          items: [
            for (final mode in MusicLeveling.values)
              DropdownMenuItem(
                value: mode,
                child: Text(switch (mode) {
                  MusicLeveling.off => t.common.off,
                  MusicLeveling.track => t.common.mediaKind.track,
                  MusicLeveling.album => t.common.mediaKind.album,
                  MusicLeveling.automatic => t.settings.playbackBufferAuto,
                }),
              ),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() {
                  if (v != null) _leveling = v;
                }),
        ),
        Text('${t.musicTools.preamp} · ${_preamp.toStringAsFixed(1)} dB'),
        Slider(
          value: _preamp,
          min: -24,
          max: 0,
          divisions: 48,
          label: '${_preamp.toStringAsFixed(1)} dB',
          onChanged: _busy ? null : (v) => setState(() => _preamp = v),
        ),
        for (var i = 0; i < _bands.length; i++)
          Row(
            children: [
              SizedBox(width: 80, child: Text('${MusicAudioPolicy.frequencies[i]} Hz')),
              Expanded(
                child: Slider(
                  value: _bands[i],
                  min: -12,
                  max: 12,
                  divisions: 48,
                  label: '${_bands[i].toStringAsFixed(1)} dB',
                  onChanged: _busy ? null : (v) => setState(() => _bands[i] = v),
                ),
              ),
              SizedBox(width: 48, child: Text(_bands[i].toStringAsFixed(1))),
            ],
          ),
        TextField(
          controller: _graphicEq,
          maxLines: 4,
          maxLength: 64000,
          decoration: const InputDecoration(labelText: 'AutoEq GraphicEQ'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  try {
                    setState(() => _bands = MusicAudioPolicy.parseGraphicEq(_graphicEq.text));
                  } catch (_) {
                    showAppSnackBar(context, t.musicExperience.error);
                  }
                },
          child: Text(t.common.preview),
        ),
        TextField(
          controller: _output,
          decoration: InputDecoration(labelText: t.videoSettings.audioOutput),
        ),
        DropdownButton<int>(
          isExpanded: true,
          value: _rate,
          items: [
            for (final rate in [0, 44100, 48000, 88200, 96000, 176400, 192000])
              DropdownMenuItem(value: rate, child: Text(rate == 0 ? t.settings.playbackBufferAuto : '$rate Hz')),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() {
                  if (v != null) _rate = v;
                }),
        ),
        SwitchListTile(
          title: Text(t.musicTools.exclusiveOutput),
          value: _exclusive,
          onChanged: _busy ? null : (v) => setState(() => _exclusive = v),
        ),
        Text('${t.settings.streamBufferSize}: $_cache MiB'),
        Slider(
          value: _cache.toDouble(),
          min: 8,
          max: 512,
          divisions: 63,
          onChanged: _busy ? null : (v) => setState(() => _cache = v.round()),
        ),
        Text('${t.settings.playbackBuffer}: $_buffer s'),
        Slider(
          value: _buffer.toDouble(),
          min: 5,
          max: 600,
          divisions: 119,
          onChanged: _busy ? null : (v) => setState(() => _buffer = v.round()),
        ),
        TextField(
          controller: _name,
          decoration: InputDecoration(labelText: t.mpvConfig.presetName),
        ),
        Wrap(
          spacing: 12,
          children: [
            FilledButton(onPressed: _busy || _audio == null ? null : () => _apply(), child: Text(t.common.save)),
            TextButton(onPressed: _busy ? null : () => _apply(savePreset: true), child: Text(t.mpvConfig.saveAsPreset)),
            TextButton(onPressed: _busy ? null : () => _choose(const MusicAudioPolicy()), child: Text(t.common.reset)),
          ],
        ),
        for (final preset in _presets)
          ListTile(
            title: Text(preset['name'] as String? ?? ''),
            onTap: () {
              try {
                _choose(MusicAudioPolicy.fromJson(Map<String, dynamic>.from(preset['policy'] as Map)));
              } catch (_) {
                showAppSnackBar(context, t.musicExperience.error);
              }
            },
          ),
        if (_busy) const LinearProgressIndicator(),
      ],
    ),
  );
}
