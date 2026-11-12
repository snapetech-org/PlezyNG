import 'dart:math';
import 'dart:collection';
import 'dart:io';

import '../../media/media_item.dart';
import 'music_playback_service.dart';
import 'music_queue_items.dart';
import 'music_queue_order.dart';

/// Immutable copy of the queue's full state, for session persistence (#2148).
/// [order] indexes into [items] (canonical order); [cursor] indexes [order].
class MusicQueueState {
  final List<MediaItem> items;
  final List<int> order;
  final int cursor;
  final bool shuffled;
  final MusicRepeatMode repeatMode;

  const MusicQueueState({
    required this.items,
    required this.order,
    required this.cursor,
    required this.shuffled,
    required this.repeatMode,
  });

  /// Validate the shape without decoding/copying the metadata payload.
  bool get isValid {
    final length = items.length;
    if (length == 0 || order.length != length || cursor < 0 || cursor >= length) return false;
    final savedOrder = order;
    if (savedOrder is MusicQueueOrderSnapshot && savedOrder.isValidatedPermutation) return true;
    final seen = List<bool>.filled(length, false);
    for (final index in order) {
      if (index < 0 || index >= length || seen[index]) return false;
      seen[index] = true;
    }
    return true;
  }
}

/// Queue state for the music session, independent of the audio player.
/// Small/test queues stay in memory; production can spool large metadata.
///
/// Holds the canonical track list ([_items], insertion order) plus a playback
/// order ([_order], indexes into the canonical list; the identity permutation
/// while unshuffled) and the [cursor] into that playback order. Every index a
/// caller passes in ([jumpTo], [removeAt], [move]) is a *playback-order*
/// index — the same flat list the queue UI renders via [queue].
///
/// The controller only mutates state; deciding what to do about it (open a
/// new track, re-arm gapless, stop) is the service's job.
class MusicQueueController {
  MusicQueueController({Random? random, bool spillLargeQueues = false, Directory? queueScratchDirectory})
    : _random = random ?? Random(),
      _items = MusicQueueItems(spill: spillLargeQueues, scratchRoot: queueScratchDirectory),
      _order = MusicQueueOrder(spill: spillLargeQueues, scratchRoot: queueScratchDirectory);

  final Random _random;

  /// Canonical tracks in the order they were loaded/enqueued. Restored as
  /// the playback order when shuffle turns off.
  final MusicQueueItems _items;

  /// Playback order: indexes into [_items]. Identity when unshuffled.
  final MusicQueueOrder _order;
  List<MediaItem>? _queueSnapshot;

  int _cursor = -1;
  bool _shuffled = false;

  MusicRepeatMode repeatMode = MusicRepeatMode.off;

  bool get isEmpty => _items.isEmpty;
  int get length => _order.length;
  bool get shuffled => _shuffled;

  /// Position of the current track within the playback order; -1 when empty.
  int get cursor => _cursor;

  MediaItem? get current => trackAt(_cursor);

  /// Full queue in playback order (what the UI renders).
  List<MediaItem> get queue =>
      _queueSnapshot ??= MusicQueueView._(_items.snapshot(), _order.snapshot(validatedPermutation: true));

  MediaItem? trackAt(int queueIndex) =>
      queueIndex >= 0 && queueIndex < _order.length ? _items[_order[queueIndex]] : null;

  bool isOrderedAlbum({required bool albumLaunch}) {
    if (_shuffled || isEmpty) return false;
    if (length == 1) return albumLaunch;
    final first = trackAt(0)!;
    if (!albumLaunch && (first.parentId?.isNotEmpty != true || first.serverId?.isNotEmpty != true)) return false;
    var previous = first;
    for (var index = 1; index < length; index++) {
      final next = trackAt(index)!;
      if (first.backend != next.backend ||
          first.serverId != next.serverId ||
          first.libraryId != next.libraryId ||
          first.parentId != next.parentId ||
          previous.globalKey == next.globalKey) {
        return false;
      }
      final previousDisc = previous.parentIndex ?? 1;
      final disc = next.parentIndex ?? 1;
      final previousTrack = previous.index;
      final track = next.index;
      if (disc <= 0 || previousDisc <= 0 || disc < previousDisc || disc > previousDisc + 1) return false;
      if (track == null || track <= 0 || previousTrack == null || previousTrack <= 0) {
        if (!albumLaunch) return false;
      } else if (disc == previousDisc ? track != previousTrack + 1 : track != 1) {
        return false;
      }
      previous = next;
    }
    return true;
  }

