import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../cast_playback_ownership.dart';
import '../multi_server_manager.dart';
import 'cast_music_output.dart';
import 'music_device_session.dart';
import 'music_playback_service.dart';
import 'music_queue_controller.dart';
import 'music_transfer_snapshot.dart';
import 'music_account_scope.dart';

class CastMusicQueue {
  CastMusicQueue._(this.items, this._snapshot, this.token, this.authorized, this._accounts);

  static const maxTracks = 32;
  static const maxRequestBytes = 48 * 1024;
  static const ownerKey = 'pleazyngOwner';
  static const occurrenceKey = 'pleazyngOccurrence';

  final List<GoogleCastQueueItem> items;
  final MusicTransferSnapshot _snapshot;
  final String token;
  final bool Function() authorized;
  final Map<String, String> _accounts;
  int? _mediaSessionId;

  int get cursor => _snapshot.queue.cursor;

  Map<String, dynamic> recoveryDocument(CastReceiverKey connection, {DateTime? now}) {
    if (_mediaSessionId == null || !authorized()) throw StateError('Cast queue is not acknowledged');
    return {
      'version': 1,
      'token': token,
      'session': connection.session,
      'device': connection.device,
      'mediaSession': _mediaSessionId,
      'created': (now ?? DateTime.now()).millisecondsSinceEpoch,
      'accounts': _accounts,
      'snapshot': _snapshot.toJson(itemLimit: maxTracks),
    };
  }

