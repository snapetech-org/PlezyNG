import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../media/media_item.dart';

/// Canonical queue occurrences. Large production queues retain compact entry
/// handles and a bounded decoded window, rather than every metadata object.
/// The scratch spool is process-local; durable recovery remains in SQLite.
class MusicQueueItems extends ListBase<MediaItem> {
  MusicQueueItems({this.spill = false, this.scratchRoot, this.threshold = 512}) {
    if (threshold < 1) throw ArgumentError.value(threshold, 'threshold');
  }
  final bool spill;
  final Directory? scratchRoot;
  final int threshold;
  List<_Entry> _entries = [];
  _Spool? _spool;

  @override
  int get length => _entries.length;
  @override
  set length(int value) {
    if (value < 0 || value > length) throw UnsupportedError('Queue entries must be explicitly supplied');
    removeRange(value, length);
  }

  @override
  MediaItem operator [](int index) => _entries[index].read();
  @override
  void operator []=(int index, MediaItem value) {
    RangeError.checkValidIndex(index, _entries);
    _entries[index] = _entry(value);
  }

  _Entry _entry(MediaItem item) => _spool?.append(item) ?? _Entry.memory(item);

  @override
  void add(MediaItem element) => addAll([element]);
  @override
  void addAll(Iterable<MediaItem> iterable) {
    // Keep admission bounded too: a decoded page or disk-backed snapshot
    // must never be materialized into a full temporary metadata list.
    var staged = _spool;
    List<_Entry>? prior;
    var incoming = <_Entry>[];
    var created = false;
    try {
      for (final item in iterable) {
        if (staged == null && spill && length + incoming.length + 1 > threshold) {
          staged = _Spool.create(scratchRoot);
          created = true;
          prior = [for (final entry in _entries) staged.append(entry.read(), key: entry.key)];
          incoming = [for (final entry in incoming) staged.append(entry.read(), key: entry.key)];
        }
        incoming.add(staged?.append(item) ?? _Entry.memory(item));
      }
      if (created) {
        _entries = [...prior!, ...incoming];
        _spool = staged;
      } else {
        _entries.addAll(incoming);
      }
    } catch (_) {
      if (created) staged?.release();
      rethrow;
    }
  }

  void replaceWith(Iterable<MediaItem> items) {
    if (items is MusicQueueItemsSnapshot && (items._spool != null || !spill || items.length <= threshold)) {
      // Hand a locally staged/persisted window to the player without another
      // full encoding pass. The immutable source retains its independent lease.
      final entries = List<_Entry>.of(items._entries);
      final spool = items._spool;
      spool?.retain();
      clear();
      _entries = entries;
      _spool = spool;
      return;
    }
    final staged = MusicQueueItems(spill: spill, scratchRoot: scratchRoot, threshold: threshold);
    try {
      staged.addAll(items);
    } catch (_) {
      staged.clear();
      rethrow;
    }
    clear();
    _entries = staged._entries;
    _spool = staged._spool;
    staged._entries = [];
    staged._spool = null;
  }

  /// Compact existing occurrences without decoding or re-encoding metadata.
  void retainCanonical(Set<int> indices) {
    _entries = [
      for (var index = 0; index < length; index++)
        if (indices.contains(index)) _entries[index],
    ];
  }

  @override
  MediaItem removeAt(int index) {
    final value = this[index];
    _entries.removeAt(index);
    return value;
  }

  @override
  void removeRange(int start, int end) {
    RangeError.checkValidRange(start, end, length);
    _entries.removeRange(start, end);
  }

  @override
  void clear() {
    _entries = [];
    final spool = _spool;
    _spool = null;
    spool?.release();
  }

  void trimDecodedMetadata() {
    _spool?.trim();
    for (final entry in _entries) {
      if (entry._spool != null) entry._weak = null;
    }
  }

  MusicQueueItemsSnapshot snapshot() => MusicQueueItemsSnapshot._(List.unmodifiable(_entries), _spool);

  @visibleForTesting
  bool get isSpilled => _spool != null;
  @visibleForTesting
  int get cachedItems => _spool?._decoded.length ?? length;
}

