import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../mpv/models.dart';
import '../widgets/app_icon.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/watch_state_notifier.dart';
import '../utils/serial_future_queue.dart';
import '../utils/session_identifier.dart';
import 'cast_playback_ownership.dart';
import 'music/cast_music_output.dart';
import 'music/cast_music_queue.dart';
import 'music/cast_music_recovery.dart';
import 'music/music_library_store.dart';
import 'music/music_device_session.dart';
import 'music/music_transfer_snapshot.dart';
import 'multi_server_manager.dart';
import 'playback_report_session.dart';
import 'trackers/tracker_coordinator.dart';

/// Google Cast handoff for server-resolved streams.
///
/// Plex, Jellyfin and Emby URLs are resolved by their existing client adapters;
/// credentials stay in the self-contained stream URL, so the default Cast
/// receiver does not need custom request headers or a fork-specific receiver.
class CastMediaService extends ChangeNotifier {
  CastMediaService._();

  static final CastMediaService instance = CastMediaService._();

  static bool get isSupportedPlatform => Platform.isAndroid || (Platform.isIOS && !PlatformDetector.isAppleTV());

  final _discovery = GoogleCastDiscoveryManager.instance;
  final _sessions = GoogleCastSessionManager.instance;
  final _remote = GoogleCastRemoteMediaClient.instance;

  bool _initialized = false;
  String? _deviceName;
  MediaItem? _activeItem;
  MediaServerClient? _activeClient;
  String? _playSessionId;
  Duration _partStart = Duration.zero;
  Duration? _duration;
  PlaybackReportSession? _reportSession;
  Timer? _progressTimer;
  StreamSubscription<GoogleCastSession?>? _sessionSubscription;
  StreamSubscription<GoggleCastMediaStatus?>? _statusSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<List<GoogleCastQueueItem>>? _queueSubscription;
  bool _finishingPlayback = false;
  bool? _lastPausedState;
  final _loads = SerialFutureQueue();
  final _ownership = CastPlaybackOwnership();
  CastReceiverKey? _receiverKey;
  int _loadIntent = 0;
  int _profileRevision = 0;
  String? _profileId;
  Duration _lastOwnedPosition = Duration.zero;
  _DetachedMusicQueue? _detached;
  Timer? _detachedTimer;
  bool _returningDetached = false;
  CastMusicRecovery? _musicRecovery;
  StreamSubscription<Object?>? _recoveryConnections;
  bool _recoveringDetached = false;

  void bindMusicRecovery(MusicLibraryStore store, MultiServerManager manager) {
    if (store.profileId != _profileId || identical(_musicRecovery?.store, store)) return;
    unawaited(_recoveryConnections?.cancel());
    _musicRecovery = CastMusicRecovery(store, manager);
    _recoveryConnections = manager.statusStream.listen((_) => _tryRecoverDetached());
    if (isSupportedPlatform) {
      unawaited(
        initialize().then((_) => _tryRecoverDetached()).catchError((Object error) {
          appLogger.d('Cast queue recovery initialization failed (${error.runtimeType})');
        }),
      );
    }
  }

  void unbindMusicRecovery(MusicLibraryStore store) {
    if (!identical(_musicRecovery?.store, store)) return;
    _musicRecovery = null;
    unawaited(_recoveryConnections?.cancel());
    _recoveryConnections = null;
  }

  void _tryRecoverDetached() {
    final recovery = _musicRecovery;
    if (!isSupportedPlatform || recovery == null || _recoveringDetached || _detached != null || _activeItem != null) {
      return;
    }
    _recoveringDetached = true;
    unawaited(
      _loads.run(() async {
        try {
          final document = await recovery.read();
          final connection = castReceiverKey(_sessions.currentSession);
          if (!identical(_musicRecovery, recovery) ||
              document == null ||
              connection == null ||
              _detached != null ||
              _activeItem != null ||
              !recovery.store.active) {
            return;
          }
          final queue = CastMusicQueue.recover(
            document,
            manager: recovery.manager,
            connection: connection,
            status: _remote.mediaStatus,
          );
          if (queue == null) return;
          _detached = _DetachedMusicQueue(queue, connection)..committed = true;
          _detachedTimer?.cancel();
          _detachedTimer = Timer.periodic(const Duration(seconds: 2), (_) => _checkDetached());
          _checkDetached();
          notifyListeners();
        } catch (error) {
          appLogger.d('Cast queue recovery unavailable (${error.runtimeType})');
        } finally {
          _recoveringDetached = false;
        }
      }),
    );
  }

