import 'dart:async';
import 'package:flutter/material.dart';
import '../../../services/subtitle_inference_scheduler.dart';

/// App-wide local inference policy. These are admission controls, not claims
/// about accelerator placement or the amount of free device memory.
class SubtitleResourceDialog extends StatefulWidget {
  const SubtitleResourceDialog({super.key});
  @override
  State<SubtitleResourceDialog> createState() => _SubtitleResourceDialogState();
}

class _SubtitleResourceDialogState extends State<SubtitleResourceDialog> {
  final _scheduler = SubtitleInferenceScheduler.instance;
  final _rss = TextEditingController();
  bool _charging = false, _multiview = true, _ready = false, _saving = false;
  String? _error;
  Timer? _refresh;
  @override
  void initState() {
    super.initState();
    _scheduler.addListener(_changed);
    unawaited(_load());
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_scheduler.refresh()));
  }
  Future<void> _load() async {
    await _scheduler.refresh();
    if (!mounted) return;
    setState(() {
      _charging = _scheduler.readAheadChargingOnly;
      _multiview = _scheduler.pauseForMultiview;
      _rss.text = _scheduler.rssLimitMiB.toString();
      _ready = true;
    });
  }
  void _changed() { if (mounted) setState(() {}); }
  @override
  void dispose() {
    _refresh?.cancel(); _scheduler.removeListener(_changed); _rss.dispose(); super.dispose();
  }
  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final limit = int.tryParse(_rss.text.trim());
      if (limit == null) throw ArgumentError('Enter a whole number of MiB.');
      await _scheduler.configure(readAheadChargingOnly: _charging, pauseForMultiview: _multiview, rssLimitMiB: limit);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally { if (mounted) setState(() => _saving = false); }
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Local subtitle resources'),
    content: SizedBox(width: 540, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('One local speech model runs at a time. Live captions retain their model; stop them before starting another local model. '
          'Memory pressure or severe heat stops live inference at the next safe boundary and preserves completed cues. Playback settings are unchanged.'),
        const SizedBox(height: 12),
        Text('Worker: ${_scheduler.busy ? 'running' : 'idle'} · ${_scheduler.waiting} waiting\n'
          'Resident live model: ${_scheduler.residentModel ? 'yes' : 'no'}\n'
          'Active video players: ${_scheduler.activeVideoPlayers}\n'
          'External power: ${switch (_scheduler.externalPower) { true => 'connected', false => 'disconnected', null => 'unknown' }}\n'
          'Thermal tier: ${_scheduler.thermalTier ?? 'unknown'}\n'
          'Process RSS: ${_scheduler.rssBytes == null ? 'unknown' : '${(_scheduler.rssBytes! / 1048576).round()} MiB'}'),
        if (_scheduler.waitingReason != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_scheduler.waitingReason!)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Read ahead only on external power'),
          subtitle: const Text('An unknown power state waits until this option is turned off.'),
          value: _charging, onChanged: !_ready || _saving ? null : (value) => setState(() => _charging = value)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Pause queued work during multiview'),
          subtitle: const Text('Read-ahead and background jobs wait while more than one video player is active. Explicit foreground work remains available.'),
          value: _multiview, onChanged: !_ready || _saving ? null : (value) => setState(() => _multiview = value)),
        TextField(controller: _rss, enabled: _ready && !_saving, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Process RSS admission limit (MiB)', helperText: '0 disables it; otherwise 256–65536. Applies to all local speech work.')),
        const SizedBox(height: 12),
        const Text('RSS covers the app process and is sampled between operations. It is not free memory, GPU memory, or a hard allocation cap. '
          'Thermal reporting is available only through supported player bridges; unknown does not mean cool. '
          'These controls do not coordinate every shader, motion model or device-wide GPU allocation.'),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]))),
    actions: [TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: !_ready || _saving ? null : _save, child: const Text('Save'))],
  );
}
