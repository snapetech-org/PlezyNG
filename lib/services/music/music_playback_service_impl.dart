import 'package:uuid/uuid.dart';
import 'music_discovery.dart';
import 'music_account_scope.dart';
import 'music_audio_policy.dart';
import 'music_gain.dart';
import 'caldera_mesh_equalizer.dart';
import 'music_byte_cache.dart';
import 'music_library_store.dart';
import 'music_offline_bundle.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show Listenable, ValueListenable, visibleForTesting;
import 'package:flutter/widgets.dart';
import 'package:os_media_controls/os_media_controls.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/lyrics.dart';
import '../../media/media_item.dart';
import '../../media/media_backend.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../media/media_source_info.dart';
import '../../models/companion_remote/remote_command.dart';
import '../../mpv/models.dart';
import '../../mpv/player/audio_spectrum.dart';
import '../../mpv/player/player.dart';
import '../../mpv/player/player_native.dart';
import '../../utils/app_logger.dart';
import '../../utils/notification_permission.dart';
import '../../utils/platform_detector.dart';
import '../../utils/serial_future_queue.dart';
import '../car_ux_restrictions_service.dart';
import '../companion_remote/companion_remote_receiver.dart';
import '../discord_rpc_service.dart';
import '../driver_distraction.dart';
import '../media_control_router.dart';
import '../media_controls_manager.dart';
import '../multi_server_manager.dart';
import '../offline_watch_sync_service.dart';
import '../playback_coordinator.dart';
import '../playback_launch_observer.dart';
import '../playback_initialization_service.dart';
import '../playback_progress_tracker.dart';
import '../preferred_audio_device.dart';
import '../settings_service.dart';
import 'music_hardware_transport.dart';
import 'music_playback_service.dart';
import 'music_queue_controller.dart';
import 'music_session_store.dart';
import 'music_source_resolver.dart';
import 'music_transfer_snapshot.dart';
import 'music_device_session.dart';
import 'music_group_playback.dart';
import 'caldera_audio_sink.dart';
import 'caldera_audio_source.dart';
import 'caldera_source_endpoint.dart';
import '../../mpv/player/music_pcm_capture_source.dart';
import 'caldera_group.dart';
import 'caldera_native_host.dart';
import 'music_playback_output.dart';

/// A gapless-armed next track: what [Player.setNext] was fed, so the
/// trackTransition event can be mapped back to a queue entry and its
/// already-resolved source reused without a second server round-trip.
class _ArmedTrack {
  final MediaItem track;
  final MusicSource source;

  const _ArmedTrack({required this.track, required this.source});
}

class _MusicOverlap {
  final Player player;
  final _ArmedTrack incoming;
  final int generation;
  final int editRevision;
  final bool usesOverlapCore;

  const _MusicOverlap(this.player, this.incoming, this.generation, this.editRevision, this.usesOverlapCore);
}

/// A restored session's deferred resume point (#2148): applied as the open
/// offset by the first [MusicPlaybackServiceImpl.play] while the current
/// track still matches; discarded by any action that changes what plays.
class _PendingResume {
  final String globalKey;
  Duration position;

  _PendingResume({required this.globalKey, required this.position});
}

