import 'dart:async';
import 'package:flutter/material.dart';
import '../../../i18n/strings.g.dart';
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
    final strings = Translations.of(context).videoControls.subtitleResources;
    setState(() { _saving = true; _error = null; });
    try {
      final limit = int.tryParse(_rss.text.trim());
      if (limit == null || limit != 0 && (limit < 256 || limit > 65536)) {
        throw FormatException(strings.invalidRssLimit);
      }
      await _scheduler.configure(readAheadChargingOnly: _charging, pauseForMultiview: _multiview, rssLimitMiB: limit);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error is FormatException ? error.message.toString() : strings.saveFailed);
    } finally { if (mounted) setState(() => _saving = false); }
  }
  String _waitingReasonText(Translations$videoControls$subtitleResources$en strings) {
    final reason = _scheduler.waitingReason;
    if (reason == null) return strings.waitingPolicy;
    final thermal = RegExp(r'^Waiting for the device to cool down \(([^)]+)\)\.$').firstMatch(reason);
    if (thermal != null) return strings.waitThermal(tier: thermal[1]!);
    final rss = RegExp(r'^The process is above the configured (\d+) MiB RSS limit\.$').firstMatch(reason);
    if (rss != null) return strings.waitProcessRss(limit: rss[1]!);
    return switch (reason) {
      'A live subtitle model is resident. Stop live captions to run another local model.' => strings.waitResidentModel,
      'The live model is releasing resources.' => strings.waitModelRelease,
      'Waiting after an OS memory-pressure event.' => strings.waitMemoryPressure,
      'Waiting for lower device thermal pressure.' => strings.waitModerateThermal,
      'Waiting while multiple video players are active.' => strings.waitMultiview,
      'Read-ahead is waiting for confirmed external power.' => strings.waitExternalPower,
      _ => strings.waitingPolicy,
    };
  }
  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final strings = t.videoControls.subtitleResources;
    final power = switch (_scheduler.externalPower) {
      true => strings.connected,
      false => strings.disconnected,
      null => t.common.unknown,
    };
    final rss = _scheduler.rssBytes == null
        ? t.common.unknown
        : strings.memoryMiB(value: (_scheduler.rssBytes! / 1048576).round());
    return AlertDialog(
      title: Text(strings.title),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(strings.description),
              const SizedBox(height: 12),
              Text('${strings.workerStatus(state: _scheduler.busy ? strings.running : strings.idle, waiting: _scheduler.waiting)}\n'
                '${strings.residentModelStatus(state: _scheduler.residentModel ? t.common.yes : t.common.no)}\n'
                '${strings.activeVideoPlayers(count: _scheduler.activeVideoPlayers)}\n'
                '${strings.externalPowerStatus(state: power)}\n'
                '${strings.thermalTierStatus(state: _scheduler.thermalTier ?? t.common.unknown)}\n'
                '${strings.processRssStatus(state: rss)}'),
              if (_scheduler.waitingReason != null)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(_waitingReasonText(strings))),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(strings.readAheadChargingOnly),
                subtitle: Text(strings.readAheadChargingHelp),
                value: _charging,
                onChanged: !_ready || _saving ? null : (value) => setState(() => _charging = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(strings.pauseForMultiview),
                subtitle: Text(strings.pauseForMultiviewHelp),
                value: _multiview,
                onChanged: !_ready || _saving ? null : (value) => setState(() => _multiview = value),
              ),
              TextField(
                controller: _rss,
                enabled: _ready && !_saving,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: strings.rssLimitLabel, helperText: strings.rssLimitHelp),
              ),
              const SizedBox(height: 12),
              Text(strings.resourceLimitsHelp),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: !_ready || _saving ? null : _save, child: Text(t.common.save)),
      ],
    );
  }
}