  /// Recovers control only. No streams are resolved or loaded into the receiver.
  static CastMusicQueue? recover(
    Map<String, dynamic> document, {
    required MultiServerManager manager,
    required CastReceiverKey connection,
    required GoggleCastMediaStatus? status,
    DateTime? now,
  }) {
    try {
      if (utf8.encode(jsonEncode(document)).length > maxRequestBytes) return null;
      final token = document['token'], mediaSession = document['mediaSession'], created = document['created'];
      final clock = (now ?? DateTime.now()).millisecondsSinceEpoch;
      if (document['version'] != 1 ||
          token is! String ||
          token.isEmpty ||
          token.length > 128 ||
          document['session'] != connection.session ||
          document['device'] != connection.device ||
          mediaSession is! int ||
          mediaSession <= 0 ||
          created is! int ||
          created > clock ||
          clock - created > const Duration(days: 7).inMilliseconds) {
        return null;
      }
      final snapshot = MusicTransferSnapshot.tryParse(document['snapshot'], itemLimit: maxTracks);
      if (snapshot == null || snapshot.queue.items.length > maxTracks) {
        return null;
      }
      final accounts = Map<String, String>.from(document['accounts'] as Map);
      final sources = <ServerId, ({MediaServerClient client, Object? authentication})>{};
      for (final track in snapshot.queue.items) {
        final id = ServerId(track.serverId!);
        final client = manager.getClient(id);
        if (client == null ||
            client.backend != track.backend ||
            client.isOfflineMode ||
            !manager.isServerVisible(id) ||
            accounts[id.value] != musicAccountScope(client)) {
          return null;
        }
        sources[id] = (client: client, authentication: client.authenticationSessionId);
      }
      if (sources.length != accounts.length) return null;
      bool authorized() => sources.entries.every(
        (source) =>
            identical(manager.getClient(source.key), source.value.client) &&
            identical(source.value.client.authenticationSessionId, source.value.authentication) &&
            accounts[source.key.value] == musicAccountScope(source.value.client) &&
            !source.value.client.isOfflineMode &&
            manager.isServerVisible(source.key),
      );
      final queue = CastMusicQueue._(
        List.unmodifiable([
          for (var index = 0; index < snapshot.queue.items.length; index++)
            GoogleCastQueueItem(
              mediaInformation: GoogleCastMediaInformation(
                contentId: 'pleazyng:$token:$index',
                contentType: 'audio/*',
                streamType: CastMediaStreamType.buffered,
                customData: {ownerKey: token, occurrenceKey: index.toString()},
              ),
            ),
        ]),
        snapshot,
        token,
        authorized,
        accounts,
      ).._mediaSessionId = mediaSession;
      return queue.matchesMedia(status) ? queue : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  GoogleCastMediaRepeatMode get _repeat => switch (_snapshot.queue.repeatMode) {
    MusicRepeatMode.off => GoogleCastMediaRepeatMode.off,
    MusicRepeatMode.one => GoogleCastMediaRepeatMode.single,
    MusicRepeatMode.all => GoogleCastMediaRepeatMode.all,
  };

  static MusicRepeatMode? _localRepeat(GoggleCastMediaStatus? status) => switch (status?.repeatMode) {
    GoogleCastMediaRepeatMode.off => MusicRepeatMode.off,
    GoogleCastMediaRepeatMode.single => MusicRepeatMode.one,
    GoogleCastMediaRepeatMode.all => MusicRepeatMode.all,
    _ => null,
  };

  GoogleCastQueueLoadOptions options(Duration position) =>
      GoogleCastQueueLoadOptions(startIndex: cursor, playPosition: position, repeatMode: _repeat);

  /// The native SDK clones only the acknowledged current queue item. No media
  /// URLs cross this channel and the receiver must remain paused throughout.
  Future<bool> armRepeat(CastReceiverKey connection, GoggleCastMediaStatus status) async {
    if (_repeat == GoogleCastMediaRepeatMode.off ||
        !authorized() ||
        !acknowledges(status, CastMediaPlayerState.paused)) {
      return false;
    }
    return await const MethodChannel('com.pleazyng/cast_music_queue')
            .invokeMethod<bool>('armRepeat', {
              'session': connection.session,
              'device': connection.device,
              'mediaSession': status.mediaSessionID,
              'item': status.currentItemId,
              'token': token,
              'occurrence': cursor.toString(),
              'contentId': items[cursor].mediaInformation.contentId,
              'repeat': _repeat.value,
            })
            .timeout(const Duration(seconds: 10)) ==
        true;
  }

  bool matches(CastReceiverKey connection, CastReceiverKey? current, GoggleCastMediaStatus? status) =>
      connection == current && matchesMedia(status);

  bool matchesMedia(GoggleCastMediaStatus? status) => _occurrence(status) != null;

  int? _occurrence(GoggleCastMediaStatus? status) {
    final custom = status?.mediaInformation?.customData;
    final rawIndex = custom?[occurrenceKey];
    final index = rawIndex is String ? int.tryParse(rawIndex) : null;
    if (status == null ||
        status.mediaSessionID <= 0 ||
        (_mediaSessionId != null && _mediaSessionId != status.mediaSessionID) ||
        (status.currentItemId ?? 0) <= 0 ||
        custom?[ownerKey] != token ||
        index == null ||
        index < 0 ||
        index >= items.length ||
        status.mediaInformation?.contentId != items[index].mediaInformation.contentId) {
      return null;
    }
    return index;
  }

  bool acknowledges(GoggleCastMediaStatus? status, CastMediaPlayerState state) =>
      _occurrence(status) == cursor && status?.playerState == state && status?.repeatMode == _repeat;

  bool isFinalOccurrence(GoggleCastMediaStatus? status) =>
      status?.repeatMode == GoogleCastMediaRepeatMode.off && _occurrence(status) == items.length - 1;

  bool stopAcknowledged(GoggleCastMediaStatus? status) =>
      _mediaSessionId != null &&
      status?.mediaSessionID == _mediaSessionId &&
      status?.playerState == CastMediaPlayerState.idle &&
      status?.idleReason == GoogleCastMediaIdleReason.cancelled;

  Future<bool> handoff({
    required MusicTransferOffer offer,
    required bool Function() current,
    required GoggleCastMediaStatus? Function() status,
    required Stream<GoggleCastMediaStatus?> statuses,
    required Stream<void> invalidated,
    required Future<void> Function(List<GoogleCastQueueItem>, GoogleCastQueueLoadOptions) load,
    required Future<void> Function() play,
    Future<bool> Function(GoggleCastMediaStatus)? armRepeat,
    required Future<bool> Function(MusicTransferOffer) finish,
  }) async {
    bool valid() => current() && authorized();
    if (!valid()) return false;
    await loadAcknowledgedCastMedia(
      statuses: statuses,
      invalidated: invalidated,
      acknowledge: (value) => valid() && acknowledges(value, CastMediaPlayerState.paused),
      load: () => load(items, options(offer.snapshot.position)),
    );
    final loaded = status();
    if (!valid() || !acknowledges(loaded, CastMediaPlayerState.paused)) return false;
    _mediaSessionId = loaded!.mediaSessionID;
    if (_repeat != GoogleCastMediaRepeatMode.off) {
      if (armRepeat == null ||
          !await armRepeat(loaded) ||
          !valid() ||
          !acknowledges(status(), CastMediaPlayerState.paused)) {
        return false;
      }
    }
    if (offer.snapshot.playing) {
      await loadAcknowledgedCastMedia(
        statuses: statuses,
        invalidated: invalidated,
        acknowledge: (value) => valid() && acknowledges(value, CastMediaPlayerState.playing),
        load: play,
      );
      if (!valid() || !acknowledges(status(), CastMediaPlayerState.playing)) return false;
    }
    return finish(offer);
  }

  Future<bool> returnToLocal({
    required bool Function() current,
    required GoggleCastMediaStatus? Function() status,
    required Stream<GoggleCastMediaStatus?> statuses,
    required Stream<void> invalidated,
    required Duration Function() position,
    required Future<void> Function() pause,
    required Future<void> Function() resume,
    required Future<PreparedMusicDeviceTransfer?> Function(MusicTransferSnapshot snapshot, bool Function() current)
    prepare,
  }) async {
    final start = status();
    final index = _occurrence(start);
    final repeat = _localRepeat(start);
    if (_mediaSessionId == null || index == null || repeat == null || !current() || !authorized()) return false;
    final wasPlaying =
        start?.playerState == CastMediaPlayerState.playing || start?.playerState == CastMediaPlayerState.buffering;
    if (!wasPlaying && start?.playerState != CastMediaPlayerState.paused) return false;
    bool sameOccurrence(GoggleCastMediaStatus? value) => _occurrence(value) == index && _localRepeat(value) == repeat;
    bool owned() => current() && authorized() && sameOccurrence(status());
    bool paused() => owned() && status()?.playerState == CastMediaPlayerState.paused;

    var frozen = false;
    var accepted = false;
    final queue = _snapshot.queue;
    final commit = await prepare(
      MusicTransferSnapshot(
        queue: MusicQueueState(
          items: queue.items,
          order: queue.order,
          cursor: index,
          shuffled: queue.shuffled,
          repeatMode: repeat,
        ),
        position: Duration.zero,
        playing: false,
        playContext: _snapshot.playContext,
      ),
      () => frozen ? paused() : owned(),
    );
    if (commit == null || !owned()) return false;
    try {
      if (wasPlaying) {
        final state = status()?.playerState;
        if (state != CastMediaPlayerState.playing && state != CastMediaPlayerState.buffering) return false;
        await loadAcknowledgedCastMedia(
          statuses: statuses,
          invalidated: invalidated,
          acknowledge: (value) =>
              current() && authorized() && sameOccurrence(value) && value?.playerState == CastMediaPlayerState.paused,
          load: pause,
        );
      }
      if (!paused()) return false;
      frozen = true;
      final playhead = position();
      if (playhead < Duration.zero || playhead > const Duration(hours: 24)) return false;
      accepted = await commit(playhead, wasPlaying);
      return accepted;
    } finally {
      if (frozen && wasPlaying && !accepted && paused()) {
        await resume().timeout(const Duration(seconds: 5));
      }
    }
  }

  static Future<CastMusicQueue> prepare(
    MusicTransferSnapshot snapshot, {
    required MultiServerManager manager,
    required String token,
    required bool Function() current,
  }) async {
    snapshot.toJson(itemLimit: maxTracks);
    final queue = snapshot.queue;
    final tracks = [for (final index in queue.order) queue.items[index]];
    final sources = <ServerId, ({MediaServerClient client, Object? authentication, String account})>{};
    for (final track in tracks) {
      final id = ServerId(track.serverId!);
      final client = manager.getClient(id);
      if (client == null || client.backend != track.backend || client.isOfflineMode || !manager.isServerVisible(id)) {
        throw StateError('Receiver queue contains an unavailable music source');
      }
      sources[id] = (
        client: client,
        authentication: client.authenticationSessionId,
        account: musicAccountScope(client),
      );
    }

    bool authorized() => sources.entries.every((entry) {
      final client = entry.value.client;
      return identical(manager.getClient(entry.key), client) &&
          identical(client.authenticationSessionId, entry.value.authentication) &&
          musicAccountScope(client) == entry.value.account &&
          manager.isServerVisible(entry.key) &&
          !client.isOfflineMode;
    });

    void verify() {
      if (!current() || !authorized()) throw StateError('Receiver queue source changed');
    }

    final items = <GoogleCastQueueItem>[];
    final resolved = <String, Uri>{};
    for (final (index, track) in tracks.indexed) {
      verify();
      final uri = resolved[track.globalKey] ??= await _resolve(sources[ServerId(track.serverId!)]!.client, track);
      verify();
      items.add(
        GoogleCastQueueItem(
          autoPlay: index != queue.cursor,
          mediaInformation: GoogleCastMediaInformation(
            contentId: 'pleazyng:$token:$index',
            contentUrl: uri,
            contentType: castMusicContentType(uri, container: track.mediaVersions?.firstOrNull?.container),
            streamType: CastMediaStreamType.buffered,
            duration: track.durationMs == null ? null : Duration(milliseconds: track.durationMs!),
            metadata: GoogleCastGenericMediaMetadata(title: track.displayTitle, subtitle: track.trackArtistTitle),
            customData: {ownerKey: token, occurrenceKey: index.toString()},
          ),
        ),
      );
    }
    final prepared = CastMusicQueue._(List.unmodifiable(items), snapshot, token, authorized, {
      for (final source in sources.entries) source.key.value: source.value.account,
    });
    final size = utf8
        .encode(
          jsonEncode({
            'items': [for (final item in items) item.toMap()],
            'options': prepared.options(snapshot.position).toMap(),
          }),
        )
        .length;
    if (size > maxRequestBytes) throw StateError('Receiver queue exceeds the Cast message budget');
    return prepared;
  }

  static Future<Uri> _resolve(MediaServerClient client, MediaItem track) async {
    final target = await client.resolveExternalPlayback(track);
    final uri = target == null ? null : Uri.tryParse(target.url);
    if (target == null ||
        target.partTimeline != null ||
        target.url.length > 8192 ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw StateError('Track has no standalone Cast stream');
    }
    return uri;
  }
}

Future<void> dispatchCastMusicQueue(
  List<GoogleCastQueueItem> items,
  GoogleCastQueueLoadOptions options, {
  required bool android,
}) async {
  final channel = MethodChannel(
    android ? 'com.felnanuke.google_cast.remote_media_client' : 'google_cast.remote_media_client',
  );
  await channel.invokeMethod<Object?>('queueLoadItems', {
    (android ? 'queueItems' : 'items'): [
      for (final item in items) {...item.toMap(), if (android) 'autoPlay': item.autoPlay},
    ],
    'options': options.toMap(android: android),
  });
}