/// A stable lease on canonical occurrences, including across queue replacement
/// and asynchronous persistence. The final lease deletes the scratch spool.
class MusicQueueItemsSnapshot extends ListBase<MediaItem> {
  MusicQueueItemsSnapshot._(this._entries, this._spool) {
    final spool = _spool;
    if (spool != null) {
      spool.retain();
      _leases.attach(this, spool);
    }
  }
  static final _leases = Finalizer<_Spool>((spool) => spool.release());
  final List<_Entry> _entries;
  final _Spool? _spool;

  Object occurrenceAt(int index) => _entries[index].key;

  @override
  int get length => _entries.length;
  @override
  MediaItem operator [](int index) => _entries[index].read();
  @override
  set length(int value) => throw UnsupportedError('Immutable music queue snapshot');
  @override
  void operator []=(int index, MediaItem value) => throw UnsupportedError('Immutable music queue snapshot');
}

class _Entry {
  _Entry.memory(MediaItem item) : _memory = item, key = Object(), _spool = null, _offset = 0, _size = 0;
  _Entry.disk(this._spool, this._offset, this._size, MediaItem item, {Object? key})
    : key = key ?? Object(),
      _weak = WeakReference(item);
  final Object key;
  MediaItem? _memory;
  WeakReference<MediaItem>? _weak;
  final _Spool? _spool;
  final int _offset, _size;
  MediaItem read() {
    final item = _memory ?? _weak?.target;
    if (item != null) return item;
    final decoded = _spool!.read(_offset, _size);
    _weak = WeakReference(decoded);
    return decoded;
  }
}

class _Spool {
  _Spool._(this.directory, this.file);
  static _Spool create(Directory? root) {
    final directory = (root ?? Directory.systemTemp).createTempSync('pleazyng-music-queue-');
    try {
      return _Spool._(directory, File('${directory.path}/metadata').openSync(mode: FileMode.write));
    } catch (_) {
      directory.deleteSync(recursive: true);
      rethrow;
    }
  }

  final Directory directory;
  final RandomAccessFile file;
  final _decoded = <int, MediaItem>{};
  final _sizes = <int, int>{};
  int _references = 1, _end = 0, _decodedBytes = 0;
  bool _closed = false;
  static const _maxItems = 96, _maxBytes = 8 * 1024 * 1024, _maxRecord = 8 * 1024 * 1024;

  void retain() {
    if (_closed) throw StateError('Music queue spool closed');
    _references++;
  }

  _Entry append(MediaItem item, {Object? key}) {
    if (_closed) throw StateError('Music queue spool closed');
    final bytes = utf8.encode(jsonEncode(item.toJson()));
    if (bytes.length > _maxRecord) throw const FormatException('Music queue metadata record too large');
    final offset = _end;
    file.setPositionSync(offset);
    file.writeFromSync(bytes);
    _end += bytes.length;
    return _Entry.disk(this, offset, bytes.length, item, key: key);
  }

  MediaItem read(int offset, int size) {
    if (_closed) throw StateError('Music queue spool closed');
    final cached = _decoded.remove(offset);
    if (cached != null) {
      _decoded[offset] = cached;
      return cached;
    }
    file.setPositionSync(offset);
    final bytes = file.readSync(size);
    if (bytes.length != size) throw const FormatException('Truncated music queue spool');
    final value = MediaItem.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    _decoded[offset] = value;
    _sizes[offset] = size;
    _decodedBytes += size;
    while (_decoded.length > _maxItems || _decodedBytes > _maxBytes) {
      final first = _decoded.keys.first;
      _decoded.remove(first);
      _decodedBytes -= _sizes.remove(first)!;
    }
    return value;
  }

  void trim() {
    _decoded.clear();
    _sizes.clear();
    _decodedBytes = 0;
  }

  void release() {
    if (_closed || --_references > 0) return;
    _closed = true;
    _decoded.clear();
    _sizes.clear();
    try {
      file.closeSync();
    } catch (_) {
      // Scratch cleanup cannot replace a playback result.
    }
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {
      // OS temporary-storage cleanup also owns abandoned process scratch.
    }
  }
}
