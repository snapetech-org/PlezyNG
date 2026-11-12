import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/library_query.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import 'music_discovery.dart';
import 'music_playback_service.dart';

enum MusicDjMode { off, stretch, gemini, freeze, twofer, groupie, contempo, friendganger }

class MusicDjSource {
  const MusicDjSource({required this.client, required this.libraryId, required this.isCurrent});

  final MediaServerClient client;
  final String libraryId;
  final bool Function() isCurrent;
}

/// Queue augmentation belongs to the existing session. The original upcoming
/// entries stay in order; only explicitly labelled generated entries are
/// removed when a DJ is disabled. Manual edits invalidate pending requests.
class MusicGuestDj extends ChangeNotifier {
  MusicGuestDj(this.music, this.clientFor, {this.sharedSources}) {
    music.addListener(_changed);
  }
  final MusicPlaybackService music;
  final MediaServerClient? Function(MediaItem) clientFor;
  final Future<List<MusicDjSource>> Function()? sharedSources;
  MusicDjMode _mode = MusicDjMode.off;
  MediaItem? _anchor;
  int _epoch = 0, _handledOccurrence = -1, _session = -1;
  bool _busy = false, _disposed = false, _mutating = false;
  String? _failure;
  MusicDjMode get mode => _mode;
  bool get busy => _busy;
  String? get failure => _failure;
  static bool isGenerated(MediaItem item) => item.raw?['pleazyngGuestDj'] is String;

  Future<void> select(MusicDjMode mode) async {
    _epoch++;
    _mode = mode;
    _anchor = music.currentTrack;
    _session = music.queueSessionRevision;
    _handledOccurrence = -1;
    _busy = false;
    _failure = null;
    _mutating = true;
    try {
      final queue = music.queue;
      for (var i = queue.length - 1; i > music.currentIndex; i--) {
        if (isGenerated(queue[i])) music.removeAt(i);
      }
    } finally {
      _mutating = false;
    }
    notifyListeners();
    await _extend();
  }

  void _changed() {
    if (_disposed || _mutating || _mode == MusicDjMode.off) return;
    if (_session != music.queueSessionRevision || music.currentTrack == null) {
      _epoch++;
      _mode = MusicDjMode.off;
      _busy = false;
      notifyListeners();
      return;
    }
    unawaited(_extend());
  }

