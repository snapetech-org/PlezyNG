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

class CastMusicQueue {
  CastMusicQueue._(this.items, this._snapshot, this.token, this.authorized);

  static const maxTracks = 32;
  static const maxRequestBytes = 48 * 1024;
  static const ownerKey = 'pleazyngOwner';
  static const occurrenceKey = 'pleazyngOccurrence';

  final List<GoogleCastQueueItem> items;
  final MusicTransferSnapshot _snapshot;
  final String token;
  final bool Function() authorized;
  int? _mediaSessionId;

  int get cursor => _snapshot.queue.cursor;

  GoogleCastQueueLoadOptions options(Duration position) =>
      GoogleCastQueueLoadOptions(startIndex: cursor, playPosition: position);

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
      _occurrence(status) == cursor && status?.playerState == state;

  bool isFinalOccurrence(GoggleCastMediaStatus? status) => _occurrence(status) == items.length - 1;

  Future<bool> handoff({
    required MusicTransferOffer offer,
    required bool Function() current,
    required GoggleCastMediaStatus? Function() status,
    required Stream<GoggleCastMediaStatus?> statuses,
    required Stream<void> invalidated,
    required Future<void> Function(List<GoogleCastQueueItem>, GoogleCastQueueLoadOptions) load,
    required Future<void> Function() play,
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
    if (_mediaSessionId == null || index == null || !current() || !authorized()) return false;
    final wasPlaying =
        start?.playerState == CastMediaPlayerState.playing || start?.playerState == CastMediaPlayerState.buffering;
    if (!wasPlaying && start?.playerState != CastMediaPlayerState.paused) return false;
    bool sameOccurrence(GoggleCastMediaStatus? value) => _occurrence(value) == index;
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
          repeatMode: queue.repeatMode,
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
    if (queue.repeatMode != MusicRepeatMode.off) throw StateError('Receiver queue requires repeat off');
    final tracks = [for (final index in queue.order) queue.items[index]];
    final sources = <ServerId, ({MediaServerClient client, Object? authentication})>{};
    for (final track in tracks) {
      final id = ServerId(track.serverId!);
      final client = manager.getClient(id);
      if (client == null || client.backend != track.backend || client.isOfflineMode || !manager.isServerVisible(id)) {
        throw StateError('Receiver queue contains an unavailable music source');
      }
      sources[id] = (client: client, authentication: client.authenticationSessionId);
    }

    bool authorized() => sources.entries.every((entry) {
      final client = entry.value.client;
      return identical(manager.getClient(entry.key), client) &&
          identical(client.authenticationSessionId, entry.value.authentication) &&
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
    final prepared = CastMusicQueue._(List.unmodifiable(items), snapshot, token, authorized);
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