  void _forgetRecovery({String? token}) {
    final recovery = _musicRecovery;
    if (recovery == null) return;
    unawaited(
      recovery.clear(token: token).catchError((Object error) {
        appLogger.d('Cast queue recovery removal failed (${error.runtimeType})');
      }),
    );
  }

  void bindProfile(String? profileId) {
    if (_profileId == profileId) return;
    _forgetRecovery();
    _musicRecovery = null;
    unawaited(_recoveryConnections?.cancel());
    _recoveryConnections = null;
    unawaited(_stopMatchedReceiver());
    _profileId = profileId;
    _profileRevision++;
    _loadIntent++;
    _detached?.retire();
    _checkDetached();
    _ownership.clear();
    _receiverKey = null;
    _progressTimer?.cancel();
    _retirePlayback();
  }

  void _retirePlayback() {
    if (_activeItem == null) return;
    final revision = _ownership.revision;
    final position = _lastOwnedPosition;
    unawaited(
      _loads.run(() async {
        if (_ownership.revision == revision) await _finishPlayback(position);
      }),
    );
  }

  bool _matchesReceiver() {
    if (_receiverKey == null || _receiverKey != castReceiverKey(_sessions.currentSession)) return false;
    final status = _remote.mediaStatus;
    return status != null && _ownership.matches(_ownerToken(status), status.mediaSessionID);
  }

  bool _ownsReceiver() => _ownership.authorized && _matchesReceiver();

  bool get hasDetachedMusicQueue {
    final detached = _detached;
    return detached != null &&
        detached.committed &&
        detached.retiredAt == null &&
        detached.queue.authorized() &&
        _matchesDetached(detached);
  }

  bool get canReturnDetachedMusicQueue =>
      !_returningDetached &&
      hasDetachedMusicQueue &&
      _detached!.queue.canReturn(_remote.mediaStatus, _remote.queueItems);

  bool _matchesDetached(_DetachedMusicQueue detached) =>
      detached.queue.matches(detached.connection, castReceiverKey(_sessions.currentSession), _remote.mediaStatus);

  void _clearDetached(_DetachedMusicQueue detached) {
    if (!identical(_detached, detached)) return;
    _forgetRecovery(token: detached.queue.token);
    _detached = null;
    _detachedTimer?.cancel();
    _detachedTimer = null;
  }

  void _checkDetached() {
    final detached = _detached;
    if (detached == null) return;
    if (!detached.queue.authorized()) detached.retire();
    final status = _remote.mediaStatus;
    final connection = castReceiverKey(_sessions.currentSession);
    final matches = _matchesDetached(detached);
    if (detached.retiredAt case final retired?) {
      if ((connection == detached.connection && detached.queue.stopAcknowledged(status)) ||
          DateTime.now().difference(retired) >= const Duration(minutes: 1)) {
        _clearDetached(detached);
      } else if (matches && status?.playerState != CastMediaPlayerState.idle && !detached.stopping) {
        unawaited(_stopDetached(detached));
      }
    } else if (detached.committed &&
        connection != null &&
        (connection != detached.connection ||
            (status?.playerState == CastMediaPlayerState.idle &&
                status?.idleReason != null &&
                status?.idleReason != GoogleCastMediaIdleReason.none &&
                (status?.idleReason != GoogleCastMediaIdleReason.finished ||
                    !matches ||
                    detached.queue.isFinalOccurrence(status))) ||
            (!matches && status?.mediaInformation != null && status?.playerState != CastMediaPlayerState.idle))) {
      _clearDetached(detached);
    }
  }

  Future<void> _stopDetached(_DetachedMusicQueue detached) async {
    if (!_matchesDetached(detached) || detached.stopping) return;
    detached.stopping = true;
    try {
      await _remote.stop().timeout(const Duration(seconds: 5));
    } catch (error) {
      appLogger.d('Google Cast queue stop failed (${error.runtimeType})');
    } finally {
      detached.stopping = false;
    }
  }

  Future<void> _stopMatchedReceiver() async {
    if (!_matchesReceiver() || _remote.mediaStatus?.playerState == CastMediaPlayerState.idle) return;
    try {
      await _remote.stop().timeout(const Duration(seconds: 5));
    } catch (error) {
      appLogger.d('Google Cast stop failed (${error.runtimeType})');
    }
  }

