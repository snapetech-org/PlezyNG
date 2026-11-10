import 'dart:async';

import 'package:flutter/services.dart';

import '../../media/media_item.dart';
import '../../mpv/models.dart';
import '../../mpv/player/player.dart';
import '../../utils/serial_future_queue.dart';
import '../../utils/session_identifier.dart';
import '../cast_playback_ownership.dart';
import 'music_source_resolver.dart';

enum CastMusicState { loading, playing, paused, finished, stopped, error }

class CastMusicStatus {
  const CastMusicStatus({required this.session, required this.state, this.token, this.duration, this.volume});
  final int session;
  final String? token;
  final CastMusicState state;
  final Duration? duration;
  final double? volume;
}

abstract interface class CastMusicReceiver {
  bool get connected;
  CastMusicStatus? get status;
  Stream<CastMusicStatus> get statuses;
  Stream<Duration> get positions;
  Stream<bool> get connections;
  Future<void> load(MediaItem track, MusicSource source, Media media, String token);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);
}

class CastMusicPlayer extends PlayerBase {
  CastMusicPlayer(this.receiver, {required this.authorized}) : super(listenToNativeEvents: false) {
    _subscriptions.add(receiver.statuses.listen(_status, onError: (Object _) => _revoke()));
    _subscriptions.add(receiver.positions.listen(_position, onError: (Object _) => _revoke()));
    _subscriptions.add(
      receiver.connections.listen((connected) {
        if (!connected) _revoke();
      }, onError: (Object _) => _revoke()),
    );
    _authorityTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!available || (_sourceCurrent != null && !_sourceCurrent!())) _revoke();
    });
  }

  final CastMusicReceiver receiver;
  final bool Function() authorized;
  final _ownership = CastPlaybackOwnership();
  final _loads = SerialFutureQueue();
  final _revoked = StreamController<void>.broadcast(sync: true);
  final List<StreamSubscription<Object?>> _subscriptions = [];
  MediaItem? _track;
  MusicSource? _source;
  bool Function()? _sourceCurrent;
  bool _lost = false;
  bool _loading = false;
  bool _loaded = false;
  int _request = 0;
  Timer? _authorityTimer;

  bool get available => !disposed && !_lost && receiver.connected && authorized();
  Stream<void> get revoked => _revoked.stream;

  void prepare(MediaItem track, MusicSource source, bool Function() current) {
    _track = track;
    _source = source;
    _sourceCurrent = current;
  }

  bool _matches(CastMusicStatus? status) => status != null && _ownership.matches(status.token, status.session);

  bool get _owns => available && _sourceCurrent?.call() == true && _matches(receiver.status);

  void _revoke() {
    if (_lost || disposed) return;
    _lost = true;
    _request++;
    handlePropertyChange('pause', true);
    _revoked.add(null);
  }

  void _position(Duration position) {
    if (!_loading &&
        _owns &&
        {CastMusicState.loading, CastMusicState.playing, CastMusicState.paused}.contains(receiver.status?.state) &&
        position >= Duration.zero) {
      handlePropertyChange('time-pos', position.inMicroseconds / Duration.microsecondsPerSecond);
    }
  }

  void _status(CastMusicStatus status) {
    if (_loading || !_loaded || disposed) return;
    if (!_owns || !_matches(status)) {
      _revoke();
      return;
    }
    if (status.duration != null) {
      handlePropertyChange('duration', status.duration!.inMicroseconds / Duration.microsecondsPerSecond);
    }
    if (status.volume != null) setVolumeState(status.volume!);
    handlePropertyChange('paused-for-cache', status.state == CastMusicState.loading);
    switch (status.state) {
      case CastMusicState.playing:
        handlePropertyChange('pause', false);
      case CastMusicState.paused:
        handlePropertyChange('pause', true);
      case CastMusicState.finished:
        if (!state.completed) {
          handlePropertyChange('time-pos', state.duration.inMicroseconds / Duration.microsecondsPerSecond);
          handlePropertyChange('eof-reached', true);
        }
      case CastMusicState.stopped || CastMusicState.error:
        _revoke();
      case CastMusicState.loading:
        break;
    }
  }

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) {
    final request = ++_request;
    final track = _track, source = _source, sourceCurrent = _sourceCurrent;
    bool current() => request == _request && available && sourceCurrent?.call() == true;
    return _loads.run(() async {
      if (!current() || track == null || source == null || source.url != media.uri) {
        throw StateError('Cast source is no longer authorized');
      }
      if (media.headers?.isNotEmpty == true) throw StateError('Cast sources must not require request headers');
      final uri = Uri.tryParse(media.uri);
      if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
        throw StateError('Cast requires a receiver-accessible HTTP source');
      }
      _loading = true;
      final token = generateSessionIdentifier();
      _ownership.begin(token, current);
      try {
        await loadAcknowledgedCastMedia(
          statuses: receiver.statuses,
          invalidated: revoked,
          acknowledge: (status) {
            if (!_ownership.acknowledge(status.token, status.session)) return false;
            if ({CastMusicState.error, CastMusicState.stopped}.contains(status.state)) {
              throw StateError('Cast receiver rejected the media');
            }
            return true;
          },
          load: () => receiver.load(track, source, media, token),
        );
        if (!current() || !_matches(receiver.status)) throw StateError('Cast load was superseded');
        takeSourceOwnership();
        configureTimeline(
          duration: timelineDuration ?? (track.durationMs == null ? null : Duration(milliseconds: track.durationMs!)),
        );
        resetPlaybackProgress(media.start ?? Duration.zero);
        handlePropertyChange('eof-reached', false);
        handlePropertyChange('pause', true);
        handlePropertyChange('seekable', true);
        if (track.durationMs != null) handlePropertyChange('duration', track.durationMs! / 1000);
        _loaded = true;
        if (play) await receiver.play();
        if (!current()) throw StateError('Cast load was superseded');
        handlePropertyChange('pause', !play);
      } finally {
        _loading = false;
      }
    });
  }

  Future<void> _control(Future<void> Function() action) async {
    if (!_owns) {
      _revoke();
      return;
    }
    await action();
  }

  @override
  Future<void> play() => _control(receiver.play);
  @override
  Future<void> pause() => _control(receiver.pause);
  @override
  Future<void> seek(Duration position) => _control(() => runSeek(position, () => receiver.seek(position)));
  @override
  Future<void> setVolume(double volume) => _control(() => receiver.setVolume(volume.clamp(0, 100).toDouble()));
  @override
  Future<void> setRate(double rate) => _control(() => receiver.setRate(rate));
  @override
  Future<void> stop() async {
    _request++;
    final status = receiver.status;
    if (_matches(status) && receiver.connected) await receiver.stop();
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    if (disposed) return;
    _request++;
    _authorityTimer?.cancel();
    _revoked.add(null);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _revoked.close();
    await super.dispose(preserveDisplayMode: preserveDisplayMode);
  }

  @override
  Future<void> selectAudioTrack(AudioTrack track) async {}
  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> setProperty(String name, String value) async {}
  @override
  Future<String?> getProperty(String name) async => null;
  @override
  Future<void> command(List<String> args) async {}
  @override
  String get playerType => 'cast';
  @override
  String get logPrefix => 'Cast music';
  @override
  MethodChannel get methodChannel => const MethodChannel('com.pleazyng/cast_music_unused');
  @override
  EventChannel get eventChannel => const EventChannel('com.pleazyng/cast_music_unused_events');
}
