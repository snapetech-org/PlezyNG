import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import 'music_playback_service.dart';
import 'music_queue_controller.dart';

enum MusicTransferResult { completed, unavailable, rejected, superseded }

/// A sender's queue and intent when the user requested handoff. Only the
/// snapshot travels over the peer channel; the revisions stay local.
class MusicTransferOffer {
  const MusicTransferOffer(this.snapshot, this.session, this.generation, this.edit, this.transport);
  final MusicTransferSnapshot snapshot;
  final int session, generation, edit, transport;
}

abstract interface class MusicTransferSession {
  MusicTransferOffer? offerTransfer();
  Future<bool> acceptTransfer(MusicTransferSnapshot snapshot, {bool Function()? current});
  Future<bool> finishTransfer(MusicTransferOffer offer);
}

/// A portable queue for an already paired receiver. Only catalog identities
/// and display metadata cross the wire; the receiver resolves its own streams.
/// Canonical order is retained separately from playback order so turning
/// shuffle off after a transfer restores the original queue, including repeats.
class MusicTransferSnapshot {
  const MusicTransferSnapshot({required this.queue, required this.position, required this.playing, this.playContext});

  static const maxItems = 128;
  static const maxTransferItems = 4096;
  final MusicQueueState queue;
  final Duration position;
  final bool playing;
  final MusicPlayContext? playContext;

  MusicTransferSnapshot at(Duration position, {required bool playing}) =>
      MusicTransferSnapshot(queue: queue, position: position, playing: playing, playContext: playContext);

  Map<String, dynamic> toJson({int itemLimit = maxItems}) {
    if (!_validQueue(queue, itemLimit) ||
        position < Duration.zero ||
        position > const Duration(hours: 24) ||
        (playContext != null && !_bounded(playContext!.title, 160))) {
      throw StateError('Music queue cannot be transferred');
    }
    return {
      'version': 1,
      'items': [
        for (final item in queue.items)
          {
            'id': item.id,
            'server': item.serverId,
            'backend': item.backend.id,
            'title': ?item.title,
            'album': ?item.parentTitle,
            'library': ?item.libraryId,
            'duration': ?item.durationMs,
          },
      ],
      'order': queue.order,
      'cursor': queue.cursor,
      'shuffled': queue.shuffled,
      'repeat': queue.repeatMode.name,
      'position': position.inMilliseconds,
      'playing': playing,
      if (playContext case final context?) 'context': {'title': context.title, 'kind': context.kind.name},
    };
  }

  /// Reject malformed and oversized peer data as a whole. Never accept a
  /// stream URL, path, auth header, arbitrary raw backend object or video ID.
  static MusicTransferSnapshot? tryParse(Object? value, {int itemLimit = maxItems}) {
    if (value is! Map ||
        value['version'] != 1 ||
        value.keys.any(
          (key) => !{
            'version',
            'items',
            'order',
            'cursor',
            'shuffled',
            'repeat',
            'position',
            'playing',
            'context',
          }.contains(key),
        )) {
      return null;
    }
    final rawItems = value['items'];
    final rawOrder = value['order'];
    final cursor = value['cursor'];
    final shuffled = value['shuffled'];
    final repeat = value['repeat'];
    final position = value['position'];
    final playing = value['playing'];
    if (rawItems is! List ||
        rawItems.isEmpty ||
        rawItems.length > itemLimit ||
        rawOrder is! List ||
        rawOrder.length != rawItems.length ||
        cursor is! int ||
        shuffled is! bool ||
        repeat is! String ||
        position is! int ||
        position < 0 ||
        position > const Duration(hours: 24).inMilliseconds ||
        playing is! bool) {
      return null;
    }
    final mode = MusicRepeatMode.values.where((mode) => mode.name == repeat).firstOrNull;
    if (mode == null) return null;
    final items = <MediaItem>[];
    for (final raw in rawItems) {
      if (raw is! Map ||
          raw.keys.any((key) => !{'id', 'server', 'backend', 'title', 'album', 'library', 'duration'}.contains(key))) {
        return null;
      }
      final id = raw['id'], server = raw['server'], backend = raw['backend'];
      final title = raw['title'], album = raw['album'], library = raw['library'], duration = raw['duration'];
      if (!_bounded(id, 160) ||
          !_bounded(server, 160) ||
          backend is! String ||
          !{'plex', 'jellyfin', 'emby'}.contains(backend) ||
          title != null && !_bounded(title, 256) ||
          album != null && !_bounded(album, 256) ||
          library != null && !_bounded(library, 160) ||
          duration != null &&
              (duration is! int || duration < 0 || duration > const Duration(hours: 24).inMilliseconds)) {
        return null;
      }
      items.add(
        MediaItem(
          id: id as String,
          serverId: server as String,
          backend: MediaBackend.fromId(backend),
          kind: MediaKind.track,
          title: title as String?,
          parentTitle: album as String?,
          libraryId: library as String?,
          durationMs: duration as int?,
        ),
      );
    }
    if (rawOrder.any((index) => index is! int)) return null;
    final context = value['context'];
    MusicPlayContext? playContext;
    if (context != null) {
      if (context is! Map ||
          context.keys.any((key) => !{'title', 'kind'}.contains(key)) ||
          !_bounded(context['title'], 160) ||
          context['kind'] is! String) {
        return null;
      }
      final kind = MusicPlayContextKind.values.where((kind) => kind.name == context['kind']).firstOrNull;
      if (kind == null) return null;
      playContext = MusicPlayContext(title: context['title'] as String, kind: kind);
    }
    final queue = MusicQueueState(
      items: items,
      order: rawOrder.cast<int>().toList(),
      cursor: cursor,
      shuffled: shuffled,
      repeatMode: mode,
    );
    if (!_validQueue(queue, itemLimit)) return null;
    return MusicTransferSnapshot(
      queue: queue,
      position: Duration(milliseconds: position),
      playing: playing,
      playContext: playContext,
    );
  }

  static bool _bounded(Object? value, int limit) => value is String && value.isNotEmpty && value.length <= limit;

  static bool _validQueue(MusicQueueState queue, int itemLimit) =>
      queue.items.isNotEmpty &&
      queue.items.length <= itemLimit &&
      queue.items.every(
        (item) =>
            item.kind == MediaKind.track &&
            _bounded(item.id, 160) &&
            _bounded(item.serverId, 160) &&
            (item.title == null || _bounded(item.title, 256)) &&
            (item.parentTitle == null || _bounded(item.parentTitle, 256)) &&
            (item.libraryId == null || _bounded(item.libraryId, 160)) &&
            (item.durationMs == null ||
                item.durationMs! >= 0 && item.durationMs! <= const Duration(hours: 24).inMilliseconds),
      ) &&
      queue.isValid;
}