  String? _ownerToken(GoggleCastMediaStatus status) {
    final value = status.mediaInformation?.customData?['pleazyngOwner'];
    return value == null
        ? null
        : value is String
        ? value
        : '';
  }

  bool get isConnected => isSupportedPlatform && _sessions.hasConnectedSession;
  String? get deviceName => _deviceName ?? _sessions.currentSession?.device?.friendlyName;
  MediaItem? get activeItem => _activeItem;
  GoggleCastMediaStatus? get mediaStatus => _remote.mediaStatus;
  Duration get playerPosition => _remote.playerPosition;

  Future<void> initialize() async {
    if (_initialized || !isSupportedPlatform) return;
    const applicationId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
    final options = Platform.isAndroid
        ? GoogleCastOptionsAndroid(appId: applicationId, stopCastingOnAppTerminated: false)
        : IOSGoogleCastOptions(
            GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(applicationId),
            stopCastingOnAppTerminated: false,
          );
    await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
    _sessionSubscription = _sessions.currentSessionStream.listen(_onSessionChanged);
    _statusSubscription = _remote.mediaStatusStream.listen(_onMediaStatusChanged);
    _queueSubscription = _remote.queueItemsStream.listen((_) => notifyListeners());
    _positionSubscription = _remote.playerPositionStream.listen((_) {
      if (_ownsReceiver() && _remote.mediaStatus?.playerState != CastMediaPlayerState.idle) {
        _lastOwnedPosition = _currentItemPosition();
      }
      notifyListeners();
    });
    _initialized = true;
  }

  Future<void> handleCastPressed(
    BuildContext context, {
    required MediaServerClient client,
    required MediaItem item,
    int mediaIndex = 0,
    String? mediaSourceId,
  }) async {
    await initialize();
    if (_sessions.hasConnectedSession) {
      if (_activeItem?.id == item.id && _activeItem?.serverId == item.serverId) {
        if (context.mounted) await showControls(context);
      } else {
        await _startSessionAndLoad(
          null,
          client: client,
          item: item,
          mediaIndex: mediaIndex,
          mediaSourceId: mediaSourceId,
        );
      }
      return;
    }

    if (!context.mounted) return;
    final device = await _pickDevice(context);
    if (device == null || !context.mounted) return;
    await _startSessionAndLoad(
      device,
      client: client,
      item: item,
      mediaIndex: mediaIndex,
      mediaSourceId: mediaSourceId,
    );
  }

  Future<CastMusicOutput?> connectMusicOutput(BuildContext context, MultiServerManager serverManager) async {
    await initialize();
    final profile = _profileRevision;
    final intent = ++_loadIntent;
    bool current() => profile == _profileRevision && intent == _loadIntent;
    final device = _sessions.hasConnectedSession || !context.mounted ? null : await _pickDevice(context);
    if (!current() || !context.mounted || (device == null && !_sessions.hasConnectedSession)) return null;
    return _loads.run(() async {
      if (!current()) return null;
      await _finishPlayback(_lastOwnedPosition);
      if (!current()) return null;
      if (device != null) {
        if (!await _sessions.startSessionWithDevice(device)) {
          throw const CastPlaybackException('Could not connect to that Cast device.');
        }
        await _waitForConnection();
      }
      if (!current() || !_sessions.hasConnectedSession) return null;
      if (device != null && _sessions.currentSession?.device?.deviceID != device.deviceID) return null;
      final receiver = GoogleMusicCastReceiver();
      if (!receiver.connected) return null;
      return CastMusicOutput(
        name: device?.friendlyName ?? _sessions.currentSession?.device?.friendlyName ?? t.cast.chooseDevice,
        serverManager: serverManager,
        authorized: current,
        receiver: receiver,
      );
    });
  }