  /// Full state copy for persistence — includes the canonical order and the
  /// shuffle permutation the public [queue] getter flattens away, so a
  /// restored session can still un-shuffle back to the original order.
  MusicQueueState captureState() => MusicQueueState(
    items: _items.snapshot(),
    order: _order.snapshot(validatedPermutation: true),
    cursor: _cursor,
    shuffled: _shuffled,
    repeatMode: repeatMode,
  );

  /// Restore a captured state. Returns false and leaves the queue untouched
  /// when the state violates queue invariants (order not a permutation of the
  /// items, cursor out of range) — a corrupt snapshot must not produce a
  /// half-valid session.
  bool restoreState(MusicQueueState state) {
    if (!state.isValid) return false;
    _queueSnapshot = null;
    _items.replaceWith(state.items);
    _order.replaceWith(state.order);
    _cursor = state.cursor;
    _shuffled = state.shuffled;
    repeatMode = state.repeatMode;
    return true;
  }

  /// Replace the queue with [tracks], starting at [startIndex]. A null
  /// [startIndex] (the default) means *no explicit start* — playback simply
  /// begins at the head.
  ///
  /// [shuffle] reads that distinction. With an explicit [startIndex] the
  /// start track is anchored first and the rest shuffle after it (it keeps
  /// playing / plays first); with none the whole list shuffles, head
  /// included. Collapsing "no start track" into index 0 is what pinned every
  /// shuffled playlist to its first track (#1811).
  void load(List<MediaItem> tracks, {int? startIndex, bool shuffle = false}) {
    _queueSnapshot = null;
    _items.replaceWith(tracks);
    _order.resetIdentity(tracks.length);
    _shuffled = false;
    _cursor = tracks.isEmpty ? -1 : (startIndex ?? 0).clamp(0, tracks.length - 1);
    if (!shuffle || tracks.isEmpty) return;
    if (startIndex == null) {
      _shuffleAll();
    } else {
      _shuffleAnchoringCurrent();
    }
  }

  MusicQueueItemsSnapshot prepareItems(Iterable<MediaItem> items) => _items.prepareSnapshot(items);

  void trimDecodedMetadata() => _items.trimDecodedMetadata();

  void clear() {
    _queueSnapshot = null;
    _items.clear();
    _order.clear();
    _cursor = -1;
    _shuffled = false;
  }

  /// Playback-order position that plays after the current one, or null when
  /// playback should end there. Natural advancement (`manual: false`)
  /// honors repeat-one by returning the cursor itself; a user-initiated
  /// next (`manual: true`) always steps to the following entry.
  int? nextIndex({bool manual = false}) {
    if (_order.isEmpty || _cursor < 0) return null;
    if (repeatMode == MusicRepeatMode.one && !manual) return _cursor;
    final next = _cursor + 1;
    if (next < _order.length) return next;
    return repeatMode == MusicRepeatMode.all ? 0 : null;
  }

  /// Playback-order position before the current one, or null when there is
  /// none (the service restarts the current track in that case).
  int? previousIndex() {
    if (_order.isEmpty || _cursor < 0) return null;
    final prev = _cursor - 1;
    if (prev >= 0) return prev;
    return repeatMode == MusicRepeatMode.all ? _order.length - 1 : null;
  }

  void jumpTo(int queueIndex) {
    if (queueIndex < 0 || queueIndex >= _order.length) return;
    _cursor = queueIndex;
  }

  /// Insert [tracks] directly after the current entry.
  void addNext(List<MediaItem> tracks) {
    if (tracks.isEmpty) return;
    _queueSnapshot = null;
    final first = _items.length;
    _items.addAll(tracks);
    _order.insertRange(_cursor < 0 ? 0 : _cursor + 1, first, tracks.length);
    if (_cursor < 0) _cursor = 0;
  }

  void addToEnd(List<MediaItem> tracks) {
    if (tracks.isEmpty) return;
    _queueSnapshot = null;
    final first = _items.length;
    _items.addAll(tracks);
    _order.appendRange(first, tracks.length);
    if (_cursor < 0) _cursor = 0;
  }

  /// Remove the queue entry at playback-order [queueIndex]. Returns true
  /// when the removed entry was the current track — the cursor then points
  /// at what used to be the next entry (or the new last entry when the
  /// current one was last; -1 when the queue emptied), and the caller
  /// decides whether to open it.
  bool removeAt(int queueIndex) {
    if (queueIndex < 0 || queueIndex >= _order.length) return false;
    _queueSnapshot = null;
    final wasCurrent = queueIndex == _cursor;
    final itemIndex = _order.removeAt(queueIndex);
    _items.removeAt(itemIndex);
    _order.decrementAbove(itemIndex);
    if (queueIndex < _cursor) {
      _cursor--;
    } else if (_cursor >= _order.length) {
      _cursor = _order.length - 1;
    }
    return wasCurrent;
  }

