import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/music/caldera_mesh_equalizer.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';

/// Edits the equalizer used by this device's native music group output.
/// Changes remain a draft until Save, and the service validates the active
/// profile again before it applies or persists them.
class CalderaEqualizerScreen extends StatefulWidget {
  const CalderaEqualizerScreen({super.key, required this.controls, required this.current});

  final CalderaEqualizerControls controls;
  final bool Function() current;

  @override
  State<CalderaEqualizerScreen> createState() => _CalderaEqualizerScreenState();
}

class _CalderaEqualizerScreenState extends State<CalderaEqualizerScreen> {
  late final PlayerParametricEqualizer _initial = widget.controls.calderaEqualizer.snapshot();
  late bool _enabled = _initial.enabled;
  late double _gain = _initial.gain;
  late final List<_BandDraft> _bands = [for (final band in _initial.bands) _BandDraft(band)];
  bool _busy = false;

  @override
  void dispose() {
    for (final band in _bands) {
      band.dispose();
    }
    super.dispose();
  }

  void _addBand() {
    if (_bands.length >= 32) return;
    setState(() => _bands.add(_BandDraft((filterType: 0, frequency: 1000, gain: 0, q: 1))));
  }

  void _removeBand(_BandDraft band) {
    setState(() => _bands.remove(band));
    band.dispose();
  }

  Future<void> _save() async {
    if (_busy || !widget.current()) return;
    if (widget.controls.calderaEqualizer != _initial) {
      showErrorSnackBar(context, t.musicExperience.error);
      return;
    }
    PlayerParametricEqualizer value;
    try {
      value = PlayerParametricEqualizer(
        enabled: _enabled,
        gain: _gain,
        bands: [for (final band in _bands) band.value],
      ).snapshot();
    } catch (_) {
      showErrorSnackBar(context, t.musicExperience.error);
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.controls.setCalderaEqualizer(value, current: widget.current);
      if (mounted && widget.current()) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.musicExperience.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t.musicExperience.equalizer)),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile.adaptive(
          title: Text(t.musicExperience.equalizer),
          value: _enabled,
          onChanged: _busy || !widget.current() ? null : (value) => setState(() => _enabled = value),
        ),
        Text('${t.musicTools.preamp} · ${_gain.toStringAsFixed(1)} dB'),
        Slider(
          value: _gain,
          min: -24,
          max: 24,
          divisions: 96,
          label: '${_gain.toStringAsFixed(1)} dB',
          onChanged: _busy || !widget.current() ? null : (value) => setState(() => _gain = value),
        ),
        for (final band in _bands)
          Card(
            key: ObjectKey(band),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(switch (band.filterType) {
                          1 => t.musicTools.bass,
                          2 => t.musicTools.treble,
                          _ => t.musicTools.peak,
                        }, style: Theme.of(context).textTheme.titleMedium),
                      ),
                      IconButton(
                        tooltip: t.common.delete,
                        onPressed: _busy || !widget.current() ? null : () => _removeBand(band),
                        icon: const AppIcon(Symbols.delete_rounded),
                      ),
                    ],
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: band.filterType,
                    decoration: InputDecoration(labelText: t.musicTools.filterType),
                    items: [
                      DropdownMenuItem(value: 0, child: Text(t.musicTools.peak)),
                      DropdownMenuItem(value: 1, child: Text(t.musicTools.bass)),
                      DropdownMenuItem(value: 2, child: Text(t.musicTools.treble)),
                    ],
                    onChanged: _busy || !widget.current()
                        ? null
                        : (value) {
                            if (value != null) setState(() => band.filterType = value);
                          },
                  ),
                  TextField(
                    controller: band.frequency,
                    enabled: !_busy && widget.current(),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(labelText: 'Hz'),
                  ),
                  TextField(
                    controller: band.gain,
                    enabled: !_busy && widget.current(),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]'))],
                    decoration: const InputDecoration(labelText: 'dB'),
                  ),
                  TextField(
                    controller: band.q,
                    enabled: !_busy && widget.current(),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(labelText: 'Q'),
                  ),
                ],
              ),
            ),
          ),
        TextButton.icon(
          onPressed: _busy || !widget.current() || _bands.length >= 32 ? null : _addBand,
          icon: const AppIcon(Symbols.add_rounded),
          label: Text(t.common.createNew),
        ),
        FilledButton(onPressed: _busy || !widget.current() ? null : _save, child: Text(t.common.save)),
        if (_busy) const LinearProgressIndicator(),
      ],
    ),
  );
}

class _BandDraft {
  _BandDraft(PlayerParametricBand band)
    : filterType = band.filterType,
      frequency = TextEditingController(text: band.frequency.toString()),
      gain = TextEditingController(text: band.gain.toString()),
      q = TextEditingController(text: band.q.toString());

  int filterType;
  final TextEditingController frequency;
  final TextEditingController gain;
  final TextEditingController q;

  PlayerParametricBand get value => (
    filterType: filterType,
    frequency: double.parse(frequency.text),
    gain: double.parse(gain.text),
    q: double.parse(q.text),
  );

  void dispose() {
    frequency.dispose();
    gain.dispose();
    q.dispose();
  }
}