  Future<MusicTransferResult> transferMusicQueue(
    BuildContext context, {
    required MusicTransferSession session,
    required MultiServerManager manager,
    required bool Function() available,
  }) async {
    final profile = _profileRevision;
    await initialize();
    if (!context.mounted || !isSupportedPlatform || profile != _profileRevision || _profileId == null || !available()) {
      return MusicTransferResult.unavailable;
    }
    final intent = _loadIntent;
    bool selected() => profile == _profileRevision && intent == _loadIntent && available();
    final device = _sessions.hasConnectedSession ? null : await _pickDevice(context);
    if (!selected() || !context.mounted || (device == null && !_sessions.hasConnectedSession)) {
      return MusicTransferResult.unavailable;
    }
    return _loads.run(() async {
      _checkDetached();
      if (!selected() || _detached != null || _activeItem != null) return MusicTransferResult.unavailable;
      _DetachedMusicQueue? binding;
      var admitted = false;
      var abandoned = false;
      try {
        if (device != null) {
          if (!await _sessions.startSessionWithDevice(device).timeout(const Duration(seconds: 10))) {
            return MusicTransferResult.rejected;
          }
          await _waitForConnection();
        }
        final connection = castReceiverKey(_sessions.currentSession);
        if (!selected() || connection == null || (device != null && device.deviceID != connection.device)) {
          return MusicTransferResult.superseded;
        }
        bool idle() => _remote.mediaStatus == null || _remote.mediaStatus?.playerState == CastMediaPlayerState.idle;
        bool connected() => connection == castReceiverKey(_sessions.currentSession);
        final original = session.offerTransfer();
        if (!idle() || original == null) return MusicTransferResult.unavailable;

        MusicTransferOffer? latest() {
          if (abandoned || !selected() || !connected()) return null;
          final offer = session.offerTransfer();
          return offer != null &&
                  offer.session == original.session &&
                  offer.generation == original.generation &&
                  offer.edit == original.edit &&
                  offer.transport == original.transport &&
                  offer.snapshot.playing == original.snapshot.playing
              ? offer
              : null;
        }

        final queue = await CastMusicQueue.prepare(
          original.snapshot,
          manager: manager,
          token: generateSessionIdentifier(),
          current: () => latest() != null && idle(),
        ).timeout(const Duration(seconds: 25));
        final offer = latest();
        if (offer == null || !idle()) return MusicTransferResult.superseded;
        final prepared = _DetachedMusicQueue(queue, connection);
        binding = prepared;
        _detached = prepared;
        _detachedTimer = Timer.periodic(const Duration(seconds: 2), (_) => _checkDetached());
        admitted = await queue.handoff(
          offer: offer,
          current: () => prepared.retiredAt == null && latest() != null,
          status: () => _remote.mediaStatus,
          statuses: _remote.mediaStatusStream,
          invalidated: _sessions.currentSessionStream
              .where((value) => castReceiverKey(value) != connection)
              .map<void>((_) {}),
          load: (items, options) => dispatchCastMusicQueue(items, options, android: Platform.isAndroid),
          play: _remote.play,
          armRepeat: (status) => queue.armRepeat(connection, status),
          finish: session.finishTransfer,
        );
        if (!admitted || prepared.retiredAt != null || !queue.authorized() || !_matchesDetached(prepared)) {
          admitted = false;
          return MusicTransferResult.superseded;
        }
        prepared.committed = true;
        final recovery = _musicRecovery;
        if (recovery != null && recovery.store.profileId == _profileId) {
          try {
            await recovery.save(queue, connection);
            if (!identical(_musicRecovery, recovery) || prepared.retiredAt != null) {
              await recovery.clear(token: queue.token);
            }
          } catch (error) {
            appLogger.d('Cast queue recovery save failed (${error.runtimeType})');
          }
        }
        notifyListeners();
        return MusicTransferResult.completed;
      } catch (error) {
        appLogger.d('Google Cast music queue handoff failed (${error.runtimeType})');
        return MusicTransferResult.rejected;
      } finally {
        abandoned = true;
        if (!admitted && binding != null) {
          binding.retire();
          _checkDetached();
        }
      }
    });
  }

  Future<MusicTransferResult> returnDetachedMusicQueue({
    required MusicDeviceSession session,
    required bool Function() available,
  }) => _loads.run(() async {
    final detached = _detached;
    if (detached == null || !canReturnDetachedMusicQueue || !available() || session.playback.isPlaying) {
      return MusicTransferResult.unavailable;
    }
    _returningDetached = true;
    notifyListeners();
    bool current() =>
        identical(_detached, detached) &&
        detached.retiredAt == null &&
        castReceiverKey(_sessions.currentSession) == detached.connection &&
        available();
    try {
      final accepted = await detached.queue.returnToLocal(
        current: current,
        status: () => _remote.mediaStatus,
        statuses: _remote.mediaStatusStream,
        invalidated: _sessions.currentSessionStream
            .where((value) => castReceiverKey(value) != detached.connection)
            .map<void>((_) {}),
        receiverItems: () => _remote.queueItems,
        position: () => _remote.playerPosition,
        pause: _remote.pause,
        resume: () async {
          if (!session.playback.isPlaying) await _remote.play();
        },
        prepare: (snapshot, current) => session.prepareMusicDeviceTransfer(snapshot, current: current),
      );
      if (!accepted) return MusicTransferResult.rejected;
      detached.retire();
      _checkDetached();
      return MusicTransferResult.completed;
    } catch (error) {
      appLogger.d('Google Cast queue return failed (${error.runtimeType})');
      return MusicTransferResult.rejected;
    } finally {
      _returningDetached = false;
      notifyListeners();
    }
  });

