import 'dart:async';
import 'package:flutter/foundation.dart';
import '../mpv/mpv.dart';
import '../mpv/player/subtitle_pcm_capture_source.dart';
import 'speech_output_service.dart';
import 'subtitle_overlay_service.dart';

class _SubtitleVolumeLease {
  _SubtitleVolumeLease(this.player, this.session, this.original, this.applied);
  final Player player;
  final SubtitleOverlaySession session;
  final double original, applied;
}

class SubtitleSpeechService extends ChangeNotifier {
  SubtitleSpeechService._();
  static final instance = SubtitleSpeechService._();
  Player? _player;
  SubtitleOverlaySession? _session;
  SubtitleOverlayTrack? _track;
  Timer? _timer;
  int? _timeline;
  int _epoch = 0;
  String? _lastCue;
  _SubtitleVolumeLease? _volume;
  Future<void> _volumeCommands = Future.value();
  bool _busy = false;
  double rate = .5, duck = .35;
  String status = 'Spoken subtitles are off.';
  bool get running => _player != null;
  bool isSpeaking(SubtitleOverlayTrack track) => identical(_track, track);
  bool get _current {
    try { return _session?.current == true && _session!.lanes.contains(_track) && _track?.isCurrent() == true; }
    catch (_) { return false; }
  }
  Future<void> start(Player player, SubtitleOverlayTrack track) async {
    await stop();
    _player = player; _session = SubtitleOverlayService.forPlayer(player); _track = track;
    _timeline = player is SubtitlePcmCaptureSource ? player.playbackTimelineGeneration : null;
    _lastCue = null;
    status = 'Speaking the selected overlay using the device speech engine.';
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_tick()));
    notifyListeners();
  }
  Future<void> _restore(_SubtitleVolumeLease? lease) {
    if (lease == null) return Future.value();
    final operation = _volumeCommands.then((_) async {
      if (!identical(_volume, lease)) return;
      _volume = null;
      // User volume changes take ownership. Never restore into replaced media.
      if (lease.session.current && (lease.player.state.volume - lease.applied).abs() < .5) {
        await lease.player.setVolume(lease.original);
      }
    });
    _volumeCommands = operation.catchError((Object _) {});
    return operation;
  }
  Future<void> stop() async {
    final epoch = ++_epoch;
    _timer?.cancel(); _timer = null;
    await SpeechOutputService.instance.stop(this);
    await _restore(_volume);
    if (epoch != _epoch) return;
    _player = null; _track = null; _session = null;
    status = 'Spoken subtitles are off.'; notifyListeners();
  }
  Future<void> _tick() async {
    if (_busy || _player == null) return;
    _busy = true;
    final epoch = _epoch, player = _player!, track = _track!;
    try {
      if (!_current) { await stop(); return; }
      final timeline = player is SubtitlePcmCaptureSource ? player.playbackTimelineGeneration : null;
      if (!player.state.playing || timeline != _timeline) {
        _timeline = timeline; _lastCue = null;
        await SpeechOutputService.instance.stop(this); await _restore(_volume);
        return;
      }
      final cues = track.at(player.currentPosition.inMilliseconds);
      if (cues.isEmpty) { await SpeechOutputService.instance.stop(this); await _restore(_volume); return; }
      final key = cues.map((c) => c.stableId).join(':');
      if (key == _lastCue) return;
      await SpeechOutputService.instance.stop(this); await _restore(_volume);
      if (epoch != _epoch || !_current) return;
      _lastCue = key;
      final lease = _SubtitleVolumeLease(player, _session!, player.state.volume,
          player.state.volume * duck.clamp(0.0, 1.0));
      _volume = lease;
      final change = _volumeCommands.then((_) async {
        if (epoch == _epoch && _current && identical(_volume, lease)) await player.setVolume(lease.applied);
      });
      _volumeCommands = change.catchError((Object _) {});
      await change;
      if (epoch != _epoch || !_current) { await _restore(lease); return; }
      await SpeechOutputService.instance.speak(this, cues.map((c) => SubtitleOverlayTrack.plain(c.text)).join('\n'),
        rate: rate, language: track.language,
        onEnded: () => unawaited(_restore(lease)),
        onReplaced: () { if (epoch == _epoch) unawaited(stop()); });
    } catch (_) {
      await stop(); status = 'Spoken subtitles stopped. Check that the selected device speech engine is available.'; notifyListeners();
    } finally { _busy = false; }
  }
}