/// Real music playback engine: owns the audio [Player], the queue
/// (via [MusicQueueController]), gapless arming, per-track server progress
/// reporting, and the OS media session.
///
/// ### Advancement paths
/// * **Gapless (normal):** after a track starts, the next queue entry is
///   resolved and armed via [Player.setNext]. When the backend auto-advances
///   it emits `trackTransition(uri)` — treated as the authoritative advance:
///   the finished track's tracker reports `stopped` at its full duration,
///   the cursor moves to the armed entry, services rebind, and the new next
///   is armed.
/// * **Completed fallback:** `completed` with nothing armed means either the
///   queue truly ended (repeat off, last track) — the session parks
///   `paused` at the end, keeping [currentTrack] so the mini-player stays —
///   or arming failed, in which case the next track is opened explicitly.
/// * **Manual:** next/previous/jumpTo/removeAt-current finalize the current
///   tracker at its *current* position and open the target directly.
///
/// ### Errors
/// Player/resolver failures surface on [errors] (for a snackbar) and
/// auto-skip to the next track; three consecutive failures without playback
/// progress stop the session with [MusicPlaybackStatus.error].
class MusicPlaybackServiceImpl extends MusicPlaybackService
    with WidgetsBindingObserver
    implements
        MusicLoudnessProfileService,
        MusicAudioSpectrumService,
        MusicVisualizationAudioService,
        MusicKaraokeControls,
        MusicDiscoveryControls,
        MusicAudioControls,
        MusicCacheControls,
        MusicSignalPathService,
        MusicTransferSession,
        MusicGroupSession,
        MusicOutputControls,
        MusicDeviceSession,
        NativeMusicGroupControls,
        NativeMusicGroupSourceControls,
        NativeMusicGroupAvailabilityControls,
        CalderaAudioOutput,
        CalderaAudioMetadataOutput,
        CalderaAudioClockOutput,
        CalderaAudioVolumeOutput,
        CalderaEqualizerControls {
  bool Function() _nativeMusicScope(bool Function() current) {
    Iterable<MediaServerClient> clients() => _serverManager.serverIds
        .map((id) => _serverManager.getClient(ServerId(id)))
        .nonNulls
        .where((client) => _serverManager.isServerVisible(client.serverId));
    final accounts = {for (final client in clients()) client: client.authenticationSessionId};
    return () =>
        !_disposed &&
        current() &&
        clients().length == accounts.length &&
        accounts.entries.every(
          (entry) =>
              identical(entry.key.authenticationSessionId, entry.value) &&
              identical(_serverManager.getClient(entry.key.serverId), entry.key) &&
              _serverManager.isServerVisible(entry.key.serverId),
        );
  }

  @override
  double get calderaAudioVolume => _volume;
  @override
  Future<void> setCalderaAudioVolume(Object owner, double value) async {
    if (!ownsCalderaAudio(owner)) throw StateError('Native output changed');
    await setVolume(value);
  }

  CalderaNativeHost? _calderaHost;
  final CalderaNativeHostFactory _nativeHostFactory;
  int _nativeTransitions = 0;

  @override
  bool get nativeMusicGroupAvailable => _calderaHost?.active == true;

  CalderaSourceMetadata _nativeMetadata() => CalderaSourceMetadata(
    title: _currentTrack?.title ?? 'Pleazyng',
    artist: _currentTrack?.grandparentTitle ?? '',
    album: _currentTrack?.parentTitle ?? '',
    state: switch (_status) {
      MusicPlaybackStatus.playing => 'playing',
      MusicPlaybackStatus.paused => 'paused',
      MusicPlaybackStatus.loading => 'buffering',
      _ => 'stopped',
    },
    position: position,
    duration: duration ?? Duration.zero,
    volume: _volume,
  );

  Future<void> _nativeControl(String action, int? value) async {
    switch (action) {
      case 'play':
        await play();
      case 'pause':
        await pause();
      case 'stop':
        await stop();
      case 'skipNext':
        await next();
      case 'skipPrevious':
        await previous();
      case 'seekTo':
        await seek(Duration(milliseconds: value!));
      case 'setParameters':
        await setVolume(value!.toDouble());
      default:
        throw ArgumentError('Unsupported native music command');
    }
  }

  void _syncNativeHost() {
    final host = _calderaHost;
    if (_nativeTransitions != 0 || host?.active != true) return;
    final source = _calderaSource, sink = _calderaSink;
    if (source?.active == true) {
      host!.synchronize(CalderaMembership(host.id, [host.id, ...source!.sinks.map((node) => node.id)]));
    } else if (sink?.active == true) {
      if (host!.membership.source != sink!.leader.id || !host.membership.sinks.contains(host.id)) {
        host.synchronize(CalderaMembership(sink.leader.id, [sink.leader.id, host.id]));
      }
    } else {
      host!.synchronize(CalderaMembership(host.id, [host.id]));
    }
  }

  @override
  Future<void> setNativeMusicGroupAvailable(bool value, {required bool Function() current}) async {
    if (value && nativeMusicGroupAvailable) return;
    final previous = _calderaHost;
    _calderaHost = null;
    await previous?.close();
    await leaveNativeMusicGroup();
    if (!value) {
      if (!_disposed) notifyListeners();
      return;
    }
    final scope = _nativeMusicScope(current);
    if (!scope()) throw StateError('Native music scope changed');
    late final CalderaNativeHost host;
    bool owns() => scope() && identical(_calderaHost, host);
    host = _nativeHostFactory(
      id: const Uuid().v4(),
      name: 'Pleazyng',
      current: owns,
      metadata: _nativeMetadata,
      equalizer: this,
      control: (action, value) async {
        if (!owns()) throw StateError('Native music scope changed');
        await _nativeControl(action, value);
      },
      assign: (membership, assigned) async {
        bool authorized() => owns() && assigned();
        if (!authorized()) throw StateError('Native membership changed');
        if (membership.source == host.id) {
          final sinks = membership.sinks.where((id) => id != host.id).map(host.resolve).toList();
          if (sinks.isEmpty) {
            await leaveNativeMusicGroup();
          } else {
            await sendNativeMusicGroup(sinks, current: authorized);
          }
        } else {
          await receiveNativeMusicGroup(host.resolve(membership.source), current: authorized);
        }
      },
      onClosed: () {
        if (identical(_calderaHost, host)) {
          _calderaHost = null;
          unawaited(leaveNativeMusicGroup());
          if (!_disposed) notifyListeners();
        }
      },
    );
    _calderaHost = host;
    try {
      await host.start();
      if (!owns()) throw StateError('Native availability retired');
      notifyListeners();
    } catch (_) {
      if (identical(_calderaHost, host)) _calderaHost = null;
      await host.close();
      rethrow;
    }
  }

  CalderaAudioSource? _calderaSource;

  @override
  bool get sendingNativeMusicGroup => _calderaSource?.active == true;

  @override
  Future<void> sendNativeMusicGroup(List<CalderaNode> sinks, {required bool Function() current}) async {
    _nativeTransitions++;
    try {
      await _sendNativeMusicGroup(sinks, current: current);
    } finally {
      _nativeTransitions--;
      _syncNativeHost();
    }
  }

  Future<void> _sendNativeMusicGroup(List<CalderaNode> sinks, {required bool Function() current}) async {
    if (!current()) throw StateError('Native music selection changed');
    final existing = _calderaSource;
    if (existing?.active == true) {
      _calderaHost?.remember(sinks);
      await existing!.replaceSinks(sinks, current: current);
      if (!_disposed) notifyListeners();
      return;
    }
    await leaveNativeMusicGroup();
    if (_disposed ||
        !current() ||
        _currentTrack == null ||
        _player == null ||
        _playbackOutput != null ||
        _musicDeviceOutput != null ||
        _musicGroupFollower) {
      throw StateError('Local music output unavailable');
    }
    final host = _calderaHost;
    var selecting = true;
    final scope = _nativeMusicScope(
      () => host == null ? current() : identical(_calderaHost, host) && host.active && (!selecting || current()),
    );
    late final CalderaAudioSource source;
    bool authorized() =>
        scope() &&
        identical(_calderaSource, source) &&
        _playbackOutput == null &&
        _musicDeviceOutput == null &&
        !_musicGroupFollower;
    host?.remember(sinks);
    source = CalderaAudioSource(
      id: host?.id,
      serveCompanion: host == null,
      sinks: List.unmodifiable(sinks),
      current: authorized,
      feeds: () {
        if (!authorized()) return const [];
        final primary = _player;
        final overlap = _overlap?.player ?? _overlapStartingPlayer;
        return [
          for (final player in [primary, overlap])
            if (player != null && !player.disposed) _nativePcmFeed(player, source, primary: identical(player, primary)),
        ];
      },
      metadata: _nativeMetadata,
      equalizer: this,
      control: (action, value) async {
        if (!authorized()) throw StateError('Native music scope changed');
        await _nativeControl(action, value);
      },
      onMembershipChanged: () {
        if (identical(_calderaSource, source)) {
          _syncNativeHost();
          if (!_disposed) notifyListeners();
        }
      },
      onClosed: () {
        if (identical(_calderaSource, source)) {
          _calderaSource = null;
          _refreshNativeOutputDsp();
          _syncNativeHost();
          if (!_disposed) notifyListeners();
        }
      },
    );
    _calderaSource = source;
    try {
      // A DSP/output change retires a partial overlap before capture. Later
      // overlaps inherit the shared source policy on both decoders.
      _cancelOverlap();
      // Per-speaker EQ belongs to local rendering, never the shared wire PCM.
      await _audioChanges.run(() async {
        for (final player in [_player, _overlap?.player ?? _overlapStartingPlayer]) {
          if (player != null && authorized()) {
            if (identical(player, _player)) await _applyOutputEqualizerNow(player);
            await _applyNativeEqualizer(player);
          }
        }
      });
      if (!authorized()) throw StateError('Native music scope changed');
      await source.start();
      if (!authorized()) {
        await source.close();
        return;
      }
      selecting = false;
      notifyListeners();
    } catch (_) {
      if (identical(_calderaSource, source)) {
        _calderaSource = null;
        _refreshNativeOutputDsp();
      }
      rethrow;
    }
  }

  final _nativeGainReaders = Expando<NativeMusicPcmGainReader>();

  double _musicVolume(Player player, {double? volume, double? gain}) => musicVolumeForGain(
    volume ?? _volume,
    _workspaceAudioEnabled ? gain ?? _musicGain * _outputGain : 0,
    nativeCubic: player.playerType == 'mpv',
  );

  CalderaPcmFeed _nativePcmFeed(Player player, CalderaAudioSource source, {required bool primary}) {
    if (player is! MusicPcmCaptureSource || player.audioPassthroughActive) {
      throw StateError('Native music PCM unavailable');
    }
    final generation = _generation;
    final revision = (generation, _audioPolicy, _currentTrack?.id);
    final reader = _nativeGainReaders[player] ??= NativeMusicPcmGainReader(player.getProperty);
    return CalderaPcmFeed(
      capture: player as MusicPcmCaptureSource,
      position: player.currentPosition,
      gain: _workspaceAudioEnabled ? musicCaptureGain(player.state.volume, nativeCubic: player.playerType == 'mpv') : 0,
      readGain: player.playerType == 'mpv' ? () => reader.read(revision) : null,
      current: () =>
          !_disposed &&
          !player.disposed &&
          identical(_calderaSource, source) &&
          generation == _generation &&
          (primary
              ? identical(_player, player)
              : identical(_overlap?.player, player) || identical(_overlapStartingPlayer, player)),
      playing: player.state.isActive && _status == MusicPlaybackStatus.playing,
      readMuted: () async => (await player.getProperty('mute')) == 'yes',
      setMuted: (muted) async {
        if (player.disposed || _calderaSource != null && !identical(_calderaSource, source)) return;
        await player.setProperty('mute', muted ? 'yes' : 'no');
      },
    );
  }

  CalderaAudioSink? _calderaSink;
  Object? _calderaAudioOwner;
  int? _calderaAudioGeneration;
  CalderaNowPlaying? _nativeNowPlaying;
  final _nativeMetadataClock = Stopwatch();

  @override
  bool get receivingNativeMusicGroup => _calderaSink?.active == true;

  @override
  Future<void> receiveNativeMusicGroup(CalderaNode leader, {required bool Function() current}) async {
    _nativeTransitions++;
    try {
      await _receiveNativeMusicGroup(leader, current: current);
    } finally {
      _nativeTransitions--;
      _syncNativeHost();
    }
  }

  Future<void> _receiveNativeMusicGroup(CalderaNode leader, {required bool Function() current}) async {
    if (!current()) throw StateError('Native music selection changed');
    final existing = _calderaSink;
    if (existing?.active == true &&
        existing!.leader.id == leader.id &&
        existing.leader.endpoint == leader.endpoint &&
        existing.leader.meshPort == leader.meshPort) {
      return;
    }
    await leaveNativeMusicGroup();
    if (_disposed || !current()) throw StateError('Native music scope changed');
    final host = _calderaHost;
    var selecting = true;
    final authorized = _nativeMusicScope(
      () => host == null ? current() : identical(_calderaHost, host) && host.active && (!selecting || current()),
    );
    _calderaHost?.remember([leader]);
    late final CalderaAudioSink sink;
    sink = CalderaAudioSink(
      id: _calderaHost?.id,
      leader: leader,
      output: this,
      current: authorized,
      onClosed: () {
        if (identical(_calderaSink, sink)) {
          _calderaSink = null;
          _syncNativeHost();
          if (!_disposed) notifyListeners();
        }
      },
    );
    _calderaSink = sink;
    try {
      await sink.start();
      if (_disposed || !identical(_calderaSink, sink) || !current()) {
        await sink.close();
        return;
      }
      selecting = false;
      notifyListeners();
    } catch (_) {
      if (identical(_calderaSink, sink)) _calderaSink = null;
      rethrow;
    }
  }

  @override
  Future<void> leaveNativeMusicGroup() async {
    final sink = _calderaSink;
    final source = _calderaSource;
    _calderaSink = null;
    _calderaSource = null;
    await source?.close();
    await sink?.close();
    if (source != null) _refreshNativeOutputDsp();
    _syncNativeHost();
  }

  @override
  bool ownsCalderaAudio(Object owner) =>
      !_disposed && identical(_calderaAudioOwner, owner) && _calderaAudioGeneration == _generation;

  @override
  Future<bool> openCalderaAudio(Object owner, Uri source, String title, bool Function() current) async {
    if (_disposed || !current() || source.scheme != 'http' || source.host != '127.0.0.1') return false;
    final stopping = _stopSession(endStatus: MusicPlaybackStatus.idle);
    final generation = _generation;
    await stopping;
    if (_disposed || generation != _generation || !current()) return false;
    _calderaAudioOwner = owner;
    _calderaAudioGeneration = generation;
    bool owns() => ownsCalderaAudio(owner) && current();
    final track = MediaItem(id: 'native-group', backend: MediaBackend.plex, kind: MediaKind.track, title: title);
    _queue.load([track]);
    _currentTrack = track;
    _musicGroupFollower = true;
    _setStatus(MusicPlaybackStatus.loading, forceNotify: true);
    try {
      await _coordinator.claimMusic();
      if (!owns()) return false;
      final player = await _ensurePlayer();
      if (!owns() || !identical(_player, player)) return false;
      _workspaceAudioEnabled = !_coordinator.workspaceHasCompetingAudioOwner;
      await player.setWorkspaceAudioFocusEnabled(_workspaceAudioEnabled);
      if (!owns()) return false;
      _ensureMediaControls();
      // This is our fixed-format live WAV. Stream-info probing otherwise buffers
      // several seconds before audio-PTS becomes available.
      await player.setProperty('demuxer-lavf-format', 'wav');
      await player.setProperty('demuxer-lavf-probe-info', 'no');
      await player.setProperty('audio-buffer', '0.02');
      if (!owns()) return false;
      await player.setProperty('cache', 'no');
      await player.setProperty('demuxer-readahead-secs', '0');
      if (!owns()) return false;
      await player.open(Media(source.toString()), isLive: true, play: automotiveMusicPlaybackAllowedNow());
      if (!owns()) return false;
      _setStatus(player.state.playing ? MusicPlaybackStatus.playing : MusicPlaybackStatus.paused, forceNotify: true);
      await _mediaControls?.updateMetadata(metadata: track);
      return true;
    } catch (_) {
      await closeCalderaAudio(owner);
      rethrow;
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

  @override
  void updateCalderaMetadata(Object owner, CalderaNowPlaying metadata) {
    if (!ownsCalderaAudio(owner)) return;
    _nativeNowPlaying = metadata;
    _nativeMetadataClock
      ..reset()
      ..start();
    final state = metadata.snapshot;
    final track = _currentTrack;
    final changed =
        track?.title != state.title ||
        track?.parentTitle != metadata.album ||
        track?.grandparentTitle != metadata.artist ||
        track?.durationMs != state.duration;
    if (changed) {
      final display = MediaItem.plex(
        id: 'native-group',
        kind: MediaKind.track,
        title: state.title,
        parentTitle: metadata.album,
        grandparentTitle: metadata.artist,
        durationMs: state.duration,
      );
      _queue.load([display]);
      _currentTrack = display;
      unawaited(_mediaControls?.updateMetadata(metadata: display));
    }
    final status = switch (state.state) {
      'playing' => MusicPlaybackStatus.playing,
      'buffering' => MusicPlaybackStatus.loading,
      _ => MusicPlaybackStatus.paused,
    };
    _setStatus(status, forceNotify: changed);
    final playhead = position;
    _positionController.add(playhead);
    _mediaControls?.updatePlaybackState(
      isPlaying: status == MusicPlaybackStatus.playing,
      position: playhead,
      speed: 1.0,
      force: true,
    );
  }

  Duration? get _nativePosition {
    final state = _nativeNowPlaying?.snapshot;
    if (_calderaAudioOwner == null || state == null) return null;
    final elapsed = state.state == 'playing' ? _nativeMetadataClock.elapsedMilliseconds : 0;
    final value = state.position + elapsed;
    return Duration(milliseconds: state.duration > 0 ? value.clamp(0, state.duration) : value);
  }

  @override
  Future<void> closeCalderaAudio(Object owner) async {
    if (!ownsCalderaAudio(owner)) return;
    await _stopSession(endStatus: MusicPlaybackStatus.idle);
  }

  MusicDevicePlayback? _musicDeviceOutput;
  int _musicDeviceRevision = 0;
  String? _remoteQueueSession;
  Object? _musicDeviceDiscrete;
  String? _musicDeviceMetadata;

  @override
  MusicPlaybackService get playback => this;
  @override
  MusicDevicePlayback? get musicDeviceOutput => _musicDeviceOutput;

  @override
  void setMusicDeviceOutput(MusicDevicePlayback? output) {
    if (identical(output, _musicDeviceOutput)) return;
    _musicDeviceOutput?.removeListener(_onMusicDeviceChanged);
    _musicDeviceOutput = output;
    if (output != null) _finalizeCurrentTrack();
    _musicDeviceDiscrete = null;
    _musicDeviceMetadata = null;
    _musicDeviceRevision++;
    _remoteQueueSession = null;
    beginPlayIntent();
    output?.addListener(_onMusicDeviceChanged);
    _onMusicDeviceChanged();
  }

  void _onMusicDeviceChanged() {
    if (_disposed) return;
    final state = _musicDeviceOutput?.state;
    final session = state?.revision.split('.').first;
    if (_remoteQueueSession != session) {
      _remoteQueueSession = session;
      _musicDeviceRevision++;
    }
    _volumeNotifier.value = state?.volume ?? _volume;
    _positionController.add(state?.snapshot?.position ?? position);
    final output = _musicDeviceOutput;
    final discrete = (output, state?.revision, state?.snapshot?.playing, output?.connected);
    final track = state?.track;
    if (track != null) {
      _ensureMediaControls();
      final metadata = '${state?.revision}:${track.globalKey}';
      if (_musicDeviceMetadata != metadata) {
        _musicDeviceMetadata = metadata;
        unawaited(_mediaControls?.updateMetadata(metadata: track, client: _clientFor(track), duration: duration));
      }
      unawaited(
        _mediaControls?.updatePlaybackState(
          isPlaying: state?.snapshot?.playing ?? false,
          position: position,
          speed: 1.0,
        ),
      );
      _syncControlsAvailability();
    }
    if (_musicDeviceDiscrete != discrete) {
      _musicDeviceDiscrete = discrete;
      notifyListeners();
    }
  }

  Future<void> _controlMusicDevice(String action, [Map<String, dynamic> args = const {}]) async {
    final output = _musicDeviceOutput;
    if (output == null) return;
    try {
      await output.control(action, args);
    } catch (error) {
      if (!_disposed && identical(output, _musicDeviceOutput)) _errorsController.add(error);
    }
  }

  @override
  Future<void> resumeFrozenMusicDevice() => play();

  @override
  Future<PreparedMusicDeviceTransfer?> prepareMusicDeviceTransfer(
    MusicTransferSnapshot snapshot, {
    required bool Function() current,
    bool allowRemoteOutput = false,
  }) async {
    final previousOutput = _musicDeviceOutput;
    if (_disposed || !current() || (previousOutput != null && !allowRemoteOutput)) return null;
    try {
      snapshot.toJson(itemLimit: MusicTransferSnapshot.maxTransferItems);
    } on StateError {
      return null;
    }
    final revision = groupControlRevision;
    final intent = _playIntentGeneration;
    final clients = <MediaServerClient, Object?>{};
    for (final item in snapshot.queue.items) {
      final client = _clientFor(item);
      if (client == null || client.isOfflineMode || client.backend != item.backend) return null;
      clients[client] = client.authenticationSessionId;
    }
    final track = snapshot.queue.items[snapshot.queue.order[snapshot.queue.cursor]];
    final MusicSource source;
    try {
      source = await _cachedSource(await _resolver.resolve(track));
    } catch (_) {
      return null;
    }
    bool valid() =>
        !_disposed &&
        current() &&
        revision == groupControlRevision &&
        intent == _playIntentGeneration &&
        identical(_musicDeviceOutput, previousOutput) &&
        clients.entries.every(
          (entry) =>
              identical(entry.key.authenticationSessionId, entry.value) &&
              identical(_serverManager.getClient(entry.key.serverId), entry.key) &&
              _serverManager.isServerVisible(entry.key.serverId),
        );
    if (!valid()) return null;
    return (position, play) async {
      if (!valid() || (play && !automotiveMusicPlaybackAllowedNow())) return false;
      return _acceptTransfer(
        snapshot.at(position, playing: play),
        current: current,
        preparedSource: source,
      );
    };
  }

  final MusicLibraryStore? _libraryStore;
  late final MusicByteCache? _byteCache = _libraryStore == null ? null : MusicByteCache(scope: _libraryStore.profileId);

  @override
  Future<void> clearPrefetchCache() async {
    await _byteCache?.clear();
  }

  bool Function() _cacheAuthority(MusicSource source) {
    final client = source.reportingClient;
    final authentication = client?.authenticationSessionId;
    return () =>
        !_disposed &&
        _libraryStore?.active == true &&
        client != null &&
        identical(client.authenticationSessionId, authentication) &&
        identical(_serverManager.getClient(client.serverId), client) &&
        _serverManager.isServerVisible(client.serverId) &&
        !client.isOfflineMode;
  }

  Future<MusicSource> _cachedSource(MusicSource source) async {
    final cache = _byteCache;
    if (cache == null || source.isOffline || source.playMethod != 'DirectPlay' || audioPolicy.prefetchMiB == 0) {
      return source;
    }
    try {
      final file = await cache.lookup(source.url, source.headers, current: _cacheAuthority(source));
      return file == null ? source : source.prefetched(file.uri.toString());
    } catch (_) {
      return source;
    }
  }

  void _prefetchTrack(_ArmedTrack armed, Player player, int generation, int request) {
    final cache = _byteCache, source = armed.source;
    if (cache == null || source.isOffline || source.playMethod != 'DirectPlay' || !source.url.startsWith('http')) {
      return;
    }
    final current = _cacheAuthority(source);
    unawaited(
      cache
          .prefetch(
            source.url,
            source.headers,
            budgetBytes: audioPolicy.prefetchMiB * 1024 * 1024,
            wifiOnly: audioPolicy.prefetchWifiOnly,
            current: () => current() && _isCurrentArmRequest(player, generation, request) && identical(_armed, armed),
          )
          .then((file) async {
            if (file == null ||
                !current() ||
                !_isCurrentArmRequest(player, generation, request) ||
                !identical(_armed, armed)) {
              return;
            }
            // Preserve the logical track/reporting source when replacing only its
            // transport. A native transition racing this update remains adoptable.
            final cached = _ArmedTrack(track: armed.track, source: source.prefetched(file.uri.toString()));
            _rememberStaleArm();
            _armed = cached;
            if (!await _trySetNext(player, Media(cached.source.url)) && identical(_armed, cached)) _armed = null;
          })
          .catchError((Object _) {
            /* Optional prefetch never interrupts playback. */
          }),
    );
  }

  PlayerParametricEqualizer _nativeEqualizer = const PlayerParametricEqualizer();
  int _nativeEqRevision = 0;
  @override
  PlayerParametricEqualizer get calderaEqualizer => _nativeEqualizer;

  Future<void> _applyNativeEqualizer(Player player) async {
    if (_disposed || player.disposed) return;
    final effective = _calderaSource == null ? _nativeEqualizer : const PlayerParametricEqualizer();
    if (player case final ParametricEqualizerCapable output) {
      await output.setParametricEqualizer(effective);
    } else if (effective.filters.isNotEmpty) {
      throw UnsupportedError('Native equalizer unavailable');
    }
  }

  Future<void> _restoreNativeEqualizerForPlayback(Player player) async {
    final requested = _nativeEqualizer, revision = _nativeEqRevision;
    try {
      await _applyNativeEqualizer(player);
    } catch (error) {
      // The typed native setter rolls back its accepted graph on failure.
      // A preset saved while idle or on another platform cannot prevent audio.
      if (!_disposed && revision == _nativeEqRevision && identical(requested, _nativeEqualizer)) {
        _nativeEqualizer = const PlayerParametricEqualizer();
      }
      appLogger.w('Native music EQ is unavailable on this output', error: error);
      if (!_disposed) _errorsController.add(error);
    }
  }

  @override
  Future<void> setCalderaEqualizer(PlayerParametricEqualizer value, {required bool Function() current}) {
    final copy = value.snapshot(), scope = _nativeMusicScope(current);
    _nativeEqRevision++;
    return _audioChanges.run(() async {
      if (!scope()) throw StateError('Native equalizer scope changed');
      _cancelOverlap();
      final previous = _nativeEqualizer, player = _player;
      _nativeEqualizer = copy;
      try {
        if (player != null) await _applyNativeEqualizer(player);
        if (!scope()) throw StateError('Native equalizer scope changed');
        await _libraryStore?.saveDocument('audio', 'nativeEqualizer', {
          'version': 1,
          ...CalderaMeshEqualizer.snapshot(copy),
        });
        if (!scope()) throw StateError('Native equalizer scope changed');
        notifyListeners();
      } catch (_) {
        _nativeEqualizer = previous;
        if (player != null && identical(_player, player) && !player.disposed && !_disposed) {
          await _applyNativeEqualizer(player);
        }
        rethrow;
      }
    });
  }

  Future<void> _restoreNativeEqualizer() async {
    final revision = _nativeEqRevision;
    try {
      final data = await _libraryStore?.document('audio', 'nativeEqualizer');
      if (data == null || data['version'] != 1 || _disposed || revision != _nativeEqRevision) return;
      final value = CalderaMeshEqualizer.restore(data);
      await _audioChanges.run(() async {
        if (_disposed || revision != _nativeEqRevision) return;
        _nativeEqualizer = value;
        final player = _player;
        if (player != null) await _restoreNativeEqualizerForPlayback(player);
        if (!_disposed) notifyListeners();
      });
    } catch (error) {
      appLogger.w('Native music EQ could not be restored', error: error);
    }
  }

  void _refreshNativeOutputDsp() {
    _cancelOverlap();
    final player = _player;
    if (player == null || _disposed) return;
    unawaited(
      _audioChanges
          .run(() async {
            if (!_disposed && identical(player, _player) && !player.disposed) {
              _outputEqSignature = null;
              await _applyOutputEqualizerNow(player);
              await _restoreNativeEqualizerForPlayback(player);
            }
          })
          .catchError((Object error) {
            appLogger.w('Native music EQ could not be applied', error: error);
            if (!_disposed) _errorsController.add(error);
          }),
    );
  }

  MusicAudioPolicy? _audioPolicy;
  MusicAudioPolicy? _outputEqualizer;
  String? _outputEqSignature;
  int _audioPolicyRevision = 0;
  final SerialFutureQueue _audioChanges = SerialFutureQueue();
  double get _outputGain => _playbackOutput == null ? (_outputEqualizer ?? _audioPolicy)?.gain ?? 1 : 1;
  @override
  MusicAudioPolicy get audioPolicy => _audioPolicy ?? const MusicAudioPolicy();

  @override
  Future<void> setAudioPolicy(MusicAudioPolicy policy) {
    policy.validate();
    _cancelOverlap();
    // Copy mutable caller lists before entering the asynchronous native queue.
    policy = MusicAudioPolicy.fromJson(policy.toJson());
    ++_audioPolicyRevision;
    return _audioChanges.run(() async {
      if (_disposed) throw StateError('Music session ended');
      final previous = _audioPolicy;
      final player = _player;
      try {
        if (player != null && !player.disposed) {
          await policy.apply(player, albumContext: !shuffled && _playContext?.kind == MusicPlayContextKind.album);
        }
        if (_disposed) return;
        _audioPolicy = policy;
        _outputEqSignature = null;
        if (player != null && !player.disposed) await _applyOutputEqualizerNow(player);
        _setMusicGain(_musicGain, force: true);
        await _libraryStore?.saveDocument('audio', 'active', policy.toJson());
        if (!_disposed) notifyListeners();
      } catch (_) {
        if (!_disposed) {
          _audioPolicy = previous;
          if (player != null && !player.disposed) {
            if (previous == null) {
              await const MusicAudioPolicy().apply(player, albumContext: false);
              await _applyAudioOutputDevice(player);
              await _applyAudioPassthrough(player);
            }
            await _applyMusicAudioSettingsNow(player);
          }
          _setMusicGain(_musicGain, force: true);
        }
        rethrow;
      }
    });
  }

  Future<void> _restoreAudioPolicy() async {
    final revision = _audioPolicyRevision;
    try {
      final json = await _libraryStore?.document('audio', 'active');
      if (json == null || _disposed || revision != _audioPolicyRevision) return;
      await _audioChanges.run(() async {
        if (_disposed || revision != _audioPolicyRevision) return;
        _audioPolicy = MusicAudioPolicy.fromJson(json);
        final player = _player;
        if (player != null && !player.disposed) await _applyMusicAudioSettingsNow(player);
        if (!_disposed) _setMusicGain(_musicGain, force: true);
      });
    } catch (error) {
      appLogger.w('Music audio policy could not be restored', error: error);
    }
  }

  @override
  Future<Map<String, String>> inspectAudioOutput() async {
    final player = _player;
    if (player == null || player.playerType != 'mpv') return {};
    final result = <String, String>{};
    for (final property in [
      'audio-params/samplerate',
      'audio-params/channel-count',
      'audio-out-params/samplerate',
      'audio-out-params/channel-count',
      'audio-out-params/format',
      'current-ao',
      'audio-device',
      'replaygain',
      'af',
    ]) {
      final value = await player.getProperty(property);
      if (_disposed || _player != player) return {};
      if (value != null && value.isNotEmpty) result[property] = value;
    }
    return result;
  }

  @override
  Future<Map<String, String>> availableAudioOutputs() async {
    final player = _player;
    if (player == null || player.playerType != 'mpv') return const {'auto': 'auto'};
    final raw = await player.getProperty('audio-device-list');
    if (_disposed || _player != player || raw == null) return const {'auto': 'auto'};
    try {
      final entries = jsonDecode(raw) as List;
      return {
        'auto': 'auto',
        for (final entry in entries.whereType<Map>())
          if (entry['name'] is String && (entry['name'] as String).isNotEmpty)
            entry['name'] as String: entry['description'] as String? ?? entry['name'] as String,
      };
    } on FormatException {
      return const {'auto': 'auto'};
    } on TypeError {
      return const {'auto': 'auto'};
    }
  }

  @override
  Future<MusicAudioPolicy?> outputEqualizer(String output) async {
    final value = await _libraryStore?.document('outputEq', output);
    if (value == null || _disposed) return null;
    try {
      final eq = MusicAudioPolicy.fromJson(value);
      // An output assignment carries EQ only. A saved preset can never switch
      // the route, resampler or exclusive mode while handling a route event.
      return MusicAudioPolicy(bands: eq.bands, preampDb: eq.preampDb);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  @override
  Future<void> setOutputEqualizer(String output, MusicAudioPolicy? policy) {
    MusicAudioPolicy(output: output).validate();
    policy?.validate();
    final copy = policy == null ? null : MusicAudioPolicy(bands: List.of(policy.bands), preampDb: policy.preampDb);
    return _audioChanges.run(() async {
      final store = _libraryStore;
      if (_disposed || store == null || !store.active) throw StateError('Music profile unavailable');
      if (copy == null) {
        await store.deleteDocument('outputEq', output);
      } else {
        await store.saveDocument('outputEq', output, copy.toJson());
      }
      _outputEqSignature = null;
      final player = _player;
      if (!_disposed && player != null && !player.disposed) await _applyOutputEqualizerNow(player);
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _applyOutputEqualizerNow(Player player) async {
    if (_disposed || _player != player || player.disposed || player.playerType != 'mpv' || _libraryStore == null) {
      return;
    }
    final source = _calderaSource;
    final output = await player.getProperty('audio-device') ?? 'auto';
    // Physical-output presets must not color PCM sent to other speakers.
    // General music EQ remains the shared source policy.
    final eq = source == null ? await outputEqualizer(output) : null;
    if (_disposed || _player != player || player.disposed || !identical(_calderaSource, source)) return;
    if (output != (await player.getProperty('audio-device') ?? 'auto')) return;
    final signature = jsonEncode([output, eq?.toJson(), source != null]);
    if (_outputEqSignature == signature) return;
    final previous = _outputEqualizer;
    final effective = eq ?? _audioPolicy;
    if (eq != null || previous != null) {
      if (player is! AudioEqualizerCapable) throw UnsupportedError('Output EQ unavailable');
      final settings = SettingsService.instanceOrNull;
      final bands =
          effective?.bands ?? [for (final pref in SettingsService.audioEqualizerBandPrefs) settings?.read(pref) ?? 0.0];
      if (bands.any((band) => band != 0) || (effective?.preampDb ?? 0) != 0) {
        await player.setAudioPassthrough(false);
      }
      await (player as AudioEqualizerCapable).setAudioEqualizer(bands);
    }
    if (_disposed || _player != player || player.disposed) return;
    _outputEqualizer = eq;
    _outputEqSignature = signature;
    _setMusicGain(_musicGain, force: true);
  }

  void _onAudioOutputChanged(Player player) {
    unawaited(
      _audioChanges.run(() => _applyOutputEqualizerNow(player)).catchError((Object error, StackTrace stack) {
        appLogger.w('Music output EQ could not be applied', error: error, stackTrace: stack);
        if (!_disposed) _errorsController.add(error);
      }),
    );
  }

  MediaItem? _continuationSeed;
  String? _continuationAccount;
  int _continuationEpoch = 0;
  bool _continuationLoading = false;
  Future<void>? _continuationTask;
  int _continuationResumeRevision = 0;
  final Set<String> _continuationExcluded = {};

  @override
  bool get continuationEnabled => _continuationSeed != null;
  @override
  bool get continuationLoading => _continuationLoading;

  @override
  void setContinuationEnabled(bool enabled) {
    _continuationEpoch++;
    _continuationLoading = false;
    _continuationTask = null;
    final seed = enabled ? _currentTrack : null;
    final client = seed == null ? null : _clientFor(seed);
    _continuationSeed = client == null || client.isOfflineMode ? null : seed;
    _continuationAccount = _continuationSeed == null ? null : musicAccountScope(client!);
    _continuationExcluded.clear();
    _persistSessionSnapshot();
    notifyListeners();
    if (continuationEnabled) unawaited(_extendStation());
  }

  Future<MusicDiscoveryBatch> _generateInstantMix(MediaItem seed, {bool Function()? current}) => MusicDiscovery(
    (item) => current?.call() == false ? null : _clientFor(item),
  ).generate(MusicRecipe(id: 'instant', title: seed.displayTitle, kind: MusicRecipeKind.mix, seeds: [seed]));

  Future<void> _extendStation() {
    if (_musicGroupFollower) return Future.value();
    if (_continuationLoading) return _continuationTask ?? Future.value();
    final seed = _continuationSeed;
    if (seed == null || _disposed || _queue.length - _queue.cursor > 12) {
      return Future.value();
    }
    final client = _clientFor(seed);
    if (client == null || client.isOfflineMode) return Future.value();
    final account = _continuationAccount;
    if (account == null || account != musicAccountScope(client)) {
      setContinuationEnabled(false);
      return Future.value();
    }
    final authentication = client.authenticationSessionId;
    final epoch = _continuationEpoch;
    final revision = _queueSessionRevision;
    _continuationLoading = true;
    notifyListeners();
    return _continuationTask = _fetchContinuation(
      seed,
      epoch,
      revision,
      () =>
          identical(client, _clientFor(seed)) &&
          identical(client.authenticationSessionId, authentication) &&
          account == musicAccountScope(client),
    );
  }

  Future<void> _fetchContinuation(MediaItem seed, int epoch, int revision, bool Function() authorized) async {
    bool current() => !_disposed && epoch == _continuationEpoch && revision == _queueSessionRevision;
    try {
      final batch = await _generateInstantMix(seed, current: () => current() && authorized());
      if (!current() || _musicGroupFollower) return;
      if (!batch.isCurrent()) throw StateError('Music continuation source changed');
      final tracks = MusicDiscovery.interleave(
        [batch.tracks],
        limit: 100,
        exclude: {..._queue.queue.map((t) => t.globalKey), ..._continuationExcluded},
      );
      if (tracks.isNotEmpty) {
        _queue.addToEnd(tracks);
        _afterQueueEdit();
      } else {
        // Finite libraries terminate instead of repeating the same request on
        // every position tick or silently recycling excluded tracks.
        _continuationSeed = null;
        _continuationAccount = null;
      }
    } catch (error) {
      if (current()) {
        _continuationSeed = null;
        _continuationAccount = null;
        _errorsController.add(error);
      }
    } finally {
      if (!_disposed && epoch == _continuationEpoch) {
        _continuationLoading = false;
        if (_continuationSeed == null) _persistSessionSnapshot();
        notifyListeners();
      }
    }
  }

  @override
  void shuffleAlbums() {
    _queue.shuffleAlbums();
    _afterQueueEdit();
  }

  @override
  Future<void> nextAlbum() async {
    final index = _queue.nextAlbumIndex();
    if (index != null) await jumpTo(index);
  }

  @override
  MusicSignalPath? get signalPath {
    final source = _currentSource;
    if (source == null) return null;
    final settings = SettingsService.instanceOrNull;
    final audio = source.mediaInfo?.audioTracks;
    final selected = audio == null || audio.isEmpty
        ? null
        : audio.where((track) => track.selected).firstOrNull ?? audio.first;
    return MusicSignalPath(
      offline: source.isOffline,
      method: source.playMethod ?? 'Unknown',
      engine: _player?.playerType ?? 'Unknown',
      codec: selected?.codec,
      channels: selected?.channels,
      normalization: _playbackOutput != null
          ? false
          : _audioPolicy != null
          ? _audioPolicy!.leveling != MusicLeveling.off
          : settings?.read(SettingsService.audioNormalization) ?? false,
      equalizer: _playbackOutput != null
          ? false
          : _audioPolicy != null
          ? _audioPolicy!.bands.any((band) => band != 0)
          : settings != null && SettingsService.audioEqualizerBandPrefs.any((pref) => settings.read(pref) != 0),
      fades: _sweetFadesEnabled && !_preserveAlbumGapless,
    );
  }

  bool? _karaokePassthrough;
  double _karaokeKey = 0, _karaokeTempo = 1;

  @override
  Future<void> setKaraokeControls({required double semitones, required double tempo}) async {
    if (!semitones.isFinite || !tempo.isFinite || semitones.abs() > 12 || tempo < .5 || tempo > 2) {
      throw ArgumentError('Karaoke key/tempo out of range');
    }
    final player = _player;
    if (player == null || player.disposed || player.playerType != 'mpv' || player is! AudioEffectsCapable) {
      throw UnsupportedError('Independent key and tempo require the MPV decoded-audio backend');
    }
    _karaokePassthrough ??= player.audioPassthroughActive;
    final effects = player as AudioEffectsCapable;
    try {
      await player.setAudioPassthrough(false);
      await effects.setAudioEffects((stereoWidth: 0, spatializer: false, pitchSemitones: semitones));
      await player.setRate(tempo);
      _karaokeKey = semitones;
      _karaokeTempo = tempo;
    } catch (_) {
      await effects.setAudioEffects((stereoWidth: 0, spatializer: false, pitchSemitones: _karaokeKey));
      await player.setRate(_karaokeTempo);
      rethrow;
    }
  }

  @override
  Future<void> resetKaraokeControls() async {
    final passthrough = _karaokePassthrough;
    if (passthrough == null) {
      return;
    }
    final player = _player;
    if (player != null && !player.disposed && player is AudioEffectsCapable) {
      await (player as AudioEffectsCapable).setAudioEffects((stereoWidth: 0, spatializer: false, pitchSemitones: 0));
      await player.setRate(1);
      await player.setAudioPassthrough(passthrough);
    }
    _karaokePassthrough = null;
    _karaokeKey = 0;
    _karaokeTempo = 1;
  }

  @override
  bool get hasNativeVisualizationAudio {
    final player = _player;
    return !_disposed &&
        player is NativeVisualizationAudioSource &&
        (player as NativeVisualizationAudioSource).nativeVisualizationAudioReady;
  }

  MusicPlaybackServiceImpl({
    required MultiServerManager serverManager,
    AppDatabase? database,
    this._libraryStore,
    this._offlineWatchService,
    MusicSourceResolver? resolver,
    this._audioPlayerFactory = Player.audio,
    @visibleForTesting Player Function(bool overlapCore)? overlapPlayerFactory,
    this._mediaControlsFactory = MediaControlsManager.new,
    this._completedConfirmDelay = const Duration(milliseconds: 400),
    this._sessionStore,
    this._positionPersistInterval = const Duration(seconds: 5),
    @visibleForTesting Future<void> Function(double)? volumePersistenceWriter,
    @visibleForTesting Random? queueRandom,
    this.onDispose,
    @visibleForTesting this._nativeHostFactory = CalderaNativeHost.new,
  }) : assert(resolver != null || database != null, 'database is required to build the default resolver'),
       _serverManager = serverManager,
       _resolver = resolver ?? ServerMusicSourceResolver(serverManager: serverManager, database: database!),
       // ignore: prefer_initializing_formals
       _overlapPlayerFactory = overlapPlayerFactory,
       _coordinator = PlaybackCoordinator.instance,
       _queue = MusicQueueController(random: queueRandom),
       _volumePersistenceWriter = volumePersistenceWriter ?? _writePersistedVolume {
    _coordinator.registerMusicSession(stopAndDispose: _stopForVideoClaim);
    // tvOS has no background-audio session in v1, so it pauses on
    // backgrounding. A car keeps observing the lifecycle only as the fallback
    // authority for vehicles that cannot report UX restrictions; where the
    // vehicle does report them, [_onCarRestrictionsChanged] is what starts and
    // stops audio, so a parked driver can leave the app and keep listening.
    // A session store additionally needs the lifecycle everywhere: the
    // backgrounding states are the position-flush accelerator, since mobile
    // offers no termination hook (#2148).
    if (PlatformDetector.isAppleTV() || PlatformDetector.isAutomotive() || _sessionStore != null) {
      _observesLifecycle = true;
      WidgetsBinding.instance.addObserver(this);
    }
    if (PlatformDetector.isAutomotive()) {
      CarUxRestrictionsService.instance.ensureStarted();
      CarUxRestrictionsService.instance.listenable.addListener(_onCarRestrictionsChanged);
      _observesCarRestrictions = true;
    }
    final settings = SettingsService.instanceOrNull;
    if (settings != null) {
      _sweetFadesSettingsListenable = settings.listenable(SettingsService.musicSweetFades)
        ..addListener(_onSweetFadesPreferenceChanged);
      _audioSettingsListenable = Listenable.merge([
        settings.listenable(SettingsService.audioNormalization),
        for (final pref in SettingsService.audioEqualizerBandPrefs) settings.listenable(pref),
      ])..addListener(_onAudioSettingsChanged);
    }
    if (_sessionStore != null) {
      unawaited(_maybeRestoreSession());
    }
    if (_libraryStore != null) {
      unawaited(_restoreAudioPolicy());
      unawaited(_restoreNativeEqualizer());
    }
  }

  static const _previousRestartThreshold = Duration(seconds: 3);
  static const _maxConsecutiveFailures = 3;

  /// How long a completed (eof-reached) signal must stay uncontradicted
  /// before it is treated as a genuine queue end — long enough for the
  /// boundary pulse's own eof-reached=false / transition to arrive, short
  /// enough to be imperceptible at a real queue end (see [_onCompleted]).
  /// Injectable so tests can collapse the confirmation window.
  final Duration _completedConfirmDelay;

  final MultiServerManager _serverManager;
  final OfflineWatchSyncService? _offlineWatchService;
  final MusicSourceResolver _resolver;
  final Player Function() _audioPlayerFactory;
  final Player Function(bool overlapCore)? _overlapPlayerFactory;
  final MediaControlsManager Function() _mediaControlsFactory;
  final PlaybackCoordinator _coordinator;
  final Future<void> Function(double) _volumePersistenceWriter;
  final void Function(MusicPlaybackServiceImpl)? onDispose;

  /// Per-profile last-session persistence; null disables restore (#2148).
  final MusicSessionStore? _sessionStore;

  /// Minimum spacing between throttled playhead writes while playing.
  final Duration _positionPersistInterval;

  final MusicQueueController _queue;
  int _queueEditRevision = 0;
  MusicPlaybackOutput? _playbackOutput;
  StreamSubscription<void>? _outputRevoked;
  int _outputRequest = 0;

  @override
  String? get remoteOutputName => _musicDeviceOutput?.name ?? _playbackOutput?.name;

  @override
  Future<bool> selectOutput(MusicPlaybackOutput? output, {bool resume = true}) async {
    if (_musicDeviceOutput != null) return false;
    final request = ++_outputRequest;
    if (_disposed || _currentTrack == null || _player == null) {
      if (output != null) await output.player.dispose();
      return false;
    }
    if (identical(output, _playbackOutput)) return true;
    final revision = groupControlRevision;
    final authority = _captureOutputAuthority();
    final track = _currentTrack!;
    final playhead = position;
    final wasPlaying = resume && isPlaying;
    bool current() => !_disposed && request == _outputRequest && revision == groupControlRevision;
    if (output == null) {
      _cancelOverlap();
      _finalizeCurrentTrack();
      final previous = _player!;
      unawaited(_outputRevoked?.cancel());
      _outputRevoked = null;
      _playbackOutput = null;
      _player = null;
      final generation = ++_generation;
      _invalidateArmRequests();
      _armed = null;
      _staleArm = null;
      for (final subscription in _playerSubs) {
        unawaited(subscription.cancel());
      }
      _playerSubs.clear();
      var resumeLocal = wasPlaying;
      try {
        await previous.stop();
      } catch (error) {
        resumeLocal = false;
        appLogger.d('Music output stop failed (${error.runtimeType})');
      }
      try {
        await previous.dispose();
      } catch (error) {
        resumeLocal = false;
        appLogger.d('Music output disposal failed (${error.runtimeType})');
      }
      if (_disposed || request != _outputRequest || generation != _generation) return false;
      await _openCurrent(
        generation,
        play: resumeLocal,
        initialPosition: playhead,
        newOccurrence: false,
        recoverFailures: resumeLocal,
      );
      return !_disposed && generation == _generation && _status != MusicPlaybackStatus.error;
    }
    final candidate = output.player;
    var committed = false;
    try {
      if (!authority() || !output.available) return false;
      final source = await output.resolve(track);
      if (!current() || !authority() || !output.available) return false;
      await candidate.open(Media(source.url, headers: source.headers, start: playhead), play: false);
      if (!current() || !authority() || !output.available) return false;
      final previous = _player!;
      _cancelOverlap();
      _finalizeCurrentTrack();
      final generation = ++_generation;
      _invalidateArmRequests();
      _armed = null;
      _staleArm = null;
      unawaited(_outputRevoked?.cancel());
      _playbackOutput = output;
      _player = candidate;
      _currentSource = source;
      _musicGain = 1;
      _wirePlayerStreams(candidate);
      _outputRevoked = output.revoked.listen((_) {
        if (!_disposed && identical(_playbackOutput, output)) {
          unawaited(
            selectOutput(null, resume: false).catchError((Object error) {
              if (!_disposed) _errorsController.add(error);
              return false;
            }),
          );
        }
      });
      committed = true;
      _setStatus(MusicPlaybackStatus.paused, forceNotify: true);
      _playheadJumpController.add(playhead);
      _bindTrackServices(track, source, newOccurrence: false, initialPosition: playhead);
      await previous.stop();
      await previous.dispose();
      if (_disposed || generation != _generation || !identical(_player, candidate)) return false;
      if (!output.available || !authority()) {
        await selectOutput(null, resume: false);
        return false;
      }
      await candidate.setVolume(_volume);
      if (wasPlaying && generation == _generation && request == _outputRequest) await play();
      return !_disposed && identical(_playbackOutput, output);
    } finally {
      if (!committed) {
        await candidate.stop();
        await candidate.dispose();
      }
    }
  }

  /// The peer protocol uses this only after the user explicitly requests a
  /// transfer. A selection alone never changes playback or output routing.
  MusicTransferSnapshot? captureTransfer() {
    if (_disposed ||
        _musicDeviceOutput != null ||
        _currentTrack == null ||
        (_status != MusicPlaybackStatus.playing && _status != MusicPlaybackStatus.paused)) {
      return null;
    }
    final snapshot = MusicTransferSnapshot(
      queue: _queue.captureState(),
      position: position,
      playing: isPlaying,
      playContext: _playContext,
    );
    try {
      snapshot.toJson(itemLimit: MusicTransferSnapshot.maxTransferItems);
      return snapshot;
    } on StateError {
      return null;
    }
  }

  @override
  MusicTransferOffer? offerTransfer() {
    final snapshot = captureTransfer();
    if (snapshot == null) return null;
    return MusicTransferOffer(
      snapshot,
      _queueSessionRevision,
      _generation,
      _queueEditRevision,
      _continuationResumeRevision,
    );
  }

  @override
  bool groupOfferCurrent(MusicTransferOffer offer) =>
      !_disposed &&
      _queueSessionRevision == offer.session &&
      _queueEditRevision == offer.edit &&
      _continuationResumeRevision == offer.transport;

  @override
  Object get groupControlRevision =>
      (_queueSessionRevision, _queueEditRevision, _continuationResumeRevision, _generation);

  bool _musicGroupFollower = false;
  bool _resumeGroupTracking = false;
  @override
  bool get isMusicGroupFollower => _musicGroupFollower;

  @override
  void setMusicGroupFollower(bool follower) {
    if (_disposed || _musicGroupFollower == follower) return;
    if (follower) _finalizeCurrentTrack();
    _musicGroupFollower = follower;
    _resumeGroupTracking = !follower;
    final track = _currentTrack;
    final source = _currentSource;
    if (!follower && isPlaying && track != null && source != null) {
      _bindTrackServices(track, source);
    }
    notifyListeners();
  }

  @override
  bool Function() captureGroupAuthority() {
    if (_playbackOutput != null || _musicDeviceOutput != null) return () => false;
    return _captureOutputAuthority();
  }

  bool Function() _captureOutputAuthority() {
    final clients = <MediaServerClient, Object?>{};
    for (final item in _queue.queue) {
      final client = _clientFor(item);
      if (client == null || client.isOfflineMode) return () => false;
      clients[client] = client.authenticationSessionId;
    }
    return () =>
        !_disposed &&
        clients.isNotEmpty &&
        clients.entries.every(
          (entry) =>
              identical(entry.key.authenticationSessionId, entry.value) &&
              identical(_serverManager.getClient(entry.key.serverId), entry.key) &&
              _serverManager.isServerVisible(entry.key.serverId),
        );
  }

  @override
  Future<bool> finishTransfer(MusicTransferOffer offer) async {
    if (_disposed ||
        _queueSessionRevision != offer.session ||
        _generation != offer.generation ||
        _queueEditRevision != offer.edit ||
        _continuationResumeRevision != offer.transport ||
        _status != (offer.snapshot.playing ? MusicPlaybackStatus.playing : MusicPlaybackStatus.paused) ||
        _currentTrack?.globalKey !=
            offer.snapshot.queue.items[offer.snapshot.queue.order[offer.snapshot.queue.cursor]].globalKey) {
      return false;
    }
    if (offer.snapshot.playing) await pause();
    return !_disposed &&
        _queueSessionRevision == offer.session &&
        _generation == offer.generation &&
        _queueEditRevision == offer.edit &&
        _continuationResumeRevision == offer.transport + (offer.snapshot.playing ? 1 : 0) &&
        _status == MusicPlaybackStatus.paused;
  }

  /// Validate *this receiver's* active server credentials before changing its
  /// queue. The sender's metadata never grants access or provides a stream URL.
  /// An open failure is not acknowledged, so the sender retains its playback.
  @override
  Future<bool> acceptTransfer(MusicTransferSnapshot snapshot, {bool Function()? current}) =>
      _acceptTransfer(snapshot, current: current);

  @override
  Future<bool> prepareGroupTransfer(MusicTransferSnapshot snapshot, {required bool Function() current}) =>
      _acceptTransfer(snapshot, current: current, group: true);

  Future<bool> _acceptTransfer(
    MusicTransferSnapshot snapshot, {
    bool Function()? current,
    bool group = false,
    MusicSource? preparedSource,
  }) async {
    bool active() => current?.call() ?? true;
    try {
      snapshot.toJson(itemLimit: group ? MusicTransferSnapshot.maxItems : MusicTransferSnapshot.maxTransferItems);
    } on StateError {
      return false;
    }
    if (_disposed || !active() || (snapshot.playing && !automotiveMusicPlaybackAllowedNow())) return false;
    final clients = <MediaServerClient, Object?>{};
    for (final item in snapshot.queue.items) {
      final serverId = serverIdOrNull(item.serverId);
      if (serverId == null || !_serverManager.isServerVisible(serverId)) return false;
      final client = _serverManager.getClient(serverId);
      if (client == null || client.backend != item.backend || client.isOfflineMode) return false;
      clients[client] = client.authenticationSessionId;
    }
    final track = snapshot.queue.items[snapshot.queue.order[snapshot.queue.cursor]];
    final intent = beginPlayIntent();
    final generation = _generation;
    final edit = _queueEditRevision;
    final transport = _continuationResumeRevision;
    MusicSource source;
    try {
      source = preparedSource ?? await _cachedSource(await _resolver.resolve(track));
    } catch (error, stackTrace) {
      appLogger.w('Music transfer source could not be prepared', error: error, stackTrace: stackTrace);
      return false;
    }
    if (source.reportingClient != null &&
        !identical(source.reportingClient, _serverManager.getClient(ServerId(track.serverId!)))) {
      return false;
    }
    if (!active() ||
        !isPlayIntentCurrent(intent) ||
        generation != _generation ||
        edit != _queueEditRevision ||
        transport != _continuationResumeRevision ||
        clients.entries.any(
          (entry) =>
              !identical(entry.key.authenticationSessionId, entry.value) ||
              !identical(_serverManager.getClient(entry.key.serverId), entry.key) ||
              !_serverManager.isServerVisible(entry.key.serverId),
        )) {
      return false;
    }
    final expectedRevision = _queueSessionRevision + 1;
    if (group) setMusicGroupFollower(true);
    await _startQueue(
      tracks: snapshot.queue.items,
      playContext:
          snapshot.playContext ?? MusicPlayContext(title: track.title ?? track.id, kind: MusicPlayContextKind.tracks),
      autoplay: snapshot.playing,
      initialPosition: snapshot.position,
      restoredQueue: snapshot.queue,
      preparedSource: source,
    );
    if (!active()) {
      // The pairing disappeared or the request expired while opening. Leave
      // newer local actions alone; retire only the queue this request opened.
      if (!_disposed && _queueSessionRevision == expectedRevision && _generation == generation + 1) await stop();
      return false;
    }
    final accepted =
        !_disposed &&
        _queueSessionRevision == expectedRevision &&
        _queue.current?.globalKey == track.globalKey &&
        _status == (snapshot.playing ? MusicPlaybackStatus.playing : MusicPlaybackStatus.paused);
    if (!accepted &&
        !_disposed &&
        _queueSessionRevision == expectedRevision &&
        _queueEditRevision == edit &&
        _continuationResumeRevision == transport) {
      await _stopSession(endStatus: MusicPlaybackStatus.idle);
    }
    return accepted;
  }

  /// Bounded per-service cache. The endpoint is optional and profiles are
  /// small (at most 512 samples), so keeping a few recent queue items avoids
  /// repeat requests without persisting server-derived data across sessions.
  final Map<String, Future<AudioLoudnessProfile?>> _loudnessProfileRequests = {};
  final Map<String, AudioLoudnessProfile?> _loadedLoudnessProfiles = {};
  AudioLoudnessProfile? _currentLoudnessProfile;
  bool _fadeCurrentTrackIn = false;
  (int, int, bool)? _albumGaplessKey;
  bool _albumGapless = false;
  double _musicGain = 1;
  bool _workspaceAudioEnabled = true;
  Listenable? _sweetFadesSettingsListenable;
  Listenable? _audioSettingsListenable;

  /// Persisted music volume (0–100), applied to every audio player instance
  /// (the core is recreated after video claims playback). Falls back to full
  /// volume when settings aren't bootstrapped (tests).
  double _volume = SettingsService.instanceOrNull?.read(SettingsService.musicVolume) ?? 100.0;
  late final ValueNotifier<double> _volumeNotifier = ValueNotifier<double>(_volume);
  // One settings write stays in flight while rapid updates replace the single
  // pending slot. The drain intentionally survives service disposal.
  double? _pendingVolumeWrite;
  Future<void>? _volumeWriteDrain;

  Player? _player;
  Player? _overlapStartingPlayer;
  _MusicOverlap? _overlap;
  int _overlapRevision = 0;
  int _overlapAttemptedGeneration = -1;
  bool _primaryUsesOverlapCore = false;
  final List<StreamSubscription<Object?>> _playerSubs = [];

  @override
  AudioSpectrumAnalyzer? get audioSpectrumAnalyzer =>
      _player is AudioSpectrumAnalyzer ? _player! as AudioSpectrumAnalyzer : null;

  MediaControlsManager? _mediaControls;
  StreamSubscription<MediaControlEvent>? _controlEventsSub;

  /// Foreground hardware media keys (Android HID remotes, #1948). Same
  /// lifecycle as [_mediaControls]; routes to the same methods as
  /// [_mediaControlRouter].
  MusicHardwareTransportHandler? _hardwareTransport;

  /// Companion-remote transport buttons (a paired phone), installed on
  /// [CompanionRemoteReceiver] for the same lifecycle as [_hardwareTransport].
  late final bool Function(RemoteCommandType type) _remoteTransport = _handleRemoteTransport;

  MusicPlaybackStatus _status = MusicPlaybackStatus.idle;
  MediaItem? _currentTrack;
  MusicSource? _currentSource;
  MusicPlayContext? _playContext;
  PlaybackProgressTracker? _tracker;
  _ArmedTrack? _armed;

  /// The arm most recently cleared for a re-arm (generation-gated): a queue
  /// edit can un-arm an entry in the same instant mpv rolls into it, so the
  /// resulting transition must stay adoptable — dropping it leaves the
  /// service tracking the finished track for the entire next file.
  _ArmedTrack? _staleArm;
  int _staleArmGeneration = -1;
  Timer? _completedConfirmTimer;

  /// Bumped on every open/advance/stop so stale async continuations
  /// (resolves, opens, arms) drop out instead of acting on the new state.
  int _generation = 0;

  /// Queue construction can involve a server round-trip before playback is
  /// replaced. Only the latest explicit play intent may commit its result.
  int _playIntentGeneration = 0;

  /// Identifies the queue session that asynchronous enqueue work belongs to.
  int _queueSessionRevision = 0;
  int _playbackOccurrenceRevision = 0;

  @override
  int get playbackOccurrenceRevision => _playbackOccurrenceRevision;

  /// Gapless arm work is serialized into one latest-request slot. The
  /// generation stales continuations while the pending flag distinguishes
  /// an explicit recomputation request from cancellation-only invalidation.
  int _armRequestGeneration = 0;
  bool _armRequestPending = false;
  Future<void>? _armDrain;

  /// The generation whose replacement [Player.open] has not committed yet.
  /// Requests remain pending while an open owns the native playlist.
  int? _openingGeneration;

  int _consecutiveFailures = 0;
  _PendingResume? _pendingRestoreResume;
  PlaybackLaunchObserver? _launchObserver;
  int? _observedGeneration;
  bool _observedReady = false;
  int? _observedSourceId;

  Map<String, dynamic> _launchSnapshot() {
    final current = _launchObserver?.isCurrent == true && _observedGeneration == _generation;
    if (!current) {
      return const {'stage': 'cancelled', 'playing': false, 'buffering': false};
    }
    final state = _player?.state;
    final failed = _status == MusicPlaybackStatus.error || _launchObserver?.failure != null;
    final ready = _observedReady;
    final blocked = !automotiveMusicPlaybackAllowedNow();
    return {
      'stage': failed
          ? 'failed'
          : blocked
          ? 'blocked'
          : state?.completed == true
          ? 'completed'
          : ready && state?.buffering == true
          ? 'buffering'
          : ready && state?.playing == true
          ? 'playing'
          : ready
          ? 'paused'
          : 'opening',
      'ready': ready,
      'playing': ready && state?.isActive == true && !failed,
      'buffering': state?.buffering ?? false,
      'positionMs': _player?.currentPosition.inMilliseconds ?? 0,
      'durationMs': state?.duration.inMilliseconds ?? 0,
      if (blocked) 'blocker': 'automotiveRestricted',
      if (failed) 'failure': const {'code': 'playbackFailed'},
    };
  }

  void _markLaunchTerminal(String stage, {String? failure}) {
    if (_observedGeneration != _generation) {
      return;
    }
    // Capture once, before generation changes or teardown clears the native
    // player. A source that never started must not inherit an old playhead.
    final player = _observedSourceId == null ? null : _player;
    _launchObserver?.mark(
      stage,
      failure: failure,
      positionMs: player?.currentPosition.inMilliseconds,
      durationMs: player?.state.duration.inMilliseconds,
    );
  }

  DateTime _lastPositionPersist = DateTime.fromMillisecondsSinceEpoch(0);
  bool _resumeAfterInterruption = false;
  bool _disposed = false;
  bool _observesLifecycle = false;
  bool _observesCarRestrictions = false;

  /// Set when the vehicle's restrictions stopped playback, so the track can be
  /// resumed the moment the car is parked again instead of leaving the driver
  /// to hunt for the play button.
  bool _pausedByCarRestriction = false;

  /// Whether a restriction-owned pause is still in flight, so a lift arriving
  /// mid-pause does not read `isPlaying` and conclude nothing needs resuming.
  bool _carPauseInFlight = false;

  /// Whether a restriction-owned resume is still in flight, so a restriction
  /// arriving mid-resume does not read `isPlaying` and conclude nothing is ours.
  bool _carResumeInFlight = false;

  /// Last value handed to `setBackgroundMode`, so a vehicle answer that changes
  /// nothing does not re-enter the native foreground-service policy.
  bool? _carBackgroundModeApplied;

  /// Whether this vehicle reports its own driver-distraction state. Only then
  /// can audio outlive the activity: the restriction signal, not the app being
  /// on screen, is what stops playback for driving.
  bool get _carBackgroundAudioAvailable =>
      PlatformDetector.isAutomotiveMedia() || CarUxRestrictionsService.instance.state != CarUxRestrictionState.unknown;

  Timer? _sleepTimer;
  Duration? _sleepTimerDuration;
  bool _sleepTimerEndOfTrack = false;

  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration?> _playheadJumpController = StreamController<Duration?>.broadcast();
  final StreamController<Object> _errorsController = StreamController<Object>.broadcast();

  // ---------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------

  @override
  MediaItem? get currentTrack => _musicDeviceOutput == null ? _currentTrack : _musicDeviceOutput?.state?.track;

  @override
  MusicPlaybackStatus get status {
    final output = _musicDeviceOutput;
    if (output == null) return _status;
    final snapshot = output.state?.snapshot;
    return snapshot == null
        ? MusicPlaybackStatus.idle
        : snapshot.playing
        ? MusicPlaybackStatus.playing
        : MusicPlaybackStatus.paused;
  }

  @override
  Duration? get duration {
    final native = _nativeNowPlaying;
    if (_calderaAudioOwner != null && native != null) return Duration(milliseconds: native.snapshot.duration);
    final output = _musicDeviceOutput;
    if (output != null) {
      final millis = output.state?.track?.durationMs;
      return millis == null ? null : Duration(milliseconds: millis);
    }
    if (_currentTrack == null) {
      return null;
    }
    final playerDuration = _player?.state.duration ?? Duration.zero;
    if (playerDuration > Duration.zero) {
      return playerDuration;
    }
    final ms = _currentTrack?.durationMs;
    return ms != null ? Duration(milliseconds: ms) : null;
  }

  @override
  Duration get position => _musicDeviceOutput == null
      ? _nativePosition ?? _player?.currentPosition ?? _pendingRestoreResume?.position ?? Duration.zero
      : _musicDeviceOutput?.state?.snapshot?.position ?? Duration.zero;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get playheadJumpStream => _playheadJumpController.stream;

  @override
  List<MediaItem> get queue => _musicDeviceOutput == null ? _queue.queue : _musicDeviceOutput?.state?.queue ?? const [];

  @override
  int get currentIndex => _musicDeviceOutput == null ? _queue.cursor : _musicDeviceOutput?.state?.index ?? -1;

  @override
  MusicPlayContext? get playContext =>
      _musicDeviceOutput == null ? _playContext : _musicDeviceOutput?.state?.snapshot?.playContext;

  @override
  bool get shuffled =>
      _musicDeviceOutput == null ? _queue.shuffled : _musicDeviceOutput?.state?.snapshot?.queue.shuffled ?? false;

  @override
  MusicRepeatMode get repeatMode => _musicDeviceOutput == null
      ? _queue.repeatMode
      : _musicDeviceOutput?.state?.snapshot?.queue.repeatMode ?? MusicRepeatMode.off;

  @override
  Stream<Object> get errors => _errorsController.stream;

  @override
  bool get sleepTimerActive => _sleepTimer != null || _sleepTimerEndOfTrack;

  @override
  Duration? get sleepTimerDuration => _sleepTimerDuration;

  @override
  bool get sleepTimerEndOfTrack => _sleepTimerEndOfTrack;

  @override
  int beginPlayIntent() => ++_playIntentGeneration;

  @override
  bool isPlayIntentCurrent(int intent) => !_disposed && intent == _playIntentGeneration;

  @override
  int get queueSessionRevision => _musicDeviceOutput == null ? _queueSessionRevision : -_musicDeviceRevision;

  // ---------------------------------------------------------------------
  // Session start
  // ---------------------------------------------------------------------

  @override
  Future<void> playFromList({
    required List<MediaItem> tracks,
    MediaItem? startTrack,
    required MusicPlayContext playContext,
    bool shuffle = false,
    Duration? initialPosition,
    bool offline = false,
    PlaybackLaunchObserver? launchObserver,
  }) {
    final output = _musicDeviceOutput;
    if (output != null) {
      beginPlayIntent();
      if (offline || launchObserver != null) {
        _errorsController.add(StateError('This playback source requires this device'));
        return Future.value();
      }
      final queue = MusicQueueController()..load(tracks, shuffle: shuffle);
      if (startTrack != null) {
        final index = tracks.indexWhere((item) => identical(item, startTrack));
        final fallback = tracks.indexWhere((item) => item.globalKey == startTrack.globalKey);
        queue.load(tracks, startIndex: index < 0 ? (fallback < 0 ? null : fallback) : index, shuffle: shuffle);
      }
      return output
          .playSnapshot(
            MusicTransferSnapshot(
              queue: queue.captureState(),
              position: initialPosition ?? Duration.zero,
              playing: true,
              playContext: playContext,
            ),
          )
          .then((accepted) {
            if (!accepted && !_disposed && identical(output, _musicDeviceOutput)) {
              _errorsController.add(StateError('Music device could not start this queue'));
            }
          });
    }
    beginPlayIntent();
    return _startQueue(
      tracks: tracks,
      startTrack: startTrack,
      playContext: playContext,
      shuffle: shuffle,
      initialPosition: initialPosition,
      offline: offline,
      launchObserver: launchObserver,
    );
  }

  @override
  Future<InstantMixOutcome> playInstantMix(MediaItem seed) async {
    final intent = beginPlayIntent();
    final client = _clientFor(seed);
    if (client == null || client.isOfflineMode) {
      if (!isPlayIntentCurrent(intent)) {
        return InstantMixOutcome.superseded;
      }
      throw PlaybackException(t.music.instantMixNoServer, reason: PlaybackFailureReason.serverUnavailable);
    }
    final account = musicAccountScope(client);
    MusicDiscoveryBatch batch;
    try {
      batch = await _generateInstantMix(seed);
    } catch (e, st) {
      if (!isPlayIntentCurrent(intent)) {
        return InstantMixOutcome.superseded;
      }
      appLogger.w('Instant mix fetch failed for ${seed.id}', error: e, stackTrace: st);
      rethrow;
    }
    if (!isPlayIntentCurrent(intent) || !batch.isCurrent()) {
      return InstantMixOutcome.superseded;
    }
    if (batch.tracks.isEmpty) {
      return InstantMixOutcome.empty;
    }
    final expectedRevision = _queueSessionRevision + (_calderaAudioOwner != null ? 2 : 1);
    await _startQueue(
      tracks: batch.tracks,
      playContext: MusicPlayContext(title: seed.displayTitle, kind: MusicPlayContextKind.mix),
    );
    if (_disposed || _queueSessionRevision != expectedRevision) return InstantMixOutcome.superseded;
    if (batch.isCurrent()) {
      _continuationSeed = seed;
      _continuationAccount = account;
      _persistSessionSnapshot();
      unawaited(_extendStation());
    }
    return InstantMixOutcome.started;
  }

  Future<void> _startQueue({
    required List<MediaItem> tracks,
    MediaItem? startTrack,
    required MusicPlayContext playContext,
    bool shuffle = false,
    bool autoplay = true,
    Duration? initialPosition,
    bool offline = false,
    PlaybackLaunchObserver? launchObserver,
    MusicQueueState? restoredQueue,
    MusicSource? preparedSource,
  }) async {
    if (tracks.isEmpty || _disposed) {
      return;
    }
    if (launchObserver != null && !launchObserver.isCurrent) {
      return;
    }
    beginPlayIntent();
    final nativeOwner = _calderaAudioOwner;
    if (nativeOwner != null) {
      final ending = closeCalderaAudio(nativeOwner);
      final stoppingIntent = _playIntentGeneration;
      unawaited(leaveNativeMusicGroup());
      await ending;
      if (!isPlayIntentCurrent(stoppingIntent)) return;
    }
    _queueSessionRevision++;
    _continuationEpoch++;
    _continuationSeed = null;
    _continuationAccount = null;
    _continuationLoading = false;
    _continuationTask = null;
    _continuationExcluded.clear();
    // A new queue is a new decision: the vehicle's claim on whatever it stopped
    // before must not make parking auto-start this one.
    _pausedByCarRestriction = false;
    // Android 13+: the background playback notification needs
    // POST_NOTIFICATIONS. Fire-and-forget — playback and the foreground
    // service run regardless; a denial only hides the notification.
    //
    // A car asks later, from `_openCurrent`, once the vehicle has answered:
    // asking here would decide against the notification before the verdict
    // exists. Where the vehicle cannot report restrictions the answer is "never
    // ask" anyway — `setBackgroundMode(false)` holds, so the foreground service
    // and its notification never start and there is nothing to authorize, while
    // the prompt would take focus and the lifecycle fallback would then read the
    // app as restricted and drop the user's play intent.
    if (!PlatformDetector.isAutomotive()) {
      unawaited(NotificationPermission.ensure());
    }
    final generation = ++_generation;
    _launchObserver?.detach();
    _launchObserver = launchObserver;
    _observedGeneration = generation;
    _observedReady = false;
    _observedSourceId = null;
    launchObserver?.attach(
      _launchSnapshot,
      ownsPlayback: () =>
          !_disposed && _launchObserver == launchObserver && _observedGeneration == generation && _currentTrack != null,
    );
    _invalidateArmRequests();
    _finalizeCurrentTrack();
    // Null start index = "no track has to play first", which is what lets a
    // shuffled queue randomize its head too. Collapsing that into 0 pinned
    // every shuffle launch to the list's first track (#1811) — including a
    // start track the list turns out not to contain.
    int? startIndex;
    if (startTrack != null) {
      var index = startTrack.playlistItemId == null
          ? -1
          : tracks.indexWhere(
              (track) => track.globalKey == startTrack.globalKey && track.playlistItemId == startTrack.playlistItemId,
            );
      if (index < 0) index = tracks.indexWhere((track) => identical(track, startTrack));
      if (index < 0) index = tracks.indexWhere((track) => track.globalKey == startTrack.globalKey);
      if (index >= 0) {
        startIndex = index;
      }
    }
    if (restoredQueue != null) {
      if (!_queue.restoreState(restoredQueue)) return;
    } else {
      _queue.load(tracks, startIndex: startIndex, shuffle: shuffle);
    }
    _playContext = playContext;
    _consecutiveFailures = 0;
    _pendingRestoreResume = null;
    _persistSessionSnapshot(positionOverride: Duration.zero);
    await _openCurrent(
      generation,
      play: autoplay,
      initialPosition: initialPosition,
      offline: offline,
      preparedSource: preparedSource,
    );
  }

  // ---------------------------------------------------------------------
  // Opening / advancing
  // ---------------------------------------------------------------------

  /// Resolve and open the queue's current track. All failure handling funnels
  /// through [_handlePlaybackFailure].
  Future<void> _openCurrent(
    int generation, {
    bool play = true,
    Duration? initialPosition,
    bool offline = false,
    MusicSource? preparedSource,
    bool newOccurrence = true,
    bool recoverFailures = true,
  }) async {
    final track = _queue.current;
    if (track == null) {
      return;
    }
    _openingGeneration = generation;
    final observer = _observedGeneration == generation ? _launchObserver : null;
    bool launchCurrent() => generation == _generation && (observer?.isCurrent ?? true);
    void failed(Object error) {
      if (!launchCurrent()) return;
      if (recoverFailures) {
        _handlePlaybackFailure(error);
      } else {
        _currentSource = null;
        _pendingRestoreResume = _PendingResume(globalKey: track.globalKey, position: initialPosition ?? Duration.zero);
        _errorsController.add(error);
        _setStatus(MusicPlaybackStatus.error, forceNotify: true);
      }
    }

    Player? committedPlayer;
    try {
      _currentTrack = track;
      _currentSource = null;
      _armed = null;
      _staleArm = null;
      _setStatus(MusicPlaybackStatus.loading, forceNotify: true);

      await _coordinator.claimMusic();
      if (!launchCurrent()) {
        return;
      }
      // When video or another non-music surface owns workspace audio, keep a
      // newly started music session silent until the user assigns it focus.
      _workspaceAudioEnabled = !_coordinator.workspaceHasCompetingAudioOwner;
      // Settle the vehicle's answer before the opt-in below reads it: a cold
      // start would otherwise configure the session as if the car were mute and
      // leave background audio off until the next track.
      if (PlatformDetector.isAutomotive()) {
        await CarUxRestrictionsService.instance.ensureResolved();
        if (!launchCurrent()) {
          return;
        }
      }
      final player = await _ensurePlayer();
      if (!launchCurrent() || _player != player) {
        return;
      }
      await player.setWorkspaceAudioFocusEnabled(_workspaceAudioEnabled);
      if (!launchCurrent() || _player != player) {
        return;
      }
      _ensureMediaControls();
      // Re-asserted per open (cheap, idempotent): the native side drops the
      // background-mode opt-in when the user swipes the task away, so a
      // session that survives task removal heals itself here.
      //
      // A car gets the foreground service too, but only once the vehicle can
      // report its UX restrictions: that is what stops audio for driving, so
      // playback no longer has to be tied to the app being on screen. Without
      // that signal the opt-in stays off (and any stale one is healed), because
      // the lifecycle fallback would silence a backgrounded track anyway.
      final backgroundMode = !PlatformDetector.isAutomotive() || _carBackgroundAudioAvailable;
      _carBackgroundModeApplied = backgroundMode;
      unawaited(_mediaControls?.setBackgroundMode(backgroundMode));
      // The prompt `_startQueue` skipped on a car belongs here, where the verdict
      // exists: background audio needs the MediaStyle notification it authorizes.
      if (PlatformDetector.isAutomotive() && backgroundMode) {
        unawaited(NotificationPermission.ensure());
      }

      // Clear any native arm left over from the previous item before the open
      // replaces it, so a stray transition can't fire mid-switch.
      try {
        await player.setNext(null);
      } catch (e) {
        appLogger.d('setNext(null) before open failed', error: e);
      }

      MusicSource source;
      try {
        final output = _playbackOutput;
        if (output != null && !output.available) throw StateError('Music output is no longer available');
        source =
            preparedSource ??
            (output == null
                ? await _cachedSource(await _resolver.resolve(track, offline: offline))
                : await output.resolve(track));
      } catch (e, st) {
        appLogger.w('Music source resolve failed for ${track.id}', error: e, stackTrace: st);
        failed(e);
        return;
      }
      if (!launchCurrent() || _player != player) {
        return;
      }
      _currentSource = source;

      // Claim audio focus before audio starts so other media apps pause (mpv
      // has no built-in focus handling; harmless no-op off Android). Result is
      // ignored — mirrors the video screen, playback proceeds either way.
      try {
        await player.requestAudioFocus();
      } catch (e) {
        appLogger.d('Audio focus request failed', error: e);
      }
      if (!launchCurrent() || _player != player) {
        return;
      }

      final shouldPlay = play && automotiveMusicPlaybackAllowedNow();
      // A restored session's first open resumes at the persisted playhead;
      // any other open consumes (discards) a stale resume point.
      final restored = _consumePendingResume(track);
      final resumeAt = initialPosition ?? restored;
      try {
        await player.open(
          Media(source.url, headers: source.headers, start: resumeAt),
          play: shouldPlay,
        );
      } catch (e, st) {
        appLogger.w('Music open failed for ${track.id}', error: e, stackTrace: st);
        failed(e);
        return;
      }
      if (!launchCurrent() || _player != player) {
        return;
      }

      final playbackStarted = shouldPlay && automotiveMusicPlaybackAllowedNow();
      if (shouldPlay && !playbackStarted) {
        await player.pause();
        if (generation != _generation || _player != player) {
          return;
        }
      }
      committedPlayer = player;
      _setStatus(playbackStarted ? MusicPlaybackStatus.playing : MusicPlaybackStatus.paused);
      _bindTrackServices(track, source, newOccurrence: newOccurrence, initialPosition: resumeAt ?? Duration.zero);
    } finally {
      // A stale open must never release a newer open's ownership. Only a
      // committed current open schedules its successor; an unsuccessful
      // current open cancels requests collected while it was unresolved.
      if (_openingGeneration == generation) {
        _openingGeneration = null;
        if (committedPlayer != null && !_disposed && generation == _generation && _player == committedPlayer) {
          _requestArmNext();
        } else if (generation == _generation) {
          _invalidateArmRequests();
        } else {
          _ensureArmDrain();
        }
      }
    }
  }

  /// Manual advance: finalize the current tracker at its current position and
  /// open the queue entry at [cursor].
  Future<void> _advanceTo(int cursor, {bool play = true}) async {
    _cancelOverlap();
    final generation = ++_generation;
    _launchObserver?.detach();
    _invalidateArmRequests();
    _finalizeCurrentTrack();
    _pendingRestoreResume = null;
    _queue.jumpTo(cursor);
    _persistSessionProgress(positionOverride: Duration.zero);
    await _openCurrent(generation, play: play);
  }

  /// Arm (or clear) what the backend should auto-advance into. Skips the
  /// resolve round-trip when the desired target is already armed; repeat-one
  /// reuses the current track's resolved source.
  Future<void> _applyArmNext(int generation, int armRequest) async {
    if (_playbackOutput != null) return;
    final player = _player;
    if (player == null || !_isCurrentArmRequest(player, generation, armRequest)) {
      return;
    }

    final targetCursor = _sleepTimerEndOfTrack ? null : _queue.nextIndex();
    final target = targetCursor == null ? null : _queue.trackAt(targetCursor);

    if (target == null) {
      if (_armed == null) {
        return;
      }
      appLogger.d('Music: clearing arm (queue end / end-of-track sleep)');
      _rememberStaleArm();
      await _trySetNext(player, null);
      return;
    }
    if (_armed?.track.globalKey == target.globalKey) {
      return;
    }

    _rememberStaleArm();
    await _trySetNext(player, null);
    if (!_isCurrentArmRequest(player, generation, armRequest)) {
      return;
    }

    MusicSource source;
    if (targetCursor == _queue.cursor && _currentSource != null) {
      // Repeat-one: the same file plays again — reuse the resolved source.
      source = _currentSource!;
    } else {
      try {
        source = await _cachedSource(await _resolver.resolve(target));
      } catch (e, st) {
        // Fail soft: with nothing armed, the completed event falls back to
        // an explicit open of the next track (which retries the resolve).
        appLogger.w('Gapless arm resolve failed for ${target.id}', error: e, stackTrace: st);
        return;
      }
    }
    if (!_isCurrentArmRequest(player, generation, armRequest)) {
      return;
    }
    final armed = _ArmedTrack(track: target, source: source);
    _armed = armed;
    if (_sweetFadesEnabled) {
      unawaited(_loadLoudnessProfile(source, target));
    }
    appLogger.d('Music: arming cursor $targetCursor "${target.title}"');
    final ok = await _trySetNext(player, Media(source.url, headers: source.headers));
    if (ok && identical(_armed, armed)) _prefetchTrack(armed, player, generation, armRequest);
    if (!ok && identical(_armed, armed)) {
      // Nothing is armed natively; clear the record so the confirmed
      // completed fallback can advance explicitly instead of waiting for a
      // transition that can never come.
      _armed = null;
    }
  }

  bool _isCurrentArmRequest(Player player, int generation, int armRequest) {
    return !_disposed &&
        _openingGeneration == null &&
        generation == _generation &&
        armRequest == _armRequestGeneration &&
        _player == player;
  }

  void _requestArmNext() {
    if (_disposed || !automotiveMusicPlaybackAllowedNow()) {
      return;
    }
    _armRequestGeneration++;
    _armRequestPending = true;
    _ensureArmDrain();
  }

  void _invalidateArmRequests() {
    _armRequestGeneration++;
    _armRequestPending = false;
  }

  void _ensureArmDrain() {
    if (_disposed || !_armRequestPending || _openingGeneration != null || _armDrain != null) {
      return;
    }
    final drain = _drainArmRequests();
    _armDrain = drain;
    unawaited(
      drain.whenComplete(() {
        if (_armDrain != drain) {
          return;
        }
        _armDrain = null;
        if (!_disposed && _armRequestPending && _openingGeneration == null) {
          _ensureArmDrain();
        }
      }),
    );
  }

  Future<void> _drainArmRequests() async {
    while (!_disposed && _armRequestPending && _openingGeneration == null) {
      final armRequest = _armRequestGeneration;
      final generation = _generation;
      _armRequestPending = false;
      await _applyArmNext(generation, armRequest);
    }
  }

  /// Un-arm bookkeeping: [_armed] is cleared but remembered so
  /// [_onTrackTransition] can adopt a transition that raced the clear.
  void _rememberStaleArm() {
    if (_armed != null) {
      _staleArm = _armed;
      _staleArmGeneration = _generation;
    }
    _armed = null;
  }

  Future<bool> _trySetNext(Player player, Media? media) async {
    if (media != null && !automotiveMusicPlaybackAllowedNow()) {
      return false;
    }
    try {
      await player.setNext(media);
      return true;
    } catch (e) {
      appLogger.w('setNext failed', error: e);
      return false;
    }
  }

  /// Re-arm only when queue/mode changes altered what plays next — queue
  /// edits that keep the same next track cost no server round-trip.
  void _rearmIfNeeded() {
    if (_calderaAudioOwner != null) return;
    if (_player == null || _currentTrack == null) {
      return;
    }
    _requestArmNext();
  }

  // ---------------------------------------------------------------------
  // Player events
  // ---------------------------------------------------------------------

  Future<Player> _ensurePlayer() async {
    final existing = _player;
    final isNew = existing == null || existing.disposed;
    final player = existing == null || existing.disposed ? _audioPlayerFactory() : existing;
    if (isNew) {
      _player = player;
      _primaryUsesOverlapCore = false;
      _outputEqSignature = null;
      _outputEqualizer = null;
      _wirePlayerStreams(player);
    }
    if (_playbackOutput != null) return player;
    if (Platform.isAndroid) {
      // Configure logging before volume/focus/open can create the native core,
      // and refresh it on later opens if the debug preference changed.
      final debugLogging = SettingsService.instanceOrNull?.read(SettingsService.enableDebugLogging) ?? false;
      await player.setLogLevel(debugLogging ? 'v' : 'warn');
    }
    if (isNew &&
        _player == player &&
        !player.disposed &&
        (_volume != 100.0 || _outputGain != 1 || !_workspaceAudioEnabled)) {
      unawaited(player.setVolume(_musicVolume(player)));
    }
    if (isNew && _player == player && !player.disposed) {
      await _applyAudioPassthrough(player);
    }
    if (isNew && _player == player && !player.disposed && _sweetFadesEnabled && !Platform.isIOS) {
      // A second decoded stream must share the device. Exclusive WASAPI and
      // encoded passthrough cannot mix two volume-controlled outputs.
      await player.setProperty('audio-exclusive', 'no');
    }
    if (isNew && _player == player && !player.disposed) {
      await _applyAudioOutputDevice(player);
      await _applyMusicAudioSettings(player);
    }
    return player;
  }

  /// Apple platforms hand AC3/EAC3 to the system Dolby decoder, the only path
  /// that keeps Atmos in music (#2595). It shares the video Audio Passthrough
  /// setting, honoring the same normalization override the settings tile shows,
  /// and lands before the first open so the audio output starts on it rather
  /// than reloading mid-track; like video, a changed setting takes effect on
  /// the next player. Elsewhere passthrough claims the output device (exclusive
  /// WASAPI, IEC 61937 AudioTrack), which music playback does not opt into.
  void _onAudioSettingsChanged() {
    _cancelOverlap();
    final player = _player;
    if (player != null && !_disposed) {
      unawaited(
        _applyMusicAudioSettings(player).catchError((Object error, StackTrace stack) {
          appLogger.w('Music audio settings could not be applied', error: error, stackTrace: stack);
          if (!_disposed) _errorsController.add(error);
        }),
      );
    }
  }

  Future<void> _applyMusicAudioSettings(Player player) => _audioChanges.run(() => _applyMusicAudioSettingsNow(player));

  Future<void> _applyMusicAudioSettingsNow(Player player) async {
    if (_disposed || player.disposed || identical(_playbackOutput?.player, player)) return;
    final policy = _audioPolicy;
    if (policy != null) {
      await policy.apply(player, albumContext: !shuffled && _playContext?.kind == MusicPlayContextKind.album);
      _outputEqSignature = null;
      await _applyOutputEqualizerNow(player);
      await _restoreNativeEqualizerForPlayback(player);
      return;
    }
    final settings = SettingsService.instanceOrNull;
    if (player.disposed) return;
    if (settings == null) {
      await _restoreNativeEqualizerForPlayback(player);
      return;
    }
    await player.setAudioNormalization(settings.read(SettingsService.audioNormalization));
    if (player is AudioEqualizerCapable && !player.disposed) {
      await (player as AudioEqualizerCapable).setAudioEqualizer([
        for (final pref in SettingsService.audioEqualizerBandPrefs) settings.read(pref),
      ]);
    }
    _outputEqSignature = null;
    await _applyOutputEqualizerNow(player);
    await _restoreNativeEqualizerForPlayback(player);
  }

  Future<void> _applyAudioPassthrough(Player player) async {
    if (!PlayerNative.usesAppleAudioOutput) {
      return;
    }
    final settings = SettingsService.instanceOrNull;
    if (settings == null) {
      return;
    }
    if (!settings.read(SettingsService.audioPassthrough) || settings.read(SettingsService.audioNormalization)) {
      return;
    }
    try {
      await player.setAudioPassthrough(true);
    } catch (error, stackTrace) {
      appLogger.w('Music: audio passthrough not applied; decoding instead', error: error, stackTrace: stackTrace);
    }
  }

  /// The output picked in the video player's Audio Output menu, before the
  /// first open so the track starts there instead of moving mid-play. A pick
  /// made while this core is alive lands on the next one: video playback
  /// disposes it when it claims the session.
  Future<void> _applyAudioOutputDevice(Player player) async {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) {
      return;
    }
    await applyPreferredAudioDevice(player, settings.read(SettingsService.audioOutputDevice));
  }

  void _wirePlayerStreams(Player player) {
    for (final sub in _playerSubs) {
      sub.cancel();
    }
    _playerSubs
      ..clear()
      ..add(player.streams.position.listen(_onPosition))
      ..add(player.streams.playheadJump.listen(_playheadJumpController.add))
      ..add(player.streams.playing.listen(_onPlayingChanged))
      ..add(player.streams.trackTransition.listen(_onTrackTransition))
      ..add(player.streams.completed.listen(_onCompleted))
      ..add(player.streams.error.listen(_onPlayerError));
    _playerSubs.add(player.streams.audioDevice.listen((_) => _onAudioOutputChanged(player)));
    if (_launchObserver != null) {
      _playerSubs
        ..add(
          player.streams.sourceStarted.listen((event) {
            if (_player != player || _observedGeneration != _generation || _launchObserver?.isCurrent != true) {
              return;
            }
            _observedSourceId = event.sourceId;
            _observedReady = false;
          }),
        )
        ..add(
          player.streams.sourceReady.listen((event) {
            if (_player != player ||
                _observedGeneration != _generation ||
                _launchObserver?.isCurrent != true ||
                event.sourceId != _observedSourceId) {
              return;
            }
            _observedReady = true;
          }),
        )
        ..add(
          player.streams.sourceFailed.listen((event) {
            if (_player == player && _observedGeneration == _generation && event.sourceId == _observedSourceId) {
              _markLaunchTerminal('failed', failure: 'playbackFailed');
            }
          }),
        );
    }
  }

  void _onPosition(Duration position) {
    if (_calderaAudioOwner != null) {
      _positionController.add(_nativePosition ?? position);
      return;
    }
    if (_musicDeviceOutput != null) return;
    final reportingPlayer = _player;
    _positionController.add(position);
    _updateSweetFade(position);
    final overlap = _overlap;
    if (overlap != null && position >= (duration ?? Duration.zero) - const Duration(milliseconds: 30)) {
      _promoteOverlap(overlap);
    }
    if (_player != reportingPlayer) {
      _onPosition(_player?.currentPosition ?? Duration.zero);
      return;
    }
    // Real playback progress proves the pipeline recovered — reset the
    // consecutive-failure strike counter.
    if (_consecutiveFailures != 0 && position > Duration.zero && _status == MusicPlaybackStatus.playing) {
      _consecutiveFailures = 0;
    }
    final player = _player;
    if (player != null) {
      _mediaControls?.updatePlaybackState(isPlaying: player.state.isActive, position: position, speed: 1.0);
    }
    DiscordRPCService.instance.updatePosition(position);
    if (_status == MusicPlaybackStatus.playing) {
      _maybePersistPositionTick(position);
    }
  }

  void _onPlayingChanged(bool isPlaying) {
    if (_musicDeviceOutput != null) return;
    if (_calderaAudioOwner != null && _nativeNowPlaying != null) {
      if (isPlaying && !automotiveMusicPlaybackAllowedNow()) unawaited(_player?.pause());
      return;
    }
    final playbackAllowed = automotiveMusicPlaybackAllowedNow();
    final shouldBePlaying = isPlaying && playbackAllowed;
    if (isPlaying && !playbackAllowed) {
      unawaited(_player?.pause());
    }
    // The vehicle's claim is discharged here when a restriction-owned resume only
    // reports the transition now: leaving it set would let a later lifted verdict
    // restart a track that has since finished and parked at its end.
    if (shouldBePlaying && !_carPauseInFlight) {
      _pausedByCarRestriction = false;
    }
    if (_status == MusicPlaybackStatus.playing || _status == MusicPlaybackStatus.paused) {
      _setStatus(shouldBePlaying ? MusicPlaybackStatus.playing : MusicPlaybackStatus.paused);
      unawaited(_tracker?.sendProgress(shouldBePlaying ? 'playing' : 'paused'));
      // Gated like the tracker: while an open is loading, the player's
      // playing flips belong to a track whose presence is not bound yet.
      final rpc = DiscordRPCService.instance;
      unawaited(shouldBePlaying ? rpc.resumePlayback() : rpc.pausePlayback());
    }
    final player = _player;
    if (player != null) {
      _mediaControls?.updatePlaybackState(
        isPlaying: shouldBePlaying && player.state.isActive,
        position: player.currentPosition,
        speed: 1.0,
        force: true,
      );
    }
  }

  /// The backend auto-advanced into the pre-armed item: authoritative
  /// track change.
  void _onTrackTransition(String uri) {
    if (_musicDeviceOutput != null) return;
    _cancelOverlap();
    var armed = _armed;
    if ((armed == null || armed.source.url != uri) &&
        _staleArm != null &&
        _staleArmGeneration == _generation &&
        _staleArm!.source.url == uri) {
      // mpv rolled into the entry in the same instant a queue edit un-armed
      // it — the transition is still authoritative for what is audibly
      // playing.
      armed = _staleArm;
    }
    _staleArm = null;
    if (armed == null || armed.source.url != uri) {
      appLogger.w('Unexpected track transition to $uri (armed: ${armed?.source.url})');
      return;
    }
    final adopted = armed;
    _armed = null;
    _generation++;
    _launchObserver?.detach();
    _invalidateArmRequests();

    // The finished track played out fully — report stopped at its duration.
    // Without one, the player's own record of where the outgoing source got to:
    // by now its live position belongs to the track that replaced it.
    final finishedMs = _currentTrack?.durationMs;
    _finalizeCurrentTrack(
      positionOverride: finishedMs != null ? Duration(milliseconds: finishedMs) : _player?.outgoingSourcePosition,
    );

    // Move the cursor to the armed entry: the expected natural-next when it
    // still matches, otherwise wherever the armed track now sits.
    final expected = _queue.nextIndex();
    if (expected != null && _queue.trackAt(expected)?.globalKey == adopted.track.globalKey) {
      _queue.jumpTo(expected);
    } else {
      final index = _queue.queue.indexWhere((t) => t.globalKey == adopted.track.globalKey);
      if (index < 0) {
        // The track mpv advanced into was removed from the queue at the
        // boundary: don't adopt it — play what the queue says comes next,
        // or park when nothing does.
        appLogger.d('Music: transition into removed track "${adopted.track.title}" — advancing past it');
        final nextCursor = _queue.nextIndex();
        if (nextCursor != null) {
          unawaited(_advanceTo(nextCursor));
        } else {
          unawaited(_player?.pause());
          _parkAtEnd();
        }
        return;
      }
      _queue.jumpTo(index);
    }

    _currentTrack = _queue.current ?? adopted.track;
    _currentSource = adopted.source;
    _consecutiveFailures = 0;
    appLogger.d('Music: transition received "${adopted.track.title}" → cursor ${_queue.cursor}');
    _persistSessionProgress(positionOverride: Duration.zero);
    if (automotiveMusicPlaybackAllowedNow()) {
      _setStatus(MusicPlaybackStatus.playing, forceNotify: true);
    } else {
      unawaited(_player?.pause());
      _setStatus(MusicPlaybackStatus.paused, forceNotify: true);
    }
    _bindTrackServices(_currentTrack!, adopted.source, fadeIn: true);
    _requestArmNext();
  }

  /// Completed (eof-reached) is NOT a last-entry-only signal: mpv pulses it
  /// at every gapless boundary (the audio of the finished entry drains
  /// before the armed entry starts), and its delivery order against the
  /// trackTransition event is not guaranteed. A boundary pulse that lands
  /// after the transition already cleared [_armed] (re-arm still resolving)
  /// looks exactly like "queue advanced with nothing armed" — acting on it
  /// immediately double-advanced the queue (skipped a track, cut off the
  /// just-started file; live-captured on Android). So never act on the raw
  /// pulse: confirm it is stable first. A boundary pulse is followed by
  /// eof-reached=false / a transition within milliseconds (which resets
  /// `state.completed` and bumps [_generation]); at a genuine queue end,
  /// sleep-at-end-of-track, or failed arm it stays true, and the confirmed
  /// handler advances explicitly or parks.
  void _onCompleted(bool done) {
    if (_calderaAudioOwner != null) {
      if (done) unawaited(leaveNativeMusicGroup());
      return;
    }
    if (!done || _currentTrack == null || _status == MusicPlaybackStatus.idle) {
      return;
    }
    final overlap = _overlap;
    if (overlap != null) {
      _promoteOverlap(overlap);
      return;
    }
    appLogger.d('Music: completed received (armed=${_armed != null}, cursor ${_queue.cursor})');
    if (_armed != null) {
      return;
    } // The backend advances; trackTransition handles it.

    final generation = _generation;
    _completedConfirmTimer?.cancel();
    _completedConfirmTimer = Timer(_completedConfirmDelay, () {
      _completedConfirmTimer = null;
      if (_disposed || generation != _generation || _armed != null) {
        return;
      }
      if (_player?.state.completed != true) {
        return;
      } // stale boundary pulse
      appLogger.d('Music: completed confirmed (cursor ${_queue.cursor})');
      _handleQueueCompleted();
    });
  }

  /// Confirmed end of the current file with nothing armed: queue end,
  /// sleep-at-end-of-track, or a failed arm (fall back to an explicit open).
  void _handleQueueCompleted() {
    if (_sleepTimerEndOfTrack) {
      _sleepTimerEndOfTrack = false;
      _parkAtEnd();
      return;
    }

    final nextCursor = _queue.nextIndex();
    if (nextCursor != null) {
      unawaited(_advanceTo(nextCursor));
      return;
    }
    if (_continuationSeed != null) {
      unawaited(_finishAfterContinuation());
      return;
    }
    _parkAtEnd();
  }

  /// A slow refill may arrive after EOF. Wait for that one bounded request,
  /// while allowing pause, seek, stop and replacement queues to win the race.
  Future<void> _finishAfterContinuation() async {
    final generation = _generation;
    final resumeRevision = _continuationResumeRevision;
    await _extendStation().timeout(const Duration(seconds: 15), onTimeout: () {});
    if (_disposed ||
        generation != _generation ||
        resumeRevision != _continuationResumeRevision ||
        !isPlaying ||
        _player?.state.completed != true) {
      return;
    }
    final next = _queue.nextIndex();
    if (next != null) {
      await _advanceTo(next);
    } else {
      _parkAtEnd();
    }
  }

  /// Queue played out: report the final track stopped at its duration and
  /// park paused at the end. [currentTrack] stays set so the mini-player
  /// remains; pressing play restarts the current track from the top.
  void _parkAtEnd() {
    _markLaunchTerminal('completed');
    _generation++;
    _invalidateArmRequests();
    final finishedMs = _currentTrack?.durationMs;
    _finalizeCurrentTrack(positionOverride: finishedMs != null ? Duration(milliseconds: finishedMs) : null);
    _setStatus(MusicPlaybackStatus.paused, forceNotify: true);
    // Restore semantics for a played-out queue: replay the final track from
    // the top, not from its end. Written after [_setStatus] so its
    // playing→paused flush (which reads the live end-of-track position)
    // cannot overwrite this.
    _persistSessionProgress(positionOverride: Duration.zero);
    final player = _player;
    if (player != null) {
      _mediaControls?.updatePlaybackState(isPlaying: false, position: player.currentPosition, speed: 1.0, force: true);
    }
    unawaited(DiscordRPCService.instance.pausePlayback());
  }

  void _onPlayerError(PlayerError error) {
    if (_status == MusicPlaybackStatus.idle || _status == MusicPlaybackStatus.error) {
      return;
    }
    appLogger.w('Music player error: $error');
    _handlePlaybackFailure(error);
  }

  /// Shared recovery for resolve/open/player errors: surface, then skip to
  /// the next track; three consecutive strikes stop the session as failed.
  void _handlePlaybackFailure(Object error) {
    _markLaunchTerminal('failed', failure: 'playbackFailed');
    _errorsController.add(error);
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      unawaited(_stopSession(endStatus: MusicPlaybackStatus.error));
      return;
    }
    final nextCursor = _queue.nextIndex(manual: true);
    if (nextCursor == null) {
      unawaited(_stopSession(endStatus: MusicPlaybackStatus.error));
      return;
    }
    unawaited(_advanceTo(nextCursor));
  }

  // ---------------------------------------------------------------------
  // Per-track services (progress reporting + OS media controls)
  // ---------------------------------------------------------------------

  /// (Re)bind the per-track progress tracker, media-session metadata and
  /// Discord presence — the music mirror of the video screen's
  /// `_wirePerItemPlaybackServices`. The previous track must already be
  /// finalized.
  void _bindTrackServices(
    MediaItem track,
    MusicSource source, {
    bool fadeIn = false,
    bool newOccurrence = true,
    Duration initialPosition = Duration.zero,
  }) {
    _resumeGroupTracking = false;
    if (newOccurrence) _playbackOccurrenceRevision++;
    if (_audioPolicy != null) _onAudioSettingsChanged();
    unawaited(_extendStation());
    _tracker?.dispose();
    _tracker = null;
    final player = _player;
    if (player == null) {
      return;
    }

    final profileKey = _loudnessProfileCacheKey(source, track);
    _currentLoudnessProfile = profileKey == null ? null : _loadedLoudnessProfiles[profileKey];
    final trackDuration = duration ?? Duration.zero;
    final trackHeadLevel = _currentLoudnessProfile?.levelAt(const Duration(milliseconds: 300), trackDuration);
    _fadeCurrentTrackIn =
        fadeIn &&
        _sweetFadesEnabled &&
        !_preserveAlbumGapless &&
        trackDuration >= const Duration(seconds: 6) &&
        trackHeadLevel != null &&
        trackHeadLevel > -48;
    // Only write when the gain actually changes. `_ensurePlayer` already
    // applies the persisted volume to a newly-created player; forcing a 1.0
    // gain here emits a redundant volume write on every ordinary track bind.
    _setMusicGain(_fadeCurrentTrackIn ? 0 : 1);
    // An armed track's profile may already be cached. Avoid scheduling a
    // redundant completed-Future callback in that case: on a gapless
    // transition the native player's playhead can still describe the outgoing
    // track. A profile that was still in flight at the boundary also needs a
    // zero-based update below so that stale playhead cannot trigger an
    // end-of-track fade on the newly adopted source.
    if (_sweetFadesEnabled && _currentLoudnessProfile == null) {
      unawaited(
        _loadLoudnessProfile(source, track).then((profile) {
          if (_disposed || !identical(_currentSource, source)) {
            return;
          }
          _currentLoudnessProfile = profile;
          _updateSweetFade(fadeIn ? Duration.zero : player.currentPosition);
        }),
      );
    }

    // Every music bind starts its track at the top, but on a gapless advance
    // the player's state still carries the *finished* track's position and
    // duration when the transition is announced. Reporting that told Plex the
    // new track was already at ~100% and double-counted the play (#1849), so
    // the initial report is pinned to the track's own start instead of live
    // player state.
    final initialDuration = track.durationMs != null ? Duration(milliseconds: track.durationMs!) : null;

    final client = source.reportingClient;
    if (client != null && !_musicGroupFollower) {
      _tracker = PlaybackProgressTracker(
        client: client,
        metadata: track,
        player: player,
        offlineWatchService: _offlineWatchService,
        // Local files keep reporting online but queue locally when the
        // server rejects the report — same policy as downloaded video.
        queueOnOnlineFailure: source.isOffline && _offlineWatchService != null,
        playMethod: source.playMethod ?? 'DirectPlay',
        playSessionId: source.playSessionId,
        mediaInfo: source.mediaInfo,
      )..startTracking(initialPosition: initialPosition, initialDuration: initialDuration);
    } else if (source.isOffline && _offlineWatchService != null && !_musicGroupFollower) {
      _tracker = PlaybackProgressTracker(
        client: null,
        metadata: track,
        player: player,
        isOffline: true,
        offlineWatchService: _offlineWatchService,
      )..startTracking(initialPosition: initialPosition, initialDuration: initialDuration);
    }

    final metadataClient = client ?? _clientFor(track);
    final controls = _mediaControls;
    if (controls != null) {
      unawaited(
        controls.updateMetadata(
          metadata: track,
          client: metadataClient,
          duration: track.durationMs != null ? Duration(milliseconds: track.durationMs!) : null,
        ),
      );
      _syncControlsAvailability();
    }

    if (metadataClient != null) {
      final rpc = DiscordRPCService.instance;
      unawaited(rpc.startPlayback(track, metadataClient));
      // Callers set [_status] before binding; a restored session or a
      // car-restricted open binds paused, and presence must not run a
      // timer for a track that is not audible.
      if (_status != MusicPlaybackStatus.playing) {
        unawaited(rpc.pausePlayback());
      }
    }
    // Repeat-one retains the same item and queue index. Publish the occurrence
    // boundary so history/DJ observers do not merge consecutive performances.
    if (!_disposed) notifyListeners();
  }

  /// Stop tracking and fire the final `stopped` report for the current
  /// track (fire-and-forget; report sessions are per track so the next
  /// track's `started` can overlap safely).
  void _finalizeCurrentTrack({Duration? positionOverride}) {
    final tracker = _tracker;
    _tracker = null;
    if (tracker == null) {
      return;
    }
    tracker.stopTracking();
    unawaited(
      tracker.sendStoppedProgressOnce(positionOverride: positionOverride).catchError((Object e) {
        appLogger.d('Final music progress report failed', error: e);
      }),
    );
  }

  void _ensureMediaControls() {
    if (_mediaControls != null) {
      return;
    }
    final controls = _mediaControlsFactory();
    _mediaControls = controls;
    _controlEventsSub = controls.controlEvents.listen(_onControlEvent);
    _hardwareTransport ??= MusicHardwareTransportHandler(
      hasActiveSession: () => !_disposed && currentTrack != null,
      onPlay: () => unawaited(play()),
      onPause: () => unawaited(pause()),
      onTogglePlayPause: () => unawaited(togglePlayPause()),
      onNext: () => unawaited(next()),
      onPrevious: () => unawaited(previous()),
      onStop: () => unawaited(stop()),
      onSkipForward: () => unawaited(_seekRelative(_defaultSkipInterval)),
      onSkipBackward: () => unawaited(_seekRelative(-_defaultSkipInterval)),
    )..register();
    CompanionRemoteReceiver.instance.musicTransport = _remoteTransport;
  }

  @override
  Future<AudioLoudnessProfile?> loadCurrentTrackLoudnessProfile() async {
    final source = _currentSource;
    final track = _currentTrack;
    if (source == null || track == null) return null;
    final profile = await _loadLoudnessProfile(source, track);
    if (_disposed || !identical(_currentSource, source) || !identical(_currentTrack, track)) return null;
    if (profile != null) {
      final document = musicAnalysisDocument(track, profile);
      if (document != null) await _libraryStore?.saveDocument('analysis', track.globalKey, document);
      return profile;
    }
    final cached = await _libraryStore?.document('analysis', track.globalKey);
    if (_disposed || !identical(_currentSource, source) || !identical(_currentTrack, track)) return null;
    return musicAnalysisProfile(track, cached);
  }

  String? _loudnessProfileCacheKey(MusicSource source, MediaItem track) {
    if (source.isOffline) {
      return 'offline:${track.globalKey}:${track.updatedAt}:${source.url}';
    }
    final client = source.reportingClient;
    if (client == null || client is! PlexLoudnessProfileClient) {
      return null;
    }
    if (client.isOfflineMode) {
      return null;
    }
    final tracks = source.mediaInfo?.audioTracks;
    if (tracks == null) {
      return null;
    }
    for (final track in tracks) {
      if (track.selected) {
        return '${client.serverId}:${identityHashCode(client.authenticationSessionId)}:${track.id}';
      }
    }
    return null;
  }

  Future<AudioLoudnessProfile?> _loadLoudnessProfile(MusicSource source, MediaItem track) {
    if (source.isOffline) {
      final key = _loudnessProfileCacheKey(source, track)!;
      final cached = _loadedLoudnessProfiles[key];
      if (cached != null) return Future.value(cached);
      final store = _libraryStore;
      if (store == null || !store.active) return Future.value(null);
      return store.document('analysis', track.globalKey).then((document) {
        if (_disposed || !store.active) return null;
        final profile = musicAnalysisProfile(track, document);
        if (profile != null) {
          if (_loadedLoudnessProfiles.length >= 24) _loadedLoudnessProfiles.remove(_loadedLoudnessProfiles.keys.first);
          _loadedLoudnessProfiles[key] = profile;
        }
        return profile;
      });
    }
    final client = source.reportingClient;
    if (client == null || client is! PlexLoudnessProfileClient) {
      return Future.value(null);
    }
    final profileClient = client as PlexLoudnessProfileClient;
    if (client.isOfflineMode) {
      return Future.value(null);
    }
    final tracks = source.mediaInfo?.audioTracks;
    if (tracks == null) {
      return Future.value(null);
    }
    MediaAudioTrack? selectedTrack;
    for (final track in tracks) {
      if (track.selected) {
        selectedTrack = track;
        break;
      }
    }
    if (selectedTrack == null) {
      return Future.value(null);
    }

    final key = _loudnessProfileCacheKey(source, track)!;
    final cached = _loudnessProfileRequests[key];
    if (cached != null) {
      return cached;
    }
    if (_loudnessProfileRequests.length >= 24) {
      final oldestKey = _loudnessProfileRequests.keys.first;
      _loudnessProfileRequests.remove(oldestKey);
      _loadedLoudnessProfiles.remove(oldestKey);
    }

    final request = profileClient
        .fetchAudioLoudnessProfile(selectedTrack.id)
        .then<AudioLoudnessProfile?>(
          (profile) {
            if (!_disposed) {
              _loadedLoudnessProfiles[key] = profile;
            }
            return profile;
          },
          onError: (Object _, StackTrace _) {
            if (!_disposed) {
              _loadedLoudnessProfiles[key] = null;
            }
            appLogger.d('Music loudness profile unavailable');
            return null;
          },
        );
    _loudnessProfileRequests[key] = request;
    return request;
  }

  bool get _sweetFadesEnabled =>
      _playbackOutput == null && (SettingsService.instanceOrNull?.read(SettingsService.musicSweetFades) ?? false);

  bool get _preserveAlbumGapless {
    final albumLaunch = _playContext?.kind == MusicPlayContextKind.album;
    final key = (_queueSessionRevision, _queueEditRevision, albumLaunch);
    if (_albumGaplessKey != key) {
      _albumGaplessKey = key;
      _albumGapless = _queue.isOrderedAlbum(albumLaunch: albumLaunch);
    }
    return _albumGapless;
  }

  bool _overlapCurrent(Player outgoing, _ArmedTrack incoming, int generation, int revision) =>
      !_disposed &&
      _sweetFadesEnabled &&
      _player == outgoing &&
      _generation == generation &&
      _queueEditRevision == revision &&
      identical(_armed, incoming) &&
      _status == MusicPlaybackStatus.playing &&
      !_sleepTimerEndOfTrack &&
      automotiveMusicPlaybackAllowedNow();

  void _tryStartOverlap(Duration position, Duration trackDuration) {
    final outgoing = _player;
    final incoming = _armed;
    if (outgoing == null ||
        incoming == null ||
        (outgoing is! PlayerNative && _overlapPlayerFactory == null) ||
        _overlap != null ||
        _overlapStartingPlayer != null ||
        _overlapAttemptedGeneration == _generation ||
        _status != MusicPlaybackStatus.playing ||
        !outgoing.state.isActive ||
        _sleepTimerEndOfTrack ||
        outgoing.audioPassthroughActive ||
        !_workspaceAudioEnabled ||
        trackDuration - position > const Duration(milliseconds: 1800)) {
      return;
    }
    final nextDuration = incoming.track.durationMs;
    final key = _loudnessProfileCacheKey(incoming.source, incoming.track);
    final nextProfile = key == null ? null : _loadedLoudnessProfiles[key];
    if (nextProfile == null ||
        nextDuration == null ||
        nextDuration < 6000 ||
        (nextProfile.levelAt(const Duration(milliseconds: 300), Duration(milliseconds: nextDuration)) ?? -100) <= -48) {
      return;
    }
    _overlapAttemptedGeneration = _generation;
    unawaited(
      _startOverlap(outgoing, incoming, _generation, _queueEditRevision).catchError((Object error) {
        appLogger.d('Music overlap decoder unavailable', error: error);
      }),
    );
  }

  Future<void> _startOverlap(Player outgoing, _ArmedTrack incoming, int generation, int editRevision) async {
    final revision = _overlapRevision;
    final useOverlapCore = !_primaryUsesOverlapCore;
    final player =
        _overlapPlayerFactory?.call(useOverlapCore) ??
        (useOverlapCore ? PlayerNative.audio(overlap: true, exclusiveAudio: Platform.isIOS) : _audioPlayerFactory());
    _overlapStartingPlayer = player;
    bool current() => revision == _overlapRevision && _overlapCurrent(outgoing, incoming, generation, editRevision);
    try {
      await player.setWorkspaceAudioFocusEnabled(false);
      await player.setVolume(0);
      if (!Platform.isIOS) await player.setProperty('audio-exclusive', 'no');
      await _applyAudioOutputDevice(player);
      // Each decoder owns its own processing state. Do not let the spare core
      // update the primary core's output EQ signature while it is loading.
      final policy = _audioPolicy;
      if (policy != null) {
        await policy.apply(player, albumContext: false);
      } else {
        final settings = SettingsService.instanceOrNull;
        if (settings != null) {
          await player.setAudioNormalization(settings.read(SettingsService.audioNormalization));
          if (player is AudioEqualizerCapable) {
            await (player as AudioEqualizerCapable).setAudioEqualizer([
              for (final pref in SettingsService.audioEqualizerBandPrefs) settings.read(pref),
            ]);
          }
        }
      }
      if (_libraryStore != null && _calderaSource == null && player is AudioEqualizerCapable) {
        final output = await player.getProperty('audio-device') ?? 'auto';
        final eq = await outputEqualizer(output);
        if (eq != null) {
          await player.setAudioPassthrough(false);
          await (player as AudioEqualizerCapable).setAudioEqualizer(eq.bands);
        }
      }
      if (!current()) return;
      await _restoreNativeEqualizerForPlayback(player);
      if (!current()) return;
      final nativeSource = _calderaSource;
      if (nativeSource != null) {
        await nativeSource.prepareFeed(_nativePcmFeed(player, nativeSource, primary: false));
        if (!current()) return;
      }
      await player.open(Media(incoming.source.url, headers: incoming.source.headers));
      if (!current()) return;
      // The outgoing playlist must stop at this file. Keep its arm until the
      // second source has opened, so a slow/failed decoder stays gapless.
      if (!await _trySetNext(outgoing, null)) return;
      if (!current()) {
        if (_player == outgoing && _generation == generation) {
          _rememberStaleArm();
          _requestArmNext();
        }
        return;
      }
      _rememberStaleArm();
      _overlap = _MusicOverlap(player, incoming, generation, editRevision, useOverlapCore);
      _overlapStartingPlayer = null;
      _updateSweetFade(outgoing.currentPosition);
    } catch (error, stackTrace) {
      appLogger.w('Music overlap unavailable; keeping gapless playback', error: error, stackTrace: stackTrace);
    } finally {
      if (identical(_overlapStartingPlayer, player)) {
        _overlapStartingPlayer = null;
        unawaited(_disposeOverlapPlayer(player));
      }
    }
  }

  Future<void> _disposeOverlapPlayer(Player player) async {
    try {
      await player.setVolume(0);
      await player.stop();
      await player.abandonAudioFocus();
      await player.dispose();
    } catch (error) {
      appLogger.d('Music overlap decoder teardown failed', error: error);
      if (!player.disposed) unawaited(player.dispose());
    }
  }

  void _cancelOverlap() {
    _overlapRevision++;
    final starting = _overlapStartingPlayer;
    _overlapStartingPlayer = null;
    final active = _overlap;
    _overlap = null;
    if (starting != null) unawaited(_disposeOverlapPlayer(starting));
    if (active != null) {
      unawaited(_disposeOverlapPlayer(active.player));
      _setMusicGain(1, force: true);
      _requestArmNext();
    }
  }

  void _promoteOverlap(_MusicOverlap overlap) {
    final outgoing = _player;
    if (!identical(_overlap, overlap) || outgoing == null) return;
    _overlap = null;
    _overlapRevision++;
    if (_disposed ||
        _generation != overlap.generation ||
        _queueEditRevision != overlap.editRevision ||
        !automotiveMusicPlaybackAllowedNow() ||
        !overlap.player.state.isActive) {
      unawaited(_disposeOverlapPlayer(overlap.player));
      _setMusicGain(1, force: true);
      _requestArmNext();
      return;
    }
    final nextIndex = _queue.nextIndex();
    if (nextIndex == null || _queue.trackAt(nextIndex)?.globalKey != overlap.incoming.track.globalKey) {
      unawaited(_disposeOverlapPlayer(overlap.player));
      _setMusicGain(1, force: true);
      _requestArmNext();
      return;
    }
    _generation++;
    _invalidateArmRequests();
    _launchObserver?.detach();
    final finishedMs = _currentTrack?.durationMs;
    _finalizeCurrentTrack(
      positionOverride: finishedMs == null ? outgoing.currentPosition : Duration(milliseconds: finishedMs),
    );
    _queue.jumpTo(nextIndex);
    _player = overlap.player;
    _primaryUsesOverlapCore = overlap.usesOverlapCore;
    _outputEqSignature = null;
    _outputEqualizer = null;
    _wirePlayerStreams(overlap.player);
    _currentTrack = _queue.current;
    _currentSource = overlap.incoming.source;
    _armed = null;
    _staleArm = null;
    _musicGain = 0;
    _setMusicGain(1, force: true);
    _persistSessionProgress(positionOverride: overlap.player.currentPosition);
    _setStatus(MusicPlaybackStatus.playing, forceNotify: true);
    _bindTrackServices(_currentTrack!, overlap.incoming.source);
    _requestArmNext();
    unawaited(() async {
      try {
        await overlap.player.setWorkspaceAudioFocusEnabled(_workspaceAudioEnabled);
        if (_player == overlap.player && !_disposed && _workspaceAudioEnabled) {
          await overlap.player.requestAudioFocus();
        }
      } catch (error) {
        appLogger.w('Music overlap focus handoff failed', error: error);
      } finally {
        await _disposeOverlapPlayer(outgoing);
      }
    }());
  }

  void _onSweetFadesPreferenceChanged() {
    if (_disposed) {
      return;
    }
    if (!_sweetFadesEnabled) {
      _cancelOverlap();
      _fadeCurrentTrackIn = false;
      _setMusicGain(1, force: true);
    } else {
      final currentPlayer = _player;
      if (currentPlayer != null && !Platform.isIOS) {
        unawaited(
          currentPlayer.setProperty('audio-exclusive', 'no').catchError((Object error) {
            appLogger.d('Music output cannot enable decoded overlap', error: error);
          }),
        );
      }
      final source = _currentSource;
      final track = _currentTrack;
      if (source != null && track != null) {
        unawaited(
          _loadLoudnessProfile(source, track).then((profile) {
            if (_disposed || !identical(_currentSource, source)) {
              return;
            }
            _currentLoudnessProfile = profile;
            _updateSweetFade(_player?.currentPosition ?? Duration.zero);
          }),
        );
      }
      final armed = _armed;
      if (armed != null) {
        unawaited(_loadLoudnessProfile(armed.source, armed.track));
      }
      _updateSweetFade(_player?.currentPosition ?? Duration.zero);
    }
  }

  void _updateSweetFade(Duration position) {
    final source = _currentSource;
    final profile = _currentLoudnessProfile;
    if (!_sweetFadesEnabled ||
        _preserveAlbumGapless ||
        source == null ||
        _player?.audioPassthroughActive == true ||
        profile == null) {
      _fadeCurrentTrackIn = false;
      _setMusicGain(1);
      return;
    }

    final trackDuration = duration ?? Duration.zero;
    const fadeDuration = Duration(milliseconds: 1800);
    if (trackDuration < const Duration(seconds: 6)) {
      _fadeCurrentTrackIn = false;
      _setMusicGain(1);
      return;
    }

    final overlap = _overlap;
    if (overlap != null) {
      final remaining = trackDuration - position;
      final progress = (1 - remaining.inMicroseconds / fadeDuration.inMicroseconds).clamp(0.0, 1.0).toDouble();
      _setMusicGain(cos(progress * pi / 2));
      unawaited(overlap.player.setVolume(_musicVolume(overlap.player, gain: _outputGain * sin(progress * pi / 2))));
      return;
    }
    _tryStartOverlap(position, trackDuration);
    if (_overlapStartingPlayer != null) {
      _setMusicGain(1);
      return;
    }

    final headLevel = profile.levelAt(const Duration(milliseconds: 300), trackDuration);
    final tailPosition = trackDuration - const Duration(milliseconds: 300);
    final tailLevel = profile.levelAt(tailPosition, trackDuration);
    var gain = 1.0;

    if (_fadeCurrentTrackIn) {
      if (headLevel == null || headLevel <= -48) {
        _fadeCurrentTrackIn = false;
      } else if (position < fadeDuration) {
        final progress = (position.inMicroseconds / fadeDuration.inMicroseconds).clamp(0.0, 1.0).toDouble();
        gain = sin(progress * pi / 2);
      } else {
        _fadeCurrentTrackIn = false;
      }
    }

    final hasNextTrack = !_sleepTimerEndOfTrack && _queue.nextIndex() != null;
    if (hasNextTrack && tailLevel != null && tailLevel > -48) {
      final remaining = trackDuration - position;
      if (remaining < fadeDuration) {
        final progress = (remaining.inMicroseconds / fadeDuration.inMicroseconds).clamp(0.0, 1.0).toDouble();
        gain = min(gain, sin(progress * pi / 2));
      }
    }
    _setMusicGain(gain);
  }

  void _setMusicGain(double gain, {bool force = false}) {
    final normalized = gain.clamp(0.0, 1.0).toDouble();
    if (!force && (normalized - _musicGain).abs() < 0.01) {
      return;
    }
    _musicGain = normalized;
    final player = _player;
    if (player == null || player.disposed) {
      return;
    }
    final effectiveVolume = _musicVolume(player);
    unawaited(
      player.setVolume(effectiveVolume).catchError((Object _) {
        appLogger.d('Music fade volume update failed');
      }),
    );
  }

  bool _handleRemoteTransport(RemoteCommandType type) {
    if (_disposed || currentTrack == null) {
      return false;
    }
    final Future<void> Function()? action = switch (type) {
      RemoteCommandType.play => play,
      RemoteCommandType.pause => pause,
      RemoteCommandType.playPause => togglePlayPause,
      RemoteCommandType.nextTrack => next,
      RemoteCommandType.previousTrack => previous,
      RemoteCommandType.stop => stop,
      RemoteCommandType.seekForward => () => _seekRelative(_defaultSkipInterval),
      RemoteCommandType.seekBackward => () => _seekRelative(-_defaultSkipInterval),
      _ => null,
    };
    if (action == null) {
      return false;
    }
    unawaited(action());
    return true;
  }

  void _syncControlsAvailability() {
    unawaited(
      _mediaControls?.setControlsEnabled(
        canPlayPause: true,
        canGoNext: _musicDeviceOutput == null
            ? _queue.nextIndex(manual: true) != null
            : currentIndex + 1 < queue.length || repeatMode == MusicRepeatMode.all,
        // Previous always restarts the track even at queue head.
        canGoPrevious: true,
        canSeek: true,
        canStop: true,
        // In-track skips: Bluetooth/steering-wheel fast-forward and rewind
        // buttons map here on Android. (Not surfaced on iOS/macOS — music
        // keeps next/previous as its lock-screen transport; see
        // MediaControlsManager.setControlsEnabled's preferSkipOverTrackButtons,
        // which music deliberately leaves unset.)
        canSkip: true,
        // Music always plays at 1.0 — never advertise a speed control.
      ),
    );
  }

  /// OS transport commands. Music has no authorization gate for playback: the
  /// session only exists while a track is loaded, and that is checked in
  /// [_onControlEvent]. The automotive gate deliberately does NOT sit on
  /// [MediaControlRouter.canControlPlayback] — the router consumes a denied
  /// event, so gating it there would swallow `PauseEvent` and leave the OS
  /// unable to stop audio. Starting audio is gated inside [play] instead.
  late final _mediaControlRouter = MediaControlRouter(
    canControlPlayback: () => true,
    canNavigateMediaItems: automotiveMusicPlaybackAllowedNow,
    onPlay: () => unawaited(play()),
    onPause: () => unawaited(pause()),
    onTogglePlayPause: () => unawaited(togglePlayPause()),
    onSeek: (position) => unawaited(seek(position)),
    onNext: () => unawaited(next()),
    onPrevious: () => unawaited(previous()),
    onStop: () => unawaited(stop()),
    onSkipForward: (interval) => unawaited(_seekRelative(interval ?? _defaultSkipInterval)),
    onSkipBackward: (interval) => unawaited(_seekRelative(-(interval ?? _defaultSkipInterval))),
    // Speed is deliberately ignored: music always plays at 1.0 and the control
    // is not advertised — but Linux MPRIS exposes an always-writable Rate
    // property, so the event can still arrive. The periodic playback-state
    // update reasserts speed 1.0.
    onSetSpeed: (_) {},
  );

  void _onControlEvent(MediaControlEvent event) {
    if (_disposed || currentTrack == null) {
      return;
    }
    if (_mediaControlRouter.route(event)) {
      return;
    }

    if (_musicDeviceOutput != null) return;

    if (event is AudioInterruptionBeganEvent || event is AudioRouteOldDeviceUnavailableEvent) {
      // Remember whether we were playing so interruption-end/route-return
      // can resume. Unlike video, music resumes even while backgrounded —
      // background audio is the product.
      _resumeAfterInterruption = _player?.state.isActive ?? false;
      unawaited(pause());
    } else if (event is AudioInterruptionEndedEvent) {
      if (event.shouldResume && _resumeAfterInterruption) {
        _resumeAfterInterruption = false;
        unawaited(play());
      } else {
        _resumeAfterInterruption = false;
      }
    } else if (event is AudioRouteNewDeviceAvailableEvent) {
      if (_resumeAfterInterruption) {
        _resumeAfterInterruption = false;
        unawaited(play());
      }
    }
  }

  static const _defaultSkipInterval = Duration(seconds: 15);

  /// In-track relative seek for OS skip commands, clamped to the track.
  Future<void> _seekRelative(Duration delta) async {
    if (_musicDeviceOutput != null) {
      var target = position + delta;
      if (target < Duration.zero) target = Duration.zero;
      final max = duration;
      if (max != null && target > max) target = max;
      return seek(target);
    }
    _cancelOverlap();
    final player = _player;
    if (player == null) {
      return;
    }
    var target = player.currentPosition + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    final max = duration;
    if (max != null && target > max) {
      target = max;
    }
    await player.seek(target);
  }

  // ---------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------

  @override
  Future<void> play() async {
    if (_musicDeviceOutput != null) return _controlMusicDevice('play');
    final native = _calderaSink;
    if (native?.active == true) {
      if (automotiveMusicPlaybackAllowedNow()) await native!.control('play');
      return;
    }
    _cancelOverlap();
    _continuationResumeRevision++;
    if (!automotiveMusicPlaybackAllowedNow()) {
      appLogger.d('Music play denied while automotive playback is restricted');
      return;
    }
    if (_currentTrack == null) {
      return;
    }
    final player = _player;
    final retryPausedOutput = _status == MusicPlaybackStatus.error && _currentSource == null;
    if (player == null || retryPausedOutput) {
      final generation = ++_generation;
      _invalidateArmRequests();
      await _openCurrent(generation, play: true, newOccurrence: !retryPausedOutput);
      return;
    }
    final generation = _generation;
    if (player.state.completed) {
      // Parked at queue end: restart the current track.
      await player.seek(Duration.zero);
      if (!_isCurrentTransport(player, generation)) {
        return;
      }
      final currentTrack = _currentTrack;
      final currentSource = _currentSource;
      if (currentTrack != null && currentSource != null) {
        _bindTrackServices(currentTrack, currentSource);
      }
      _requestArmNext();
    }
    if (!automotiveMusicPlaybackAllowedNow()) {
      appLogger.d('Music play denied while automotive playback is restricted');
      return;
    }
    await player.play();
    if (!_isCurrentTransport(player, generation)) {
      return;
    }
    if (!automotiveMusicPlaybackAllowedNow()) {
      await player.pause();
      if (_isCurrentTransport(player, generation)) {
        _setStatus(MusicPlaybackStatus.paused);
      }
      return;
    }
    _setStatus(MusicPlaybackStatus.playing);
    if (_resumeGroupTracking && !_musicGroupFollower && _currentTrack != null && _currentSource != null) {
      _bindTrackServices(_currentTrack!, _currentSource!);
    }
    // A restriction cleared the native arm on the way in; restore it so gapless
    // playback survives a park-and-resume cycle.
    if (PlatformDetector.isAutomotive()) {
      _requestArmNext();
    }
  }

  @override
  Future<void> pause() async {
    if (_musicDeviceOutput != null) return _controlMusicDevice('pause');
    _pausedByCarRestriction = false;
    final native = _calderaSink;
    if (native?.active == true) return native!.control('pause');
    await _pause(byCar: false);
  }

  /// [byCar] marks the pause the vehicle's restrictions own, which is the only
  /// one resumed when they lift. Any other pause — the user, a media-session
  /// command, the sleep timer — takes that ownership away, so parking must not
  /// restart a track somebody deliberately stopped while driving.
  Future<void> _pause({required bool byCar}) async {
    _cancelOverlap();
    _continuationResumeRevision++;
    if (!byCar) {
      _pausedByCarRestriction = false;
    }
    final player = _player;
    if (player == null || _currentTrack == null) {
      return;
    }
    final generation = _generation;
    await player.pause();
    if (!_isCurrentTransport(player, generation)) {
      return;
    }
    _setStatus(MusicPlaybackStatus.paused);
  }

  bool _isCurrentTransport(Player player, int generation) {
    return !_disposed && _currentTrack != null && generation == _generation && _player == player;
  }

  @override
  Future<void> togglePlayPause() {
    if (_musicDeviceOutput != null) return _controlMusicDevice('toggle');
    if (_calderaSink?.active == true) return isPlaying ? pause() : play();
    final player = _player;
    if (player == null) {
      return _currentTrack != null ? play() : Future.value();
    }
    return player.state.isActive ? pause() : play();
  }

  /// On Apple TV, pause when the app leaves the foreground because tvOS
  /// background audio is not attempted in v1. On a car this is only the
  /// fallback authority: [_applyCarPlaybackRestrictions] keeps playing when the
  /// vehicle reports no restrictions, so leaving the app while parked keeps the
  /// music going.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) {
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // The process may be about to die; the throttled tick alone could be
      // up to its full interval stale.
      _persistSessionProgress();
    }
    if (PlatformDetector.isAutomotive()) {
      _applyCarPlaybackRestrictions();
      return;
    }
    if (PlatformDetector.isAppleTV() &&
        (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) &&
        isPlaying) {
      appLogger.d('App backgrounded on Apple TV — pausing music playback');
      unawaited(pause());
    }
  }

  void _onCarRestrictionsChanged() {
    if (_disposed) {
      return;
    }
    // A late first answer must reconfigure the session that was opened while the
    // vehicle was still silent, otherwise background audio stays off until the
    // next track opens.
    _reassertCarBackgroundMode();
    _applyCarPlaybackRestrictions();
  }

  /// Applies the foreground-service opt-in (and the notification it needs) for
  /// the live session whenever the vehicle's answer changes what we may do.
  void _reassertCarBackgroundMode() {
    if (!PlatformDetector.isAutomotive() || _mediaControls == null) {
      return;
    }
    final enabled = _carBackgroundAudioAvailable;
    if (enabled == _carBackgroundModeApplied) {
      return;
    }
    _carBackgroundModeApplied = enabled;
    unawaited(_mediaControls?.setBackgroundMode(enabled));
    if (enabled) {
      unawaited(NotificationPermission.ensure());
    }
  }

  /// Stop audio while the vehicle requires distraction optimization (`DD-2`),
  /// and pick the track back up once it does not.
  ///
  /// Resuming is deliberately limited to vehicles that report their own
  /// restrictions, where lifting them means "the car is parked again". Under
  /// the lifecycle fallback the same transition only means the app regained
  /// focus — it could still be driving, and a dialog dismissal is not a request
  /// to play — so those cars keep the previous, conservative behaviour.
  void _applyCarPlaybackRestrictions() {
    final vehicleReports = _carBackgroundAudioAvailable;
    if (!automotiveMusicPlaybackAllowedNow()) {
      _invalidateArmRequests();
      _rememberStaleArm();
      final player = _player;
      if (player != null) {
        unawaited(_trySetNext(player, null));
      }
      // `isPlaying` reports the session status, which reads `loading` while a
      // replacement source resolves — and the previous track is still coming out of
      // the native player for the whole of that window, however long the resolver
      // takes. Ask the player as well, or driving would not silence it.
      final soundingNow = isPlaying || (player?.state.playing ?? false);
      // One pause per transition: a car delivers the restriction push and its
      // lifecycle states separately, and a second pause launched while the first
      // is pending would clear the in-flight flag out from under it.
      if (soundingNow && !_carPauseInFlight) {
        appLogger.d('Vehicle restricted playback — pausing music');
        // The gate owns this pause even when the verdict came from lifecycle: a
        // transient car-service restart lands here, and losing ownership would
        // leave the track silent for good once the vehicle answers again.
        _pausedByCarRestriction = true;
        unawaited(_pauseForRestriction());
      }
      return;
    }
    // Restrictions lifted: re-arm the next track that was cleared on entry.
    if (_currentTrack != null) {
      _requestArmNext();
    }
    // Only playback this gate stopped is resumed; a track the user paused
    // before driving stays paused, and nothing auto-starts on a fresh session.
    if (_pausedByCarRestriction) {
      // A restriction-owned pause still in flight keeps the latch: `isPlaying`
      // reads stale until that pause lands, so clearing here would skip the
      // resume and leave a parked car silent. The re-evaluation does it instead.
      if (_carPauseInFlight) {
        return;
      }
      // Only a definitive verdict consumes it. While the vehicle cannot answer,
      // the app regaining focus is not a reason to forget that this gate stopped
      // the track — the answer can still arrive and resume it.
      if (!vehicleReports) {
        return;
      }
      // A resume already in flight owns the outcome; it re-evaluates when it lands.
      if (_carResumeInFlight) {
        return;
      }
      if (_currentTrack != null && !isPlaying) {
        appLogger.d('Vehicle restrictions lifted — resuming music');
        unawaited(_resumeAfterRestriction());
        return;
      }
      // Nothing left to resume, so the gate's claim on this track is discharged.
      _pausedByCarRestriction = false;
    }
  }

  /// Resumes what the vehicle stopped, keeping the latch until it actually plays.
  ///
  /// The car can restrict again while this is in flight, and that transition reads
  /// the track as already paused, so it neither pauses nor reclaims the latch —
  /// [play] then refuses on the closed gate. Discharging the latch up front would
  /// strand the track paused on a parked car for good.
  Future<void> _resumeAfterRestriction() async {
    _carResumeInFlight = true;
    var failed = false;
    try {
      await play();
    } catch (e, stackTrace) {
      failed = true;
      appLogger.w('Failed to resume after vehicle restrictions lifted', error: e, stackTrace: stackTrace);
    } finally {
      _carResumeInFlight = false;
    }
    if (_disposed) {
      return;
    }
    if (isPlaying) {
      _pausedByCarRestriction = false;
      return;
    }
    if (failed) {
      // The platform refused outright. Re-evaluating would call straight back into
      // here and spin as fast as play() can fail, so drop the claim and leave the
      // track for the user; the vehicle is not what is broken here.
      _pausedByCarRestriction = false;
      return;
    }
    if (!automotiveMusicPlaybackAllowedNow()) {
      // The vehicle restricted again mid-resume: keep the claim and let the current
      // verdict decide what happens next.
      _applyCarPlaybackRestrictions();
      return;
    }
    // The play call landed but the platform has not reported the transition yet — it
    // arrives as a state event. Keep the claim, which the next evaluation discharges
    // once `isPlaying` is true; re-running now would just issue another play.
  }

  /// Pauses for the vehicle, then re-reads the verdict.
  ///
  /// The car can release playback while the pause is still in flight — a
  /// stop-and-go — and that transition arrives while [isPlaying] is still true,
  /// so it cannot resume anything by itself.
  Future<void> _pauseForRestriction() async {
    _carPauseInFlight = true;
    try {
      await _pause(byCar: true);
    } catch (e, stackTrace) {
      appLogger.w('Failed to pause for vehicle restrictions', error: e, stackTrace: stackTrace);
      // Fail closed: `DD-2` is not satisfied by having tried. Nothing else is
      // coming to stop this — the restriction already fired — so end the session
      // rather than leave audio running in a moving car. The native state decides,
      // for the same reason the caller checks it: the session reads `loading` while
      // a replacement source resolves, with the previous track still audible.
      final stillSounding = isPlaying || (_player?.state.playing ?? false);
      if (!_disposed && !automotiveMusicPlaybackAllowedNow() && stillSounding) {
        try {
          await stop();
        } catch (e, stackTrace) {
          appLogger.w('Failed to stop restricted playback', error: e, stackTrace: stackTrace);
        }
      }
    } finally {
      _carPauseInFlight = false;
    }
    if (_disposed || !automotiveMusicPlaybackAllowedNow()) {
      return;
    }
    _applyCarPlaybackRestrictions();
  }

  @override
  Future<void> next() async {
    if (_musicDeviceOutput != null) return _controlMusicDevice('next');
    final native = _calderaSink;
    if (native?.active == true) return native!.control('skipNext');
    _continuationResumeRevision++;
    final nextCursor = _queue.nextIndex(manual: true);
    if (nextCursor == null) {
      return;
    }
    await _advanceTo(nextCursor);
  }

  @override
  Future<void> previous() async {
    if (_musicDeviceOutput != null) return _controlMusicDevice('previous');
    final native = _calderaSink;
    if (native?.active == true) return native!.control('skipPrevious');
    _continuationResumeRevision++;
    _cancelOverlap();
    final player = _player;
    if (player == null) {
      // Parked restored session: previous restarts from the top (or steps
      // back) — the persisted resume offset belongs to play() alone.
      if (_currentTrack == null) {
        return;
      }
      await _advanceTo(_queue.previousIndex() ?? _queue.cursor);
      return;
    }
    if (player.currentPosition > _previousRestartThreshold) {
      await player.seek(Duration.zero);
      return;
    }
    final prevCursor = _queue.previousIndex();
    if (prevCursor == null) {
      await player.seek(Duration.zero);
      return;
    }
    await _advanceTo(prevCursor);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_musicDeviceOutput != null) return _controlMusicDevice('seek', {'position': position.inMilliseconds});
    final native = _calderaSink;
    if (native?.active == true) return native!.control('seek', position: position);
    _cancelOverlap();
    _continuationResumeRevision++;
    final pending = _pendingRestoreResume;
    if (_player == null && pending != null) {
      // Parked restored session: move the deferred resume point instead.
      var target = position < Duration.zero ? Duration.zero : position;
      final max = duration;
      if (max != null && target > max) {
        target = max;
      }
      pending.position = target;
      _positionController.add(target);
      _persistSessionProgress();
      return;
    }
    await _player?.seek(position);
  }

  @override
  double get volume => _musicDeviceOutput?.state?.volume ?? _volume;
  @override
  ValueListenable<double> get volumeListenable => _volumeNotifier;

  @override
  Future<void> setVolume(double volume, {bool persist = true}) async {
    if (_musicDeviceOutput != null) {
      if (!volume.isFinite) return;
      _volumeNotifier.value = volume.clamp(0.0, 100.0);
      if (persist) await _controlMusicDevice('volume', {'volume': volume.clamp(0.0, 100.0)});
      return;
    }
    final clamped = volume.clamp(0.0, 100.0);
    Future<void>? playerUpdate;
    if (clamped != _volume) {
      _volume = clamped;
      _volumeNotifier.value = clamped;
      final player = _player;
      playerUpdate = player?.setVolume(_musicVolume(player, volume: clamped));
      final overlap = _overlap;
      if (overlap != null) {
        final currentDuration = duration ?? Duration.zero;
        final remaining = currentDuration - (_player?.currentPosition ?? Duration.zero);
        const fadeDuration = Duration(milliseconds: 1800);
        final progress = (1 - remaining.inMicroseconds / fadeDuration.inMicroseconds).clamp(0.0, 1.0).toDouble();
        unawaited(
          overlap.player.setVolume(
            _musicVolume(overlap.player, volume: clamped, gain: _outputGain * sin(progress * pi / 2)),
          ),
        );
      }
    }

    final persistence = persist ? _persistVolume(clamped) : null;
    if (playerUpdate != null && persistence != null) {
      await Future.wait([playerUpdate, persistence]);
    } else {
      await playerUpdate;
      await persistence;
    }
  }

  @override
  Future<void> setWorkspaceAudioEnabled(bool enabled) async {
    if (_workspaceAudioEnabled == enabled) {
      return;
    }
    _workspaceAudioEnabled = enabled;
    if (!enabled) _cancelOverlap();
    final player = _player;
    if (player == null || player.disposed) {
      return;
    }
    if (enabled) {
      try {
        await player.setWorkspaceAudioFocusEnabled(true);
        if (player.state.isActive) {
          await player.requestAudioFocus();
        }
      } catch (error, stackTrace) {
        appLogger.w('Music workspace audio focus handoff failed', error: error, stackTrace: stackTrace);
      }
      await player.setVolume(_musicVolume(player));
      return;
    }

    try {
      await player.setVolume(0);
    } finally {
      try {
        await player.setWorkspaceAudioFocusEnabled(false);
      } catch (error, stackTrace) {
        appLogger.w('Music workspace audio focus release failed', error: error, stackTrace: stackTrace);
      }
    }
  }

  static Future<void> _writePersistedVolume(double volume) async {
    final settings = SettingsService.instanceOrNull;
    if (settings != null) {
      await settings.write(SettingsService.musicVolume, volume);
    }
  }

  Future<void> _persistVolume(double volume) {
    _pendingVolumeWrite = volume;
    final activeDrain = _volumeWriteDrain;
    if (activeDrain != null) {
      return activeDrain;
    }

    final completer = Completer<void>();
    _volumeWriteDrain = completer.future;
    unawaited(_drainVolumeWrites(completer));
    return completer.future;
  }

  Future<void> _drainVolumeWrites(Completer<void> completer) async {
    Object? firstError;
    StackTrace? firstStackTrace;

    while (_pendingVolumeWrite != null) {
      final volume = _pendingVolumeWrite!;
      _pendingVolumeWrite = null;
      try {
        await _volumePersistenceWriter(volume);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    _volumeWriteDrain = null;
    if (firstError != null) {
      completer.completeError(firstError, firstStackTrace);
    } else {
      completer.complete();
    }
  }

  @override
  Future<void> jumpTo(int index) async {
    if (_musicDeviceOutput != null) return _controlMusicDevice('jump', {'index': index});
    if (index < 0 || index >= _queue.length || index == _queue.cursor) {
      return;
    }
    _continuationResumeRevision++;
    await _advanceTo(index);
  }

  // ---------------------------------------------------------------------
  // Queue / mode edits
  // ---------------------------------------------------------------------

  @override
  void setRepeatMode(MusicRepeatMode mode) {
    if (_musicDeviceOutput != null) {
      unawaited(_controlMusicDevice('repeat', {'mode': mode.name}));
      return;
    }
    if (_queue.repeatMode == mode) {
      return;
    }
    _queue.repeatMode = mode;
    _afterQueueEdit();
  }

  @override
  void toggleShuffle() {
    if (_musicDeviceOutput != null) {
      unawaited(_controlMusicDevice('shuffle', const {}));
      return;
    }
    if (_queue.isEmpty) {
      return;
    }
    _queue.toggleShuffle();
    _afterQueueEdit();
  }

  @override
  void removeAt(int index) {
    if (_musicDeviceOutput != null) {
      unawaited(_controlMusicDevice('remove', {'index': index}));
      return;
    }
    final excluded = _queue.trackAt(index);
    if (excluded != null) _continuationExcluded.add(excluded.globalKey);
    if (index < 0 || index >= _queue.length) {
      return;
    }
    final wasCurrent = _queue.removeAt(index);
    if (wasCurrent) {
      if (_queue.isEmpty) {
        unawaited(stop());
        return;
      }
      _persistSessionSnapshot(positionOverride: Duration.zero);
      // The cursor already points at what used to be next — open it.
      unawaited(_advanceTo(_queue.cursor));
      return;
    }
    _afterQueueEdit();
  }

  @override
  void reorder(int from, int to) {
    if (_musicDeviceOutput != null) {
      unawaited(_controlMusicDevice('reorder', {'index': from, 'to': to}));
      return;
    }
    if (from == to) {
      return;
    }
    _queue.move(from, to);
    _afterQueueEdit();
  }

  @override
  void addNext(List<MediaItem> tracks) => _enqueue(tracks, next: true);

  @override
  void addToEnd(List<MediaItem> tracks) => _enqueue(tracks, next: false);

  /// Queue edits while idle start a session parked on the first added track
  /// (mini-player appears paused) instead of silently dropping the action
  /// or surprising the user with audio.
  void _enqueue(List<MediaItem> tracks, {required bool next}) {
    if (_musicDeviceOutput != null) {
      if (tracks.isEmpty) return;
      final queue = MusicQueueController()..load(tracks);
      final snapshot = MusicTransferSnapshot(queue: queue.captureState(), position: Duration.zero, playing: false);
      try {
        unawaited(
          _controlMusicDevice(next ? 'addNext' : 'addToEnd', {
            'tracks': snapshot.toJson(itemLimit: MusicTransferSnapshot.maxTransferItems),
          }),
        );
      } on StateError catch (error) {
        if (!_disposed) _errorsController.add(error);
      }
      return;
    }
    if (tracks.isEmpty) {
      return;
    }
    if (_queue.isEmpty || _currentTrack == null) {
      final first = tracks.first;
      unawaited(
        _startQueue(
          tracks: tracks,
          playContext: MusicPlayContext(
            title: first.albumTitle ?? first.title ?? '',
            kind: MusicPlayContextKind.tracks,
          ),
          autoplay: false,
        ),
      );
      return;
    }
    if (next) {
      _queue.addNext(tracks);
    } else {
      _queue.addToEnd(tracks);
    }
    _afterQueueEdit();
  }

  @override
  void clearUpcoming() {
    if (_musicDeviceOutput != null) {
      unawaited(_controlMusicDevice('clear', const {}));
      return;
    }
    setContinuationEnabled(false);
    if (_queue.isEmpty) {
      return;
    }
    _queue.clearUpcoming();
    _afterQueueEdit();
  }

  void _afterQueueEdit() {
    _cancelOverlap();
    _queueEditRevision++;
    if (_sweetFadesEnabled && _preserveAlbumGapless) {
      _fadeCurrentTrackIn = false;
      _setMusicGain(1);
    }
    _rearmIfNeeded();
    _syncControlsAvailability();
    _persistSessionSnapshot();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Sleep timer
  // ---------------------------------------------------------------------

  @override
  void setSleepTimer(Duration? duration, {bool endOfTrack = false}) {
    if (endOfTrack) _cancelOverlap();
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerDuration = null;
    final hadEndOfTrack = _sleepTimerEndOfTrack;
    _sleepTimerEndOfTrack = endOfTrack;
    if (!endOfTrack && duration != null) {
      _sleepTimerDuration = duration;
      _sleepTimer = Timer(duration, _onSleepTimerFired);
    }
    // End-of-track mode suppresses gapless arming (and leaving it restores
    // the arm), so the track genuinely completes instead of transitioning.
    if (hadEndOfTrack != _sleepTimerEndOfTrack) {
      _requestArmNext();
    }
    notifyListeners();
  }

  void _onSleepTimerFired() {
    _sleepTimer = null;
    _sleepTimerDuration = null;
    unawaited(pause());
    notifyListeners();
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerDuration = null;
    _sleepTimerEndOfTrack = false;
  }

  // ---------------------------------------------------------------------
  // Stop / teardown
  // ---------------------------------------------------------------------

  @override
  Future<void> stop() async {
    final output = _musicDeviceOutput;
    if (output != null) {
      await _controlMusicDevice('stop');
      if (!identical(output, _musicDeviceOutput)) return;
      setMusicDeviceOutput(null);
    }
    await _stopSession(endStatus: MusicPlaybackStatus.idle);
    _workspaceAudioEnabled = true;
  }

  /// The coordinator's video claim uses the exact same full-stop path, so
  /// the audio core is guaranteed disposed when it resolves.
  Future<void> _stopForVideoClaim() => _stopSession(endStatus: MusicPlaybackStatus.idle);

  Future<void> _stopSession({required MusicPlaybackStatus endStatus}) async {
    final nativeSource = _calderaSource;
    _calderaSource = null;
    unawaited(nativeSource?.close());
    final nativeSink = _calderaAudioOwner == null ? null : _calderaSink;
    if (nativeSink != null) {
      _calderaSink = null;
      unawaited(nativeSink.close());
    }
    _syncNativeHost();
    _calderaAudioOwner = null;
    _calderaAudioGeneration = null;
    _nativeNowPlaying = null;
    _nativeMetadataClock
      ..stop()
      ..reset();
    _musicGroupFollower = false;
    _cancelOverlap();
    _continuationEpoch++;
    _continuationSeed = null;
    _continuationAccount = null;
    _continuationLoading = false;
    _continuationTask = null;
    beginPlayIntent();
    _queueSessionRevision++;
    _generation++;
    if (endStatus == MusicPlaybackStatus.error) {
      // Keep the terminal receipt after native teardown. An explicit stop or
      // replacement queue can still retire it without reading a dead player.
      _launchObserver?.detach();
    } else {
      _launchObserver?.mark('stopped');
      _launchObserver?.detach(stage: 'stopped');
      _launchObserver = null;
    }
    _observedGeneration = null;
    _invalidateArmRequests();
    _cancelTimersAndFinalizeTrack();
    _queue.clear();
    _currentTrack = null;
    _currentSource = null;
    _currentLoudnessProfile = null;
    _fadeCurrentTrackIn = false;
    _musicGain = 1;
    _armed = null;
    _staleArm = null;
    _playContext = null;
    _pendingRestoreResume = null;
    // A user-visible session end (stop, swipe-dismiss, video claim, error
    // stop): nothing should come back on the next launch.
    _clearPersistedSession();
    _resumeAfterInterruption = false;
    // The vehicle's claim dies with the session: whatever plays next is a fresh
    // decision, and parking must not resume a queue the user never started.
    _pausedByCarRestriction = false;
    _setStatus(endStatus, forceNotify: true);

    await _teardownPlayerAndControls(awaitStop: true);
  }

  /// Kills the completion/sleep timers and flushes the track's final progress
  /// report — done before [_setStatus] so listeners never see a live timer.
  void _cancelTimersAndFinalizeTrack() {
    _completedConfirmTimer?.cancel();
    _completedConfirmTimer = null;
    _cancelSleepTimer();
    _finalizeCurrentTrack();
  }

  /// Detaches the player streams, shuts the player down and drops the OS media
  /// session — the teardown shared by [_stopSession] and [dispose].
  ///
  /// [awaitStop] stops the player and awaits every step, so callers know the
  /// audio core is gone once the future resolves. The `false` path must never
  /// suspend: [dispose] is a synchronous override and needs the whole teardown
  /// to run in the caller's turn, before `super.dispose()`.
  Future<void> _teardownPlayerAndControls({required bool awaitStop}) async {
    _cancelOverlap();
    _outputRequest++;
    unawaited(_outputRevoked?.cancel());
    _outputRevoked = null;
    _playbackOutput = null;
    // Before any await: the session is already inert (guards check
    // [_currentTrack]/[_disposed]), and the handler must not outlive the turn
    // that tears the session down.
    _hardwareTransport?.unregister();
    _hardwareTransport = null;
    final receiver = CompanionRemoteReceiver.instance;
    if (identical(receiver.musicTransport, _remoteTransport)) {
      receiver.musicTransport = null;
    }
    for (final sub in _playerSubs) {
      unawaited(sub.cancel());
    }
    _playerSubs.clear();
    // The subscriptions above are gone before the player stops, so no
    // playing=false will reach [_onPlayingChanged]: clear presence here, and
    // before any await so a video claim's own presence lands after it.
    unawaited(DiscordRPCService.instance.stopPlayback());
    final player = _player;
    _player = null;
    if (player != null && !player.disposed) {
      if (awaitStop) {
        try {
          await player.stop();
        } catch (e) {
          appLogger.d('Audio player stop failed during session teardown', error: e);
        }
        try {
          await player.abandonAudioFocus();
        } catch (e) {
          appLogger.d('Audio focus abandon failed during session teardown', error: e);
        }
        try {
          await player.dispose();
        } catch (e) {
          appLogger.w('Audio player dispose failed during session teardown', error: e);
          _player = player;
          rethrow;
        }
      } else {
        unawaited(
          player.abandonAudioFocus().catchError((Object e) {
            appLogger.d('Audio focus abandon failed during dispose', error: e);
          }),
        );
        unawaited(player.dispose());
      }
    }

    unawaited(_controlEventsSub?.cancel());
    _controlEventsSub = null;
    final controls = _mediaControls;
    _mediaControls = null;
    if (controls != null) {
      unawaited(controls.setBackgroundMode(false));
      unawaited(controls.clear());
      controls.dispose();
    }
  }

  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) async {
    final client = _clientFor(track);
    if (client != null && !client.isOfflineMode) {
      try {
        final authentication = client.authenticationSessionId;
        final lyrics = await client.fetchLyrics(track);
        if (_disposed ||
            !identical(_clientFor(track), client) ||
            !identical(authentication, client.authenticationSessionId)) {
          return null;
        }
        try {
          if (lyrics == null) {
            await _libraryStore?.deleteDocument('lyrics', track.globalKey);
          } else {
            await _libraryStore?.saveDocument('lyrics', track.globalKey, {
              'version': 1,
              'updatedAt': track.updatedAt,
              'lyrics': lyrics.toJson(),
            });
          }
        } catch (error) {
          appLogger.w('Lyrics could not be cached', error: error);
        }
        return lyrics;
      } catch (_) {
        final cached = await _libraryStore?.document('lyrics', track.globalKey);
        if (cached == null) rethrow;
      }
    }
    final cached = await _libraryStore?.document('lyrics', track.globalKey);
    if (_disposed ||
        cached == null ||
        cached['version'] != 1 ||
        track.updatedAt != null && cached['updatedAt'] != track.updatedAt) {
      return null;
    }
    try {
      return Lyrics.fromJson(Map<String, dynamic>.from(cached['lyrics'] as Map));
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  MediaServerClient? _clientFor(MediaItem item) {
    final serverId = serverIdOrNull(item.serverId);
    if (serverId == null || !_serverManager.isServerVisible(serverId)) {
      return null;
    }
    return _serverManager.getClient(serverId);
  }

  // ---------------------------------------------------------------------
  // Session persistence & restore (#2148)
  // ---------------------------------------------------------------------

  /// Rehydrate the last persisted session as a parked-paused queue: no
  /// player, no source resolution, no OS media session — the first play()
  /// performs the real open (resolution happens then, so this also works
  /// offline for downloaded tracks and while servers are still connecting).
  Future<void> _maybeRestoreSession() async {
    final store = _sessionStore;
    if (store == null) {
      return;
    }
    final settings = SettingsService.instanceOrNull;
    if (settings != null && !settings.read(SettingsService.resumeMusicOnLaunch)) {
      return;
    }
    final intent = _playIntentGeneration;
    final revision = _queueSessionRevision;
    MusicSessionSnapshot? snapshot;
    try {
      snapshot = await store.load();
    } catch (e, st) {
      appLogger.w('Music session restore read failed', error: e, stackTrace: st);
      return;
    }
    if (snapshot == null) {
      return;
    }
    // A play intent or session that raced the read wins; never clobber it.
    if (_disposed || intent != _playIntentGeneration || revision != _queueSessionRevision) {
      return;
    }
    if (_status != MusicPlaybackStatus.idle || _currentTrack != null) {
      return;
    }
    if (!_queue.restoreState(snapshot.queue)) {
      appLogger.w('Discarding persisted music session with invalid queue state');
      return;
    }
    final track = _queue.current;
    if (track == null) {
      _queue.clear();
      return;
    }
    var resumeAt = snapshot.position;
    final durationMs = track.durationMs;
    if (resumeAt < Duration.zero || (durationMs != null && resumeAt.inMilliseconds >= durationMs)) {
      resumeAt = Duration.zero;
    }
    _queueSessionRevision++;
    _playContext = snapshot.playContext;
    _continuationAccount = snapshot.continuationAccount;
    _continuationSeed = _continuationAccount == null ? null : snapshot.continuationSeed;
    _continuationExcluded
      ..clear()
      ..addAll(snapshot.continuationExcluded);
    _currentTrack = track;
    _pendingRestoreResume = _PendingResume(globalKey: track.globalKey, position: resumeAt);
    appLogger.i('Music: restored parked session "${track.title}" at ${resumeAt.inSeconds}s');
    _positionController.add(resumeAt);
    _setStatus(MusicPlaybackStatus.paused, forceNotify: true);
  }

  /// One-shot: the resume offset applies only to the still-current restored
  /// track; opening anything else discards it.
  Duration? _consumePendingResume(MediaItem track) {
    final pending = _pendingRestoreResume;
    if (pending == null) {
      return null;
    }
    _pendingRestoreResume = null;
    if (pending.globalKey != track.globalKey || pending.position <= Duration.zero) {
      return null;
    }
    return pending.position;
  }

  /// Full snapshot rewrite — queue-shape/mode changes only; the playhead
  /// travels through [_persistSessionProgress] otherwise.
  void _persistSessionSnapshot({Duration? positionOverride}) {
    final store = _sessionStore;
    // Guard on the queue, not [_currentTrack]: at [_startQueue] time the
    // queue is already loaded but the track only commits inside [_openCurrent].
    if (store == null || _disposed || _calderaAudioOwner != null || _queue.current == null) {
      return;
    }
    final snapshot = MusicSessionSnapshot(
      queue: _queue.captureState(),
      playContext: _playContext,
      position: positionOverride ?? position,
      continuationSeed: _continuationSeed,
      continuationAccount: _continuationAccount,
      continuationExcluded: Set.unmodifiable(_continuationExcluded),
    );
    unawaited(
      store.save(snapshot).catchError((Object e, StackTrace st) {
        appLogger.w('Music session snapshot write failed', error: e, stackTrace: st);
      }),
    );
  }

  void _persistSessionProgress({Duration? positionOverride}) {
    final store = _sessionStore;
    if (store == null || _calderaAudioOwner != null || _currentTrack == null) {
      return;
    }
    unawaited(
      store.updateProgress(cursor: _queue.cursor, position: positionOverride ?? position).catchError((
        Object e,
        StackTrace st,
      ) {
        appLogger.w('Music session progress write failed', error: e, stackTrace: st);
      }),
    );
  }

  void _maybePersistPositionTick(Duration position) {
    if (_sessionStore == null || _currentTrack == null) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastPositionPersist) < _positionPersistInterval) {
      return;
    }
    _lastPositionPersist = now;
    _persistSessionProgress(positionOverride: position);
  }

  void _clearPersistedSession() {
    final store = _sessionStore;
    if (store == null) {
      return;
    }
    unawaited(
      store.clear().catchError((Object e, StackTrace st) {
        appLogger.w('Music session clear failed', error: e, stackTrace: st);
      }),
    );
  }

  void _setStatus(MusicPlaybackStatus status, {bool forceNotify = false}) {
    if (_disposed) {
      return;
    }
    if (_status == status && !forceNotify) {
      return;
    }
    final wasPlaying = _status == MusicPlaybackStatus.playing;
    _status = status;
    // Pause is the moment the playhead stops moving — flush it so a quit
    // while paused restores exactly here.
    if (wasPlaying && status == MusicPlaybackStatus.paused) {
      _persistSessionProgress();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    final nativeHost = _calderaHost;
    _calderaHost = null;
    unawaited(nativeHost?.close());
    unawaited(leaveNativeMusicGroup());
    _musicDeviceOutput?.removeListener(_onMusicDeviceChanged);
    _musicDeviceOutput = null;
    if (_disposed) {
      return;
    }
    // Best-effort final playhead flush: dispose runs on profile switch and
    // normal app teardown, both of which should restore precisely.
    _persistSessionProgress();
    _playIntentGeneration++;
    _queueSessionRevision++;
    _generation++;
    _invalidateArmRequests();
    _disposed = true;
    onDispose?.call(this);
    _byteCache?.dispose();
    if (_observesLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observesLifecycle = false;
    }
    if (_observesCarRestrictions) {
      CarUxRestrictionsService.instance.listenable.removeListener(_onCarRestrictionsChanged);
      _observesCarRestrictions = false;
    }
    _audioSettingsListenable?.removeListener(_onAudioSettingsChanged);
    _sweetFadesSettingsListenable?.removeListener(_onSweetFadesPreferenceChanged);
    _sweetFadesSettingsListenable = null;
    _coordinator.unregisterMusicSession(_stopForVideoClaim);
    _cancelTimersAndFinalizeTrack();
    // Runs to completion synchronously — see the awaitStop: false contract.
    unawaited(_teardownPlayerAndControls(awaitStop: false));
    unawaited(_positionController.close());
    unawaited(_playheadJumpController.close());
    unawaited(_errorsController.close());
    _loudnessProfileRequests.clear();
    _loadedLoudnessProfiles.clear();
    _volumeNotifier.dispose();
    super.dispose();
  }
}