  Future<GoogleCastDevice?> _pickDevice(BuildContext context) async {
    await _discovery.startDiscovery(activeScan: Platform.isAndroid);
    try {
      if (!context.mounted) return null;
      return await showModalBottomSheet<GoogleCastDevice>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                  child: Text(t.cast.chooseDevice, style: Theme.of(sheetContext).textTheme.titleLarge),
                ),
                Expanded(
                  child: StreamBuilder<List<GoogleCastDevice>>(
                    stream: _discovery.devicesStream,
                    initialData: _discovery.devices,
                    builder: (context, snapshot) {
                      final devices = snapshot.data ?? const <GoogleCastDevice>[];
                      if (devices.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              Text(t.cast.searching),
                            ],
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: devices.length,
                        itemBuilder: (context, index) {
                          final device = devices[index];
                          return ListTile(
                            leading: const AppIcon(Symbols.cast_rounded),
                            title: Text(device.friendlyName),
                            subtitle: device.modelName == null ? null : Text(device.modelName!),
                            onTap: () => Navigator.of(context).pop(device),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      await _discovery.stopDiscovery();
    }
  }

  Future<void> _startSessionAndLoad(
    GoogleCastDevice? device, {
    required MediaServerClient client,
    required MediaItem item,
    required int mediaIndex,
    String? mediaSourceId,
  }) {
    final intent = ++_loadIntent;
    final profile = _profileRevision;
    final authentication = client.authenticationSessionId;
    bool current() =>
        intent == _loadIntent &&
        profile == _profileRevision &&
        identical(authentication, client.authenticationSessionId);
    return _loads.run(() async {
      if (!current()) return;
      await _finishPlayback(_lastOwnedPosition);
      if (!current()) return;
      await _loadOwnedMedia(
        device,
        client: client,
        item: item,
        mediaIndex: mediaIndex,
        mediaSourceId: mediaSourceId,
        current: current,
      );
    });
  }

  Future<void> _loadOwnedMedia(
    GoogleCastDevice? device, {
    required MediaServerClient client,
    required MediaItem item,
    required int mediaIndex,
    required bool Function() current,
    String? mediaSourceId,
  }) async {
    var createdSession = false;
    if (device != null) {
      final started = await _sessions.startSessionWithDevice(device);
      if (!started) throw const CastPlaybackException('Could not connect to that Cast device.');
      createdSession = true;
    } else if (!_sessions.hasConnectedSession) {
      throw const CastPlaybackException('The Cast device is no longer connected.');
    }

    try {
      if (device != null) await _waitForConnection();
      if (!current()) return;
      final connection = castReceiverKey(_sessions.currentSession);
      if (connection == null || (device != null && device.deviceID != connection.device)) {
        throw const CastPlaybackException('The Cast device is no longer connected.');
      }
      bool authorized() => current() && castReceiverKey(_sessions.currentSession) == connection;
      final resume = item.viewOffsetMs != null && item.viewOffsetMs! > 0
          ? Duration(milliseconds: item.viewOffsetMs!)
          : null;
      final target = await client.resolveExternalPlayback(
        item,
        mediaIndex: mediaIndex,
        mediaSourceId: mediaSourceId,
        position: resume,
      );
      if (!authorized()) return;
      if (target == null || target.url.isEmpty) {
        throw const CastPlaybackException('This item is not available for casting.');
      }
      final uri = Uri.tryParse(target.url);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
        throw const CastPlaybackException('The server did not provide a Cast-compatible stream.');
      }

      final part = target.partTimeline?.current;
      final partStart = part?.start ?? Duration.zero;
      final filePosition = target.partTimeline == null
          ? resume ?? Duration.zero
          : resume != null && target.partTimeline!.covers(resume)
          ? resume - partStart
          : Duration.zero;
      final duration =
          target.partTimeline?.duration ??
          (item.durationMs != null && item.durationMs! > 0 ? Duration(milliseconds: item.durationMs!) : null);
      final textTracks = _castTracks(target.subtitles);
      final streamType = CastMediaStreamType.buffered;
      final token = generateSessionIdentifier();
      _receiverKey = connection;
      _ownership.begin(token, authorized);
      final information = GoogleCastMediaInformation(
        contentId: uri.toString(),
        contentUrl: uri,
        contentType: _contentType(uri),
        streamType: streamType,
        duration: duration,
        metadata: GoogleCastGenericMediaMetadata(title: item.displayTitle, subtitle: item.displaySubtitle),
        tracks: textTracks.tracks.isEmpty ? null : textTracks.tracks,
        customData: {'pleazyngOwner': token},
      );

      bool acknowledged(GoggleCastMediaStatus? status) =>
          status != null && _ownership.acknowledge(_ownerToken(status), status.mediaSessionID);
      await loadAcknowledgedCastMedia(
        statuses: _remote.mediaStatusStream,
        acknowledge: acknowledged,
        invalidated: _sessions.currentSessionStream
            .where((session) => castReceiverKey(session) != connection)
            .map<void>((_) {}),
        load: () => _remote.loadMedia(
          information,
          autoPlay: false,
          playPosition: filePosition,
          activeTrackIds: textTracks.defaultTrackIds.isEmpty ? null : textTracks.defaultTrackIds,
        ),
      );
      if (!_ownsReceiver()) {
        await _stopMatchedReceiver();
        return;
      }
      await _remote.play().timeout(const Duration(seconds: 10));
      if (!_ownsReceiver()) {
        await _stopMatchedReceiver();
        return;
      }

      _deviceName = device?.friendlyName ?? _sessions.currentSession?.device?.friendlyName ?? _deviceName;
      _activeItem = item;
      _activeClient = client;
      _playSessionId = target.playSessionId;
      _partStart = partStart;
      _duration = duration;
      _lastPausedState = null;
      _lastOwnedPosition = resume ?? Duration.zero;
      _beginProgressReporting();
      notifyListeners();
    } catch (error) {
      if (createdSession && current() && _ownsReceiver()) await _sessions.endSessionAndStopCasting();
      await _stopMatchedReceiver();
      _ownership.clear();
      _receiverKey = null;
      if (error is CastPlaybackException) rethrow;
      appLogger.w('Google Cast could not load media (${error.runtimeType})');
      throw const CastPlaybackException('Could not start playback on this Cast device.');
    } finally {
      if (_activeItem == null) {
        _ownership.clear();
        _receiverKey = null;
      }
    }
  }

  Future<void> _waitForConnection() async {
    if (_sessions.hasConnectedSession) return;
    await _sessions.currentSessionStream
        .firstWhere((session) => session?.connectionState == GoogleCastConnectState.connected)
        .timeout(const Duration(seconds: 30));
  }

  ({List<GoogleCastMediaTrack> tracks, List<int> defaultTrackIds}) _castTracks(List<SubtitleTrack> subtitles) {
    final tracks = <GoogleCastMediaTrack>[];
    final defaults = <int>[];
    for (final subtitle in subtitles) {
      final rawUri = subtitle.uri;
      if (rawUri == null) continue;
      final uri = Uri.tryParse(rawUri);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) continue;
      final extension = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.split('.').last.toLowerCase();
      final contentType = switch (extension) {
        'vtt' => 'text/vtt',
        'srt' => 'application/x-subrip',
        _ => null,
      };
      if (contentType == null) continue;
      final id = tracks.length + 1;
      tracks.add(
        GoogleCastMediaTrack(
          trackId: id,
          type: TrackType.text,
          subtype: TextTrackType.subtitles,
          trackContentId: uri.toString(),
          trackContentType: contentType,
          name: subtitle.title ?? subtitle.language ?? t.cast.subtitle,
        ),
      );
      if (subtitle.isDefault) defaults.add(id);
    }
    return (tracks: tracks, defaultTrackIds: defaults);
  }

  static String _contentType(Uri uri) {
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.toLowerCase();
    if (name.endsWith('.m3u8')) return 'application/x-mpegURL';
    if (name.endsWith('.mpd')) return 'application/dash+xml';
    if (name.endsWith('.webm')) return 'video/webm';
    if (name.endsWith('.mov')) return 'video/quicktime';
    if (name.endsWith('.mkv')) return 'video/x-matroska';
    if (name.endsWith('.ts')) return 'video/mp2t';
    if (name.endsWith('.mp3')) return 'audio/mpeg';
    if (name.endsWith('.m4a')) return 'audio/mp4';
    return 'video/mp4';
  }

  void _beginProgressReporting() {
    final item = _activeItem;
    final client = _activeClient;
    final duration = _duration;
    if (item == null || client == null || !_ownership.authorized) return;

    if (duration != null && duration > Duration.zero) {
      _reportSession = PlaybackReportSession(
        client: client,
        itemId: item.id,
        playMethod: 'DirectPlay',
        playSessionId: _playSessionId,
      );
      if (_ownsReceiver()) unawaited(_reportPosition(_currentItemPosition(), isStopped: false));
    }
    unawaited(TrackerCoordinator.instance.startPlayback(item, client));
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_ownsReceiver()) {
        unawaited(_reportPosition(_currentItemPosition(), isStopped: false));
      } else {
        unawaited(_stopMatchedReceiver());
        _retirePlayback();
      }
    });
  }

  Duration _currentItemPosition() => _partStart + _remote.playerPosition;

  Future<void> _reportPosition(Duration position, {required bool isStopped}) async {
    final item = _activeItem;
    final client = _activeClient;
    final duration = _duration;
    final reportSession = _reportSession;
    if (item == null || client == null || !_ownership.authorized) return;
    if (!isStopped && !_ownsReceiver()) return;
    final revision = _ownership.revision;
    bool current() => revision == _ownership.revision && _ownership.authorized;

    final clampedPosition = duration == null
        ? position
        : Duration(milliseconds: position.inMilliseconds.clamp(0, duration.inMilliseconds).toInt());
    final status = _remote.mediaStatus;
    final paused = status?.playerState == CastMediaPlayerState.paused;
    var stoppedReportSucceeded = false;
    if (_lastPausedState != null && _lastPausedState != paused) {
      if (paused) {
        unawaited(TrackerCoordinator.instance.pausePlayback());
      } else {
        unawaited(TrackerCoordinator.instance.resumePlayback());
      }
    }
    _lastPausedState = paused;
    TrackerCoordinator.instance.updatePosition(clampedPosition);

    if (reportSession != null && duration != null) {
      try {
        final delivered = await reportSession.report(
          PlaybackReportSnapshot(
            state: isStopped
                ? 'stopped'
                : paused
                ? 'paused'
                : 'playing',
            position: clampedPosition,
            duration: duration,
          ),
        );
        if (isStopped) stoppedReportSucceeded = delivered;
        if (!isStopped && current()) {
          WatchStateNotifier().notifyProgress(
            item: item,
            cacheServerId: client.cacheServerId,
            viewOffset: clampedPosition.inMilliseconds,
            duration: duration.inMilliseconds,
            watchedThreshold: client.watchedThreshold,
            serverAcknowledged: true,
          );
        }
      } catch (error) {
        appLogger.d('Google Cast progress report failed (${error.runtimeType})');
      }
    }

    if (!isStopped ||
        !current() ||
        !stoppedReportSucceeded ||
        duration == null ||
        clampedPosition.inMilliseconds < duration.inMilliseconds * client.watchedThreshold) {
      return;
    }
    try {
      await client.markWatchedFromPlaybackStop(item);
      WatchStateNotifier().notifyWatched(item: item, cacheServerId: client.cacheServerId, serverAcknowledged: true);
      await TrackerCoordinator.instance.markWatched(item, client);
    } catch (error) {
      appLogger.d('Google Cast watched-state update failed (${error.runtimeType})');
    }
  }

  void _onSessionChanged(GoogleCastSession? session) {
    _checkDetached();
    _tryRecoverDetached();
    if (castReceiverKey(session) != _receiverKey && _activeItem != null && !_finishingPlayback) {
      _retirePlayback();
    }
    if (session?.device?.friendlyName case final String name) _deviceName = name;
    notifyListeners();
  }

  void _onMediaStatusChanged(GoggleCastMediaStatus? status) {
    _checkDetached();
    _tryRecoverDetached();
    if (_activeItem != null) {
      if (!_ownsReceiver()) {
        _progressTimer?.cancel();
        unawaited(_stopMatchedReceiver());
        _retirePlayback();
        return;
      }
      if (status?.playerState != CastMediaPlayerState.idle) _lastOwnedPosition = _currentItemPosition();
      if (status?.playerState == CastMediaPlayerState.idle &&
          status?.idleReason != null &&
          status?.idleReason != GoogleCastMediaIdleReason.none) {
        if (status?.idleReason == GoogleCastMediaIdleReason.finished && _duration != null) {
          _lastOwnedPosition = _duration!;
        }
        _retirePlayback();
      } else if ((status?.playerState == CastMediaPlayerState.playing ||
              status?.playerState == CastMediaPlayerState.paused) &&
          _lastPausedState != (status?.playerState == CastMediaPlayerState.paused)) {
        unawaited(_reportPosition(_currentItemPosition(), isStopped: false));
      }
    }
    notifyListeners();
  }

  Future<void> _finishPlayback(Duration position) async {
    if (_finishingPlayback || _activeItem == null) return;
    _finishingPlayback = true;
    try {
      _progressTimer?.cancel();
      _progressTimer = null;
      if (_ownership.authorized) await _reportPosition(position, isStopped: true);
      await TrackerCoordinator.instance.stopPlayback();
      _reportSession = null;
      _activeItem = null;
      _activeClient = null;
      _playSessionId = null;
      _partStart = Duration.zero;
      _duration = null;
      _lastPausedState = null;
      _ownership.clear();
      _receiverKey = null;
      notifyListeners();
    } finally {
      _finishingPlayback = false;
    }
  }

  Future<void> showControls(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => AnimatedBuilder(
        animation: this,
        builder: (context, _) {
          final status = _remote.mediaStatus;
          final detached = hasDetachedMusicQueue;
          final metadata = status?.mediaInformation?.metadata;
          final isPaused = status?.playerState == CastMediaPlayerState.paused;
          final isPlaying =
              status?.playerState == CastMediaPlayerState.playing ||
              status?.playerState == CastMediaPlayerState.buffering;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.cast.connectedTo(device: deviceName ?? t.cast.device),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _activeItem?.displayTitle ??
                        (detached && metadata is GoogleCastGenericMediaMetadata ? metadata.title : null) ??
                        t.cast.readyToCast,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 18),
                  StreamBuilder<Duration>(
                    stream: _remote.playerPositionStream,
                    initialData: _remote.playerPosition,
                    builder: (context, snapshot) {
                      final position = _partStart + (snapshot.data ?? Duration.zero);
                      final duration = detached ? status?.mediaInformation?.duration : _duration;
                      return Text(
                        duration == null
                            ? _formatDuration(position)
                            : '${_formatDuration(position)} / ${_formatDuration(duration)}',
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      IconButton.filledTonal(
                        tooltip: isPaused ? t.common.resume : t.common.pause,
                        onPressed: !(_ownsReceiver() || detached && !_returningDetached) || !isPaused && !isPlaying
                            ? null
                            : () {
                                if (_ownsReceiver() || canReturnDetachedMusicQueue) {
                                  unawaited(isPaused ? _remote.play() : _remote.pause());
                                }
                              },
                        icon: AppIcon(isPaused ? Symbols.play_arrow_rounded : Symbols.pause_rounded),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: t.cast.stopCasting,
                        onPressed: () async {
                          final queue = _detached;
                          if (canReturnDetachedMusicQueue && queue != null) {
                            queue.retire();
                            await _stopDetached(queue);
                            if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                            return;
                          }
                          if (!_ownsReceiver()) return;
                          final status = _remote.mediaStatus!;
                          final token = _ownerToken(status);
                          final profile = _profileRevision;
                          await _remote.stop();
                          final current = _remote.mediaStatus;
                          if (profile == _profileRevision &&
                              current != null &&
                              current.mediaSessionID == status.mediaSessionID &&
                              _ownerToken(current) == token) {
                            await _sessions.endSessionAndStopCasting();
                          }
                          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                        },
                        icon: const AppIcon(Symbols.stop_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _formatDuration(Duration value) {
    String two(int number) => number.toString().padLeft(2, '0');
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0 ? '$hours:${two(minutes)}:${two(seconds)}' : '$minutes:${two(seconds)}';
  }

  @override
  void dispose() {
    _loadIntent++;
    _ownership.clear();
    _progressTimer?.cancel();
    _detachedTimer?.cancel();
    _detached = null;
    unawaited(_recoveryConnections?.cancel());
    unawaited(_sessionSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    unawaited(_queueSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    super.dispose();
  }
}

class _DetachedMusicQueue {
  _DetachedMusicQueue(this.queue, this.connection);

  final CastMusicQueue queue;
  final CastReceiverKey connection;
  DateTime? retiredAt;
  bool committed = false;
  bool stopping = false;

  void retire() => retiredAt ??= DateTime.now();
}

class CastPlaybackException implements Exception {
  const CastPlaybackException(this.message);
  final String message;
}
