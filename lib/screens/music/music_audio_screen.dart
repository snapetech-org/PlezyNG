import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/music_audio_policy.dart';
import '../../services/music/music_experience.dart';
import '../../services/music/music_playback_service.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/music/music_headphone_picker.dart';

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
  late int _prefetch = _policy.prefetchMiB;
  late bool _prefetchWifiOnly = _policy.prefetchWifiOnly;
  late final _output = TextEditingController(text: _policy.output);
  final _name = TextEditingController(), _graphicEq = TextEditingController();
  List<Map<String, dynamic>> _presets = [];
  Map<String, String> _outputs = const {'auto': 'auto'};
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
    final outputs = await _audio?.availableAudioOutputs() ?? const {'auto': 'auto'};
    if (mounted) {
      setState(() {
        _presets = values;
        _outputs = outputs;
      });
    }
  }

  Future<void> _assignOutput({bool remove = false}) async {
    setState(() => _busy = true);
    try {
      await _audio?.setOutputEqualizer(
        _output.text.trim(),
        remove ? null : MusicAudioPolicy(bands: List.of(_bands), preampDb: _preamp),
      );
      if (mounted) showAppSnackBar(context, t.musicExperience.ready);
    } catch (_) {
      if (mounted) showAppSnackBar(context, t.musicExperience.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
        prefetchMiB: _prefetch,
        prefetchWifiOnly: _prefetchWifiOnly,
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
    _prefetch = p.prefetchMiB;
    _prefetchWifiOnly = p.prefetchWifiOnly;
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
          decoration: InputDecoration(labelText: t.musicTools.autoEqGraphicEq),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final preset = await pickMusicHeadphone(context);
                  if (!mounted || preset == null) return;
                  setState(() {
                    _bands = List.of(preset.bands);
                    _preamp = 0;
                    _name.text = preset.name;
                  });
                },
          child: Text(t.musicTools.autoEq),
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
        if (_outputs.length > 1)
          DropdownButton<String>(
            isExpanded: true,
            hint: Text(t.videoSettings.audioOutput),
            items: [
              for (final entry in _outputs.entries)
                DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) _output.text = value;
                  },
          ),
        Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(t.musicTools.outputPreset)),
        Text(t.musicTools.outputPresetHint),
        Wrap(
          spacing: 12,
          children: [
            TextButton(onPressed: _busy || _audio == null ? null : () => _assignOutput(), child: Text(t.common.save)),
            TextButton(
              onPressed: _busy || _audio == null ? null : () => _assignOutput(remove: true),
              child: Text(t.common.reset),
            ),
            TextButton(
              onPressed: _busy || _audio == null
                  ? null
                  : () async {
                      final eq = await _audio.outputEqualizer(_output.text.trim());
                      if (!mounted || !context.mounted) return;
                      if (eq == null) {
                        showAppSnackBar(context, t.common.notAvailable);
                        return;
                      }
                      setState(() {
                        _bands = List.of(eq.bands);
                        _preamp = eq.preampDb;
                      });
                    },
              child: Text(t.common.preview),
            ),
          ],
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
        Text(t.settings.streamBufferSizeMiB(size: _cache)),
        Slider(
          value: _cache.toDouble(),
          min: 8,
          max: 512,
          divisions: 63,
          onChanged: _busy ? null : (v) => setState(() => _cache = v.round()),
        ),
        Text(t.performanceOverlay.cacheLimitMiB(size: _prefetch)),
        Slider(
          value: _prefetch.toDouble(),
          min: 0,
          max: 2048,
          divisions: 32,
          onChanged: _busy ? null : (v) => setState(() => _prefetch = v.round()),
        ),
        SwitchListTile(
          title: Text(t.settings.downloadOnWifiOnly),
          value: _prefetchWifiOnly,
          onChanged: _busy ? null : (v) => setState(() => _prefetchWifiOnly = v),
        ),
        if (_music is MusicCacheControls)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      await (_music as MusicCacheControls).clearPrefetchCache();
                    } catch (_) {
                      if (context.mounted) showAppSnackBar(context, t.musicExperience.error);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: Text('${t.common.clear} · ${t.performanceOverlay.cacheLimit}'),
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
