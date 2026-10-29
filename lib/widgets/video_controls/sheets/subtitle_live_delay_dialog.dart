import 'dart:async';
import 'package:flutter/material.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/live_tv_timeline.dart';
import '../../../mpv/mpv.dart';
import 'package:provider/provider.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../services/subtitle_dvr_delay_service.dart';

/// An explicit DVR seek on the backend's epoch/grid, never a fabricated wall
/// clock or a change to playback speed. It does not promise future audio access.
class SubtitleLiveDelayDialog extends StatefulWidget {
  const SubtitleLiveDelayDialog({super.key, required this.player, required this.timeline, required this.seek, this.goLive, this.isCurrent});
  final Player player;
  final LiveTvTimeline Function(Duration) timeline;
  final ValueChanged<double> seek;
  final VoidCallback? goLive;
  final bool Function()? isCurrent;
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
    final copy = Translations.of(context).videoControls.subtitleLive;
    if (widget.player.disposed) return AlertDialog(content: Text(copy.playbackEnded));
    final hold = SubtitleDvrDelayService.forPlayer(widget.player);
    String holdStatus() {
      final status = hold.status;
      if (status.startsWith('Holding ')) {
        final seconds = RegExp(r'^Holding ([\d.]+) seconds behind live$').firstMatch(status)?.group(1);
        if (seconds != null) return copy.holdingStatus(seconds: seconds);
      }
      return switch (status) {
        'Delay hold is off' => copy.holdOff,
        'Waiting for the backend DVR window' => copy.waitingWindow,
        'Waiting for the requested DVR delay' => copy.waitingRequestedDelay,
        'Delay hold stopped: playback, audio or profile changed' => copy.stoppedPlaybackChanged,
        'Delay hold stopped: the backend seek failed' => copy.stoppedSeekFailed,
        'Delay hold stopped: viewer playback control takes precedence' => copy.stoppedViewerControl,
        'Delay hold stopped: no fresh backend DVR clock' => copy.stoppedClockUnavailable,
        'Delay hold stopped: another seek took control' => copy.stoppedOtherSeek,
        'Delay hold stopped: the backend did not confirm the requested delay' => copy.stoppedUnconfirmed,
        'Delay hold stopped: this backend no longer exposes a current DVR window' => copy.stoppedWindowUnavailable,
        _ => copy.unknownHoldStatus,
      };
    }
    final timeline = widget.timeline(widget.player.currentPosition);
    final window = timeline.seekable;
    final edge = timeline.liveEdgeEpoch;
    final validEdge = timeline.liveEdgeAccuracy == LiveTvTimeAccuracy.confirmed || timeline.liveEdgeAccuracy == LiveTvTimeAccuracy.estimated;
    final available = window != null && window.isValid && edge != null && validEdge &&
        timeline.seekStatus != LiveTvSeekStatus.pending && timeline.seekStatus != LiveTvSeekStatus.opening;
    final target = available ? window!.target(edge! - _delay) : null;
    final actualDelay = target == null || edge == null ? null : edge - target;
    return AlertDialog(title: Text(copy.title), content: SizedBox(width: 560,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(copy.description),
        SwitchListTile(title: Text(copy.holdTitle),
          subtitle: Text(copy.holdHelp),
          value: hold.running, onChanged: !available && !hold.running ? null : (enabled) {
            if (!enabled) { hold.stop(); } else {
              final profiles = context.read<ActiveProfileProvider>(), profile = context.read<ActiveProfileProvider>().activeId;
              hold.start(seconds: _delay, timeline: widget.timeline, seek: widget.seek,
                isCurrent: () => profiles.activeId == profile && (widget.isCurrent?.call() ?? true));
            }
            setState(() {});
          }),
        Text(holdStatus()),
        Text(copy.requestedDelay(seconds: _delay.round())), Slider(value: _delay, min: 5, max: 120, divisions: 23,
          onChanged: (value) => setState(() { hold.stop(); _delay = value; _message = null; })),
        if (actualDelay != null) Text(actualDelay < _delay - 1
          ? copy.availableTargetLimited(seconds: actualDelay.toStringAsFixed(1))
          : copy.availableTarget(seconds: actualDelay.toStringAsFixed(1))),
        if (!available) Text(copy.noSeekableWindow),
        if (timeline.playback.epoch != null && edge != null) Text(copy.currentDelay(
          seconds: (edge - timeline.playback.epoch!).clamp(0, 86400).toStringAsFixed(1))),
        if (_message != null) Text(_message!),
      ])), actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(Translations.of(context).common.close)),
        if (widget.goLive != null) TextButton(onPressed: () { hold.stop(); widget.goLive!(); Navigator.pop(context); }, child: Text(copy.returnLive)),
        FilledButton(onPressed: target == null ? null : () {
          // Re-read at the moment of intent; the DVR window may have advanced.
          final fresh = widget.timeline(widget.player.currentPosition);
          final edge = fresh.liveEdgeEpoch;
          final next = edge == null ? null : fresh.seekable?.target(edge - _delay);
          if (next == null || fresh.liveEdgeAccuracy == LiveTvTimeAccuracy.stale || fresh.liveEdgeAccuracy == LiveTvTimeAccuracy.unknown) {
            setState(() => _message = copy.windowChanged); return;
          }
          hold.stop(); widget.seek(next); setState(() => _message = copy.delayRequested);
        }, child: Text(copy.applyDelay)),
      ]);
  }
}
