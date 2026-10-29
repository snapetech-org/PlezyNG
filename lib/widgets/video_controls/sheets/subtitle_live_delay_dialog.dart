import 'dart:async';
import 'package:flutter/material.dart';
import '../../../media/live_tv_timeline.dart';
import '../../../mpv/mpv.dart';
import 'package:provider/provider.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../services/subtitle_dvr_delay_service.dart';

/// An explicit DVR seek on the backend's epoch/grid, never a fabricated wall
/// clock or a change to playback speed. It does not promise future audio access.
class SubtitleLiveDelayDialog extends StatefulWidget {
  const SubtitleLiveDelayDialog({super.key, required this.player, required this.timeline, required this.seek, this.goLive});
  final Player player;
  final LiveTvTimeline Function(Duration) timeline;
  final ValueChanged<double> seek;
  final VoidCallback? goLive;
  @override
  State<SubtitleLiveDelayDialog> createState() => _SubtitleLiveDelayDialogState();
}
class _SubtitleLiveDelayDialogState extends State<SubtitleLiveDelayDialog> {
  Timer? _timer;
  double _delay = 15;
  String? _message;
  @override
  void initState() { super.initState(); _timer = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); }); }
  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (widget.player.disposed) return const AlertDialog(content: Text('Playback ended.'));
    final hold = SubtitleDvrDelayService.forPlayer(widget.player);
    final timeline = widget.timeline(widget.player.currentPosition);
    final window = timeline.seekable;
    final edge = timeline.liveEdgeEpoch;
    final validEdge = timeline.liveEdgeAccuracy == LiveTvTimeAccuracy.confirmed || timeline.liveEdgeAccuracy == LiveTvTimeAccuracy.estimated;
    final available = window != null && window.isValid && edge != null && validEdge &&
        timeline.seekStatus != LiveTvSeekStatus.pending && timeline.seekStatus != LiveTvSeekStatus.opening;
    final target = available ? window!.target(edge! - _delay) : null;
    final actualDelay = target == null || edge == null ? null : edge - target;
    return AlertDialog(title: const Text('Delayed live / DVR playback'), content: SizedBox(width: 560,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Choose how far behind the backend’s live edge to watch. This uses the available DVR buffer and its seek grid. '
          'It does not make future audio available to playback capture or guarantee captions arrive before dialogue.'),
        SwitchListTile(title: const Text('Hold the requested DVR delay'),
          subtitle: const Text('May seek at most once every 30 seconds when drift exceeds the backend grid. Stops on manual seek, pause, speed, media, audio or profile changes. It does not decode future audio.'),
          value: hold.running, onChanged: !available && !hold.running ? null : (enabled) {
            if (!enabled) { hold.stop(); } else {
              final profiles = context.read<ActiveProfileProvider>(), profile = context.read<ActiveProfileProvider>().activeId;
              hold.start(seconds: _delay, timeline: widget.timeline, seek: widget.seek, isCurrent: () => profiles.activeId == profile);
            }
            setState(() {});
          }),
        Text(hold.status),
        Text('Requested delay: ${_delay.round()} seconds'), Slider(value: _delay, min: 5, max: 120, divisions: 23,
          onChanged: (value) => setState(() { hold.stop(); _delay = value; _message = null; })),
        if (actualDelay != null) Text('Available target: ${actualDelay.toStringAsFixed(1)} seconds behind live${actualDelay < _delay - 1 ? ' (limited by the current DVR window)' : ''}.'),
        if (!available) const Text('This session has no current seekable DVR window. Refresh after the backend has buffered more content.'),
        if (timeline.playback.epoch != null && edge != null) Text('Current delay: ${(edge - timeline.playback.epoch!).clamp(0, 86400).toStringAsFixed(1)} seconds.'),
        if (_message != null) Text(_message!),
      ])), actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (widget.goLive != null) TextButton(onPressed: () { hold.stop(); widget.goLive!(); Navigator.pop(context); }, child: const Text('Return to live')),
        FilledButton(onPressed: target == null ? null : () {
          // Re-read at the moment of intent; the DVR window may have advanced.
          final fresh = widget.timeline(widget.player.currentPosition);
          final edge = fresh.liveEdgeEpoch;
          final next = edge == null ? null : fresh.seekable?.target(edge - _delay);
          if (next == null || fresh.liveEdgeAccuracy == LiveTvTimeAccuracy.stale || fresh.liveEdgeAccuracy == LiveTvTimeAccuracy.unknown) {
            setState(() => _message = 'The DVR window changed. Wait for its next update.'); return;
          }
          hold.stop(); widget.seek(next); setState(() => _message = 'Delay requested. The backend will report the resulting position.');
        }, child: const Text('Apply DVR delay')),
      ]);
  }
}