  Future<void> _extend() async {
    final track = music.currentTrack;
    final occurrence = music.playbackOccurrenceRevision;
    if (_disposed || _mode == MusicDjMode.off || _busy || track == null || _handledOccurrence == occurrence) return;
    if (isGenerated(track) && _mode != MusicDjMode.freeze) return;
    final seed = _mode == MusicDjMode.freeze ? _anchor ?? track : track;
    final client = clientFor(seed);
    if (client == null || client.isOfflineMode) return;
    final authentication = client.authenticationSessionId;
    final epoch = _epoch, session = music.queueSessionRevision;
    final before = music.queue, index = music.currentIndex;
    final next = index + 1 < before.length ? before[index + 1] : null;
    _handledOccurrence = occurrence;
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final candidates = await _candidates(client, seed, next, exclude: before.map((item) => item.globalKey).toSet());
      if (_disposed ||
          epoch != _epoch ||
          session != music.queueSessionRevision ||
          occurrence != music.playbackOccurrenceRevision ||
          !listEquals(before, music.queue) ||
          !identical(clientFor(seed), client) ||
          !identical(authentication, client.authenticationSessionId)) {
        return;
      }
      final count = switch (_mode) {
        MusicDjMode.twofer || MusicDjMode.gemini => 1,
        MusicDjMode.groupie || MusicDjMode.contempo => 5,
        MusicDjMode.freeze => 10,
        _ => 20,
      };
      final selected = MusicDiscovery.interleave(
        [
          candidates
              .where(
                (item) =>
                    _mode == MusicDjMode.friendganger ||
                    item.serverId == seed.serverId &&
                        (seed.libraryId == null || item.libraryId == null || item.libraryId == seed.libraryId),
              )
              .toList(),
        ],
        limit: count,
        exclude: before.map((item) => item.globalKey).toSet(),
      );
      if (selected.isEmpty) _failure = 'empty';
      _mutating = true;
      try {
        music.addNext(
          selected.map((item) => item.copyWith(raw: {...?item.raw, 'pleazyngGuestDj': _mode.name})).toList(),
        );
      } finally {
        _mutating = false;
      }
    } on UnsupportedError {
      if (!_disposed && epoch == _epoch) _failure = 'unsupported';
    } catch (_) {
      if (!_disposed && epoch == _epoch) _failure = 'error';
    } finally {
      if (!_disposed && epoch == _epoch) {
        _busy = false;
        notifyListeners();
        // A track can finish while its request is in flight. Process the new
        // occurrence instead of leaving that transition permanently unhandled.
        if (occurrence != music.playbackOccurrenceRevision) unawaited(_extend());
      }
    }
  }

  Future<List<MediaItem>> _candidates(
    MediaServerClient client,
    MediaItem seed,
    MediaItem? next, {
    required Set<String> exclude,
  }) async {
    switch (_mode) {
      case MusicDjMode.friendganger:
        final epoch = _epoch;
        final sources = await sharedSources?.call() ?? <MusicDjSource>[];
        final batches = <({MusicDjSource source, Object authentication, List<MediaItem> tracks})>[];
        final seen = <String>{};
        for (final source in sources.take(8)) {
          if (_disposed || epoch != _epoch) return [];
          final remote = source.client;
          if (remote.isOfflineMode || !source.isCurrent() || !seen.add('${remote.serverId}:${source.libraryId}')) {
            continue;
          }
          final authentication = remote.authenticationSessionId;
          try {
            final page = await remote
                .fetchLibraryPagedContent(
                  source.libraryId,
                  query: const LibraryQuery(
                    kind: MediaKind.track,
                    limit: 50,
                    sort: LibrarySort(field: 'random'),
                  ),
                )
                .timeout(const Duration(seconds: 15));
            batches.add((source: source, authentication: authentication, tracks: page.items));
          } catch (_) {
            continue;
          }
        }
        return MusicDiscovery.interleave([
          for (final batch in batches)
            if (batch.source.isCurrent() &&
                !batch.source.client.isOfflineMode &&
                identical(batch.authentication, batch.source.client.authenticationSessionId))
              batch.tracks
                  .where(
                    (item) =>
                        item.kind == MediaKind.track &&
                        item.serverId == batch.source.client.serverId &&
                        item.libraryId == batch.source.libraryId,
                  )
                  .toList(),
        ], limit: 20);
      case MusicDjMode.off:
        return [];
      case MusicDjMode.gemini:
      case MusicDjMode.freeze:
        if (client is! SonicMusicClient) throw UnsupportedError('Sonic analysis required');
        return (client as SonicMusicClient).sonicallySimilar(seed.id, limit: 100);
      case MusicDjMode.stretch:
        if (client is! SonicMusicClient ||
            next == null ||
            seed.libraryId == null ||
            seed.serverId != next.serverId ||
            seed.libraryId != next.libraryId) {
          throw UnsupportedError('Two analyzed tracks in the same library required');
        }
        return (client as SonicMusicClient).sonicPath(libraryId: seed.libraryId!, startId: seed.id, endId: next.id);
      case MusicDjMode.twofer:
      case MusicDjMode.groupie:
        if (seed.grandparentId == null) throw UnsupportedError('Artist identity unavailable');
        final epoch = _epoch;
        const pageSize = 100, maxPages = 20;
        final needed = _mode == MusicDjMode.twofer ? 1 : 5;
        final results = <MediaItem>[];
        final seen = {...exclude};
        var offset = 0;
        int? totalCount;
        Future<void> loadPages() async {
          for (var pageIndex = 0; pageIndex < maxPages; pageIndex++) {
            if (_disposed || epoch != _epoch) return;
            final page = await client.fetchMusicTracksPage(
              seed.grandparentId!,
              kind: MediaKind.artist,
              libraryId: seed.libraryId,
              start: offset,
              size: pageSize,
            );
            if (_disposed || epoch != _epoch) return;
            if (page.offset != offset ||
                page.items.length > pageSize ||
                page.totalCount < offset + page.items.length ||
                totalCount != null && page.totalCount != totalCount ||
                page.items.isEmpty && page.totalCount > offset) {
              throw const FormatException('Invalid Guest DJ artist page');
            }
            final pageTotal = totalCount = page.totalCount;
            for (final item in page.items) {
              if (item.kind == MediaKind.track &&
                  item.serverId == seed.serverId &&
                  (seed.libraryId == null || item.libraryId == null || item.libraryId == seed.libraryId) &&
                  seen.add(item.globalKey)) {
                results.add(item);
                if (results.length == needed) break;
              }
            }
            offset += page.items.length;
            if (results.length >= needed || offset >= pageTotal || page.items.isEmpty) return;
          }
        }

        await loadPages().timeout(const Duration(seconds: 15));
        return results;
      case MusicDjMode.contempo:
        if (seed.libraryId == null || seed.year == null) throw UnsupportedError('Track era unavailable');
        final page = await client.fetchLibraryPagedContent(
          seed.libraryId!,
          query: LibraryQuery(
            kind: MediaKind.track,
            limit: 100,
            sort: const LibrarySort(field: 'random'),
            filters: [
              LibraryFilter(field: 'year', op: LibraryFilterOperator.atLeast, values: ['${seed.year! - 5}']),
              LibraryFilter(field: 'year', op: LibraryFilterOperator.atMost, values: ['${seed.year! + 5}']),
            ],
          ),
        );
        // Some providers ignore unsupported filters. Verify the promised era.
        return page.items.where((item) => item.year != null && (item.year! - seed.year!).abs() <= 5).toList();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    music.removeListener(_changed);
    super.dispose();
  }
}
