import 'music_audio_output_inspection.dart';
import 'dart:async';
import '../../mpv/models.dart';
import '../../mpv/player/player.dart';
import 'caldera_audio_output.dart';
import '../../utils/serial_future_queue.dart';

/// A physical source speaker under the existing music session's focus lease.
/// It renders only the private live WAV, never opens media-server content,
/// owns a queue, reports progress, or applies shared-source DSP again.
class CalderaLocalAudioOutput implements CalderaAudioOutput, CalderaAudioClockOutput {
  CalderaLocalAudioOutput({
    required this.createPlayer,
    required this.configure,
    required this.current,
    required this.onFailed,
  });
  final Player Function() createPlayer;
  final Future<void> Function(Player player, bool Function() current) configure;
  final bool Function() current;
  final void Function() onFailed;
  Player? _player;
  Object? _owner;
  bool _used = false;
  final _configuration = SerialFutureQueue();
  final _subscriptions = <StreamSubscription<dynamic>>[];

  @override
  bool ownsCalderaAudio(Object owner) => current() && identical(owner, _owner) && _player != null && !_player!.disposed;

  @override
  Future<bool> openCalderaAudio(Object owner, Uri source, String title, bool Function() allowed) async {
    if (_used || !current() || !allowed() || source.scheme != 'http' || source.host != '127.0.0.1') return false;
    _used = true;
    final player = createPlayer();
    _owner = owner;
    _player = player;
    bool owns() => ownsCalderaAudio(owner) && allowed() && identical(_player, player);
    void failed() {
      if (!owns()) return;
      unawaited(closeCalderaAudio(owner).then<void>((_) => onFailed(), onError: (Object _) => onFailed()));
    }

    _subscriptions
      ..add(player.streams.error.listen((_) => failed()))
      ..add(
        player.streams.completed.listen((done) {
          if (done) failed();
        }),
      );
    var accepted = false;
    try {
      // The primary decoder retains the app's focus claim. This renderer must
      // not arbitrate against it or the overlapping capture decoder.
      await player.setWorkspaceAudioFocusEnabled(false);
      if (!owns()) return false;
      await _configuration.run(() async {
        if (owns()) await configure(player, owns);
      });
      if (!owns()) return false;
      for (final entry in const {
        'demuxer-lavf-format': 'wav',
        'demuxer-lavf-probe-info': 'no',
        'audio-buffer': '0.02',
        'cache': 'no',
        'demuxer-readahead-secs': '0',
        'audio-exclusive': 'no',
        'replaygain': 'no',
      }.entries) {
        await player.setProperty(entry.key, entry.value);
        if (!owns()) return false;
      }
      await player.open(Media(source.toString()), isLive: true);
      accepted = owns();
      return accepted;
    } finally {
      if (!accepted) await closeCalderaAudio(owner);
    }
  }

  @override
  bool hasCalderaAudioClock(Object owner) => ownsCalderaAudio(owner) && _player?.playerType == 'mpv';

  @override
  Future<Duration?> readCalderaAudioClock(Object owner) async {
    final player = _player;
    if (!hasCalderaAudioClock(owner) || player == null) return null;
    final value = double.tryParse(await player.getProperty('audio-pts') ?? '');
    if (!ownsCalderaAudio(owner) || !identical(player, _player) || value == null || !value.isFinite || value < 0) {
      return null;
    }
    return Duration(microseconds: (value * 1000000).round());
  }

  Future<Map<String, String>> inspectOutput() {
    final player = _player, owner = _owner;
    return inspectMusicAudioOutput(
      player,
      current: () => owner != null && ownsCalderaAudio(owner) && identical(player, _player),
    );
  }

  Future<void> refresh() async {
    final player = _player, owner = _owner;
    if (player == null || owner == null || !ownsCalderaAudio(owner)) return;
    bool owns() => ownsCalderaAudio(owner) && identical(player, _player);
    try {
      await _configuration.run(() async {
        if (owns()) await configure(player, owns);
      });
    } catch (_) {
      await closeCalderaAudio(owner);
      onFailed();
      rethrow;
    }
  }

  @override
  Future<void> closeCalderaAudio(Object owner) async {
    if (!identical(owner, _owner)) return;
    final player = _player;
    _owner = null;
    _player = null;
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player?.dispose();
  }
}