  /// Reorder the playback queue: move the entry at [from] to [to] (both
  /// playback-order indexes). The cursor keeps tracking the current track.
  void move(int from, int to) {
    if (from < 0 || from >= _order.length || to < 0 || to >= _order.length || from == to) {
      return;
    }
    _queueSnapshot = null;
    final entry = _order.removeAt(from);
    _order.insert(to, entry);
    if (from == _cursor) {
      _cursor = to;
    } else if (from < _cursor && to >= _cursor) {
      _cursor--;
    } else if (from > _cursor && to <= _cursor) {
      _cursor++;
    }
  }

  /// Toggle shuffle. Turning it on anchors the current track first and
  /// shuffles the rest after it; turning it off restores canonical order
  /// with the cursor following the current track.
  void toggleShuffle() {
    if (_items.isEmpty) return;
    _queueSnapshot = null;
    if (_shuffled) {
      final currentItem = _order[_cursor];
      _order.resetIdentity(_items.length);
      _cursor = currentItem;
      _shuffled = false;
    } else {
      _shuffleAnchoringCurrent();
    }
  }

  /// Shuffle complete album blocks, preserving disc/track sequence within each
  /// block and keeping the playing album at the head. Duplicate occurrences
  /// remain separate entries inside their block.
  void shuffleAlbums() {
    if (_items.isEmpty) return;
    _queueSnapshot = null;
    final currentItem = _order[_cursor];
    final blocks = <String, List<int>>{};
    String key(int i) => _items[i].parentId == null ? 'entry:$i' : '${_items[i].serverId}:${_items[i].parentId}';
    for (var i = 0; i < _items.length; i++) {
      (blocks[key(i)] ??= []).add(i);
    }
    for (final block in blocks.values) {
      block.sort((a, b) {
        final disc = (_items[a].parentIndex ?? 0).compareTo(_items[b].parentIndex ?? 0);
        if (disc != 0) return disc;
        final track = (_items[a].index ?? a).compareTo(_items[b].index ?? b);
        return track == 0 ? a.compareTo(b) : track;
      });
    }
    final anchor = blocks.remove(key(currentItem))!;
    final rest = blocks.values.toList()..shuffle(_random);
    Iterable<int> ordered() sync* {
      yield* anchor;
      for (final block in rest) {
        yield* block;
      }
    }

    _order.replaceWith(ordered());
    _cursor = _order.indexOf(currentItem);
    _shuffled = true;
  }

  int? nextAlbumIndex() {
    final active = current;
    if (active == null) return null;
    for (var i = _cursor + 1; i < _order.length; i++) {
      final candidate = trackAt(i)!;
      if (active.parentId == null || candidate.parentId != active.parentId || candidate.serverId != active.serverId) {
        return i;
      }
    }
    return null;
  }

  void _shuffleAnchoringCurrent() {
    final anchorPosition = _cursor < 0 ? 0 : _cursor;
    _order.swap(0, anchorPosition);
    _order.shuffleFrom(1, _random);
    _cursor = 0;
    _shuffled = true;
  }

  /// Shuffle every entry, head included — a session started *as* shuffled
  /// has no track that must play first.
  void _shuffleAll() {
    _order.shuffle(_random);
    _cursor = 0;
    _shuffled = true;
  }

  /// Drop everything after the current entry (playback order), including
  /// the underlying canonical items.
  void clearUpcoming() {
    if (_cursor < 0 || _cursor >= _order.length - 1) return;
    _queueSnapshot = null;
    _order.removeRange(_cursor + 1, _order.length);
    _items.retainInPlaybackOrder(_order);
  }
}

/// Immutable playback-order view. Occurrence keys never depend on decoded
/// object identity, so metadata eviction cannot duplicate or resurrect a row.
class MusicQueueView extends ListBase<MediaItem> {
  MusicQueueView._(this._items, this._order);
  final MusicQueueItemsSnapshot _items;
  final MusicQueueOrderSnapshot _order;
  Object occurrenceAt(int index) => _items.occurrenceAt(_order[index]);
  @override
  int get length => _order.length;
  @override
  MediaItem operator [](int index) => _items[_order[index]];
  @override
  set length(int value) => throw UnsupportedError('Immutable music queue');
  @override
  void operator []=(int index, MediaItem value) => throw UnsupportedError('Immutable music queue');
}
