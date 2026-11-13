import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import 'music_queue_order.dart';

int _nextOccurrenceId = 0;

/// Canonical queue occurrences. Large production queues keep metadata and a
/// fixed-width occurrence index in process-local scratch files. The decoded
/// metadata window is bounded; durable recovery remains in SQLite.
class MusicQueueItems extends ListBase<MediaItem> {
  MusicQueueItems({this.spill = false, this.scratchRoot, this.threshold = 512}) {
    if (threshold < 1) throw ArgumentError.value(threshold, 'threshold');
  }

  final bool spill;
  final Directory? scratchRoot;
  final int threshold;
  List<_Entry> _entries = [];
  int _length = 0;
  int _liveEncodedBytes = 0;
  _Spool? _spool;
  _EntryIndex? _index;

  @override
  int get length => _length;

  @override
  set length(int value) {
    if (value < 0 || value > length) {
      throw UnsupportedError('Queue entries must be explicitly supplied');
    }
    removeRange(value, length);
  }

  @override
  MediaItem operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final indexFile = _index;
    if (indexFile == null) return _entries[index].read();
    final record = indexFile.read(index);
    return _spool!.read(record.offset, record.size);
  }

  @override
  void operator []=(int index, MediaItem value) {
    RangeError.checkValidIndex(index, this);
    final indexFile = _index;
    if (indexFile == null) {
      _entries[index] = _Entry.memory(value, _newOccurrenceId());
      return;
    }

    final encoded = _spool!.append(value);
    final writable = _writableIndex();
    final previous = writable.read(index);
    writable.write(index, encoded.withOccurrenceId(_newOccurrenceId()));
    _liveEncodedBytes += encoded.size - previous.size;
    _maybeCompactMetadata();
  }

  @override
  void add(MediaItem element) => addAll([element]);

  @override
  void addAll(Iterable<MediaItem> iterable) {
    // A self-append must read a stable window while its destination grows.
    MusicQueueItemsSnapshot? selfSnapshot;
    if (identical(iterable, this)) {
      selfSnapshot = snapshot();
      iterable = selfSnapshot;
    }

    final originalIndex = _index;
    var workingIndex = originalIndex;
    var workingSpool = _spool;
    var clonedIndex = false;
    var promoted = false;
    var createdSpool = false;
    final pendingMemory = <_Entry>[];
    var appended = 0;
    var appendedBytes = 0;
    var promotedLiveBytes = 0;
    final originalIndexLength = originalIndex?.length ?? 0;

    try {
      for (final item in iterable) {
        if (_length + appended >= 0x100000000) {
          throw RangeError('Music queue exceeds its occurrence index format');
        }

        if (workingIndex == null && spill && _length + appended + 1 > threshold) {
          workingSpool = _Spool.create(scratchRoot);
          createdSpool = true;
          workingIndex = _EntryIndex.create(scratchRoot);
          for (final entry in _entries) {
            final encoded = workingSpool.append(entry.read());
            workingIndex.append(encoded.withOccurrenceId(entry.key));
            promotedLiveBytes += encoded.size;
          }
          for (final entry in pendingMemory) {
            final encoded = workingSpool.append(entry.read());
            workingIndex.append(encoded.withOccurrenceId(entry.key));
            promotedLiveBytes += encoded.size;
          }
          pendingMemory.clear();
          promoted = true;
        }

        if (workingIndex == null) {
          pendingMemory.add(_Entry.memory(item, _newOccurrenceId()));
        } else {
          if (originalIndex != null && identical(workingIndex, originalIndex) && !clonedIndex) {
            if (originalIndex.references > 1) {
              workingIndex = originalIndex.copy(scratchRoot);
              clonedIndex = true;
            }
          }
          final encoded = workingSpool!.append(item);
          workingIndex.append(encoded.withOccurrenceId(_newOccurrenceId()));
          if (promoted) {
            promotedLiveBytes += encoded.size;
          } else {
            appendedBytes += encoded.size;
          }
        }
        appended++;
      }

      if (appended == 0) return;
      if (promoted) {
        _entries = [];
        _index = workingIndex;
        _spool = workingSpool;
        _length += appended;
        _liveEncodedBytes = promotedLiveBytes;
      } else if (originalIndex == null) {
        _entries.addAll(pendingMemory);
        _length += appended;
      } else {
        _index = workingIndex;
        _length += appended;
        _liveEncodedBytes += appendedBytes;
        if (clonedIndex) originalIndex.release();
        _maybeCompactMetadata();
      }
    } catch (_) {
      if (createdSpool) {
        workingIndex?.release();
        workingSpool?.release();
      } else if (originalIndex != null) {
        if (clonedIndex) {
          workingIndex?.release();
        } else {
          workingIndex?.truncate(originalIndexLength);
        }
      }
      rethrow;
    } finally {
      // Keep the stable self-snapshot alive through the complete iteration.
      selfSnapshot = null;
    }
  }

  @override
  void insert(int index, MediaItem element) {
    RangeError.checkValueInInterval(index, 0, length, 'index');
    if (index == length) {
      add(element);
      return;
    }
    if (_index == null && spill && length + 1 > threshold) {
      _promoteMemoryEntries();
    }
    final indexFile = _index;
    if (indexFile == null) {
      _entries.insert(index, _Entry.memory(element, _newOccurrenceId()));
      _length++;
      return;
    }

    final encoded = _spool!.append(element);
    _writableIndex().insert(index, encoded.withOccurrenceId(_newOccurrenceId()));
    _length++;
    _liveEncodedBytes += encoded.size;
  }

  void _promoteMemoryEntries() {
    final stagedSpool = _Spool.create(scratchRoot);
    _EntryIndex? stagedIndex;
    var liveBytes = 0;
    try {
      stagedIndex = _EntryIndex.create(scratchRoot);
      for (final entry in _entries) {
        final encoded = stagedSpool.append(entry.read());
        stagedIndex.append(encoded.withOccurrenceId(entry.key));
        liveBytes += encoded.size;
      }
    } catch (_) {
      stagedIndex?.release();
      stagedSpool.release();
      rethrow;
    }
    _entries = [];
    _index = stagedIndex;
    _spool = stagedSpool;
    _liveEncodedBytes = liveBytes;
  }

  MusicQueueItemsSnapshot prepareSnapshot(Iterable<MediaItem> items) {
    final staged = MusicQueueItems(spill: spill, scratchRoot: scratchRoot, threshold: threshold);
    try {
      staged.replaceWith(items);
      return staged.snapshot();
    } finally {
      staged.clear();
    }
  }

  void replaceWith(Iterable<MediaItem> items) {
    if (items is MusicQueueItemsSnapshot) {
      final sourceIndex = items._index;
      if (sourceIndex != null) {
        final sourceSpool = items._spool!;
        sourceIndex.retain();
        sourceSpool.retain();
        clear();
        _entries = [];
        _index = sourceIndex;
        _spool = sourceSpool;
        _length = items.length;
        _liveEncodedBytes = items._liveEncodedBytes;
        return;
      }
      if (!spill || items.length <= threshold) {
        final entries = List<_Entry>.of(items._entries!);
        clear();
        _entries = entries;
        _length = entries.length;
        return;
      }
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
    _length = staged._length;
    _liveEncodedBytes = staged._liveEncodedBytes;
    _index = staged._index;
    _spool = staged._spool;
    staged
      .._entries = []
      .._length = 0
      .._liveEncodedBytes = 0
      .._index = null
      .._spool = null;
  }

  /// Keep the canonical items referenced by [order], compacting both the
  /// queue and playback order without allocating per-item heap objects.
  void retainInPlaybackOrder(MusicQueueOrder order) {
    final retainedLength = order.length;
    if (_index == null) {
      _retainMemoryInPlaybackOrder(order, retainedLength);
      return;
    }
    if (retainedLength == 0) {
      order.resetIdentity(0);
      clear();
      return;
    }

    final originalIndex = _index!;
    final stagedIndex = originalIndex.copy(scratchRoot);
    final stagedOrder = MusicQueueOrder(spill: order.spill, scratchRoot: order.scratchRoot, threshold: order.threshold);
    try {
      stagedOrder.replaceWith(order.snapshot());
      for (var playback = 0; playback < retainedLength; playback++) {
        RangeError.checkValidIndex(stagedOrder[playback], stagedIndex);
        final record = stagedIndex.read(stagedOrder[playback]);
        if (record.retained) throw StateError('Playback order contains a duplicate queue occurrence');
        record.retained = true;
        stagedIndex.write(stagedOrder[playback], record);
      }

      var nextCanonical = 0;
      var retainedBytes = 0;
      for (var canonical = 0; canonical < stagedIndex.length; canonical++) {
        final record = stagedIndex.read(canonical);
        if (!record.retained) continue;
        record.compactedIndex = nextCanonical++;
        retainedBytes += record.size;
        stagedIndex.write(canonical, record);
      }

      for (var playback = 0; playback < retainedLength; playback++) {
        final canonical = stagedOrder[playback];
        final record = stagedIndex.read(canonical);
        if (!record.retained) throw StateError('Playback order contains a duplicate queue occurrence');
        stagedOrder[playback] = record.compactedIndex;
      }

      var write = 0;
      for (var read = 0; read < stagedIndex.length; read++) {
        final record = stagedIndex.read(read);
        if (!record.retained) continue;
        record
          ..retained = false
          ..compactedIndex = 0;
        stagedIndex.write(write, record);
        write++;
      }
      stagedIndex.truncate(write);

      order.replaceWith(stagedOrder.snapshot());
      _index = stagedIndex;
      _length = write;
      _liveEncodedBytes = retainedBytes;
      originalIndex.release();
      _maybeCompactMetadata();
    } catch (_) {
      stagedIndex.release();
      rethrow;
    } finally {
      stagedOrder.clear();
    }
  }

  void _retainMemoryInPlaybackOrder(MusicQueueOrder order, int retainedLength) {
    try {
      for (var playback = 0; playback < retainedLength; playback++) {
        RangeError.checkValidIndex(order[playback], _entries);
        final entry = _entries[order[playback]];
        if (entry.retained) throw StateError('Playback order contains a duplicate queue occurrence');
        entry.retained = true;
      }

      var nextCanonical = 0;
      for (final entry in _entries) {
        if (!entry.retained) continue;
        entry.compactedIndex = nextCanonical++;
      }

      for (var playback = 0; playback < retainedLength; playback++) {
        final entry = _entries[order[playback]];
        order[playback] = entry.compactedIndex!;
      }
      order.removeRange(retainedLength, order.length);

      var write = 0;
      for (var read = 0; read < _entries.length; read++) {
        final entry = _entries[read];
        if (entry.retained) _entries[write++] = entry;
        entry
          ..retained = false
          ..compactedIndex = null;
      }
      _entries.length = write;
      _length = write;
    } catch (_) {
      for (final entry in _entries) {
        entry
          ..retained = false
          ..compactedIndex = null;
      }
      rethrow;
    }
  }

  @override
  MediaItem removeAt(int index) {
    RangeError.checkValidIndex(index, this);
    final value = this[index];
    removeRange(index, index + 1);
    return value;
  }

  @override
  void removeRange(int start, int end) {
    RangeError.checkValidRange(start, end, length);
    if (start == end) return;
    if (_index == null) {
      _entries.removeRange(start, end);
      _length -= end - start;
      return;
    }
    if (start == 0 && end == _length) {
      clear();
      return;
    }

    final indexFile = _writableIndex();
    var removedBytes = 0;
    for (var index = start; index < end; index++) {
      removedBytes += indexFile.read(index).size;
    }
    indexFile.removeRange(start, end);
    _length -= end - start;
    _liveEncodedBytes -= removedBytes;
    _maybeCompactMetadata();
  }

  @override
  void clear() {
    _entries = [];
    _length = 0;
    _liveEncodedBytes = 0;
    final indexFile = _index;
    _index = null;
    indexFile?.release();
    final spool = _spool;
    _spool = null;
    spool?.release();
  }

  void trimDecodedMetadata() => _spool?.trim();

  MusicQueueItemsSnapshot snapshot() {
    final indexFile = _index;
    if (indexFile == null) return MusicQueueItemsSnapshot._memory(List.unmodifiable(_entries));
    return MusicQueueItemsSnapshot._disk(_length, _liveEncodedBytes, indexFile, _spool!);
  }

  _EntryIndex _writableIndex() {
    final indexFile = _index!;
    if (indexFile.references == 1) return indexFile;
    final copy = indexFile.copy(scratchRoot);
    _index = copy;
    indexFile.release();
    return copy;
  }

  void _maybeCompactMetadata() {
    final oldSpool = _spool;
    final oldIndex = _index;
    if (oldSpool == null || oldIndex == null) return;
    final garbage = oldSpool._end - _liveEncodedBytes;
    if (garbage <= max(_Spool._maxOrphanBytes, _liveEncodedBytes)) return;

    final stagedSpool = _Spool.create(scratchRoot);
    _EntryIndex? stagedIndex;
    try {
      stagedIndex = _EntryIndex.create(scratchRoot);
      for (var index = 0; index < oldIndex.length; index++) {
        final record = oldIndex.read(index);
        final item = oldSpool.read(record.offset, record.size);
        final encoded = stagedSpool.append(item);
        stagedIndex.append(encoded.withOccurrenceId(record.occurrenceId));
      }
    } catch (_) {
      stagedIndex?.release();
      stagedSpool.release();
      return;
    }

    _index = stagedIndex;
    _spool = stagedSpool;
    oldIndex.release();
    oldSpool.release();
  }

  @visibleForTesting
  bool get isSpilled => _index != null;

  @visibleForTesting
  int get cachedItems => _spool?._decoded.length ?? length;
}

/// A stable lease on canonical occurrences, including across queue replacement
/// and asynchronous persistence. Disk snapshots retain compact file indexes.
class MusicQueueItemsSnapshot extends ListBase<MediaItem> {
  MusicQueueItemsSnapshot._memory(List<_Entry> entries)
    : _entries = entries,
      _index = null,
      _spool = null,
      _length = entries.length,
      _liveEncodedBytes = 0;

  MusicQueueItemsSnapshot._disk(this._length, this._liveEncodedBytes, this._index, this._spool) : _entries = null {
    _index!.retain();
    _spool!.retain();
    _indexLeases.attach(this, _index!);
    _spoolLeases.attach(this, _spool!);
  }

  static final _indexLeases = Finalizer<_EntryIndex>((index) => index.release());
  static final _spoolLeases = Finalizer<_Spool>((spool) => spool.release());

  final List<_Entry>? _entries;
  final _EntryIndex? _index;
  final _Spool? _spool;
  final int _length;
  final int _liveEncodedBytes;
  bool _released = false;

  /// Release this snapshot's scratch-file leases when its owner no longer
  /// needs the immutable view.
  void release() {
    if (_released) return;
    _released = true;
    if (_index != null) {
      _indexLeases.detach(this);
      _index!.release();
    }
    if (_spool != null) {
      _spoolLeases.detach(this);
      _spool!.release();
    }
  }

  int occurrenceAt(int index) {
    RangeError.checkValidIndex(index, this);
    return _entries?[index].key ?? _index!.read(index).occurrenceId;
  }

  @override
  int get length => _length;

  @override
  MediaItem operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final entries = _entries;
    if (entries != null) return entries[index].read();
    final record = _index!.read(index);
    return _spool!.read(record.offset, record.size);
  }

  @override
  set length(int value) => throw UnsupportedError('Immutable music queue snapshot');

  @override
  void operator []=(int index, MediaItem value) => throw UnsupportedError('Immutable music queue snapshot');
}

class _Entry {
  _Entry.memory(this.item, this.key);

  final MediaItem item;
  final int key;
  bool retained = false;
  int? compactedIndex;

  MediaItem read() => item;
}

int _newOccurrenceId() {
  if (_nextOccurrenceId >= 0x7fffffffffffffff) {
    throw RangeError('Music queue occurrence identifiers are exhausted');
  }
  return ++_nextOccurrenceId;
}

class _MetadataRecord {
  const _MetadataRecord(this.offset, this.size);

  final int offset;
  final int size;

  _QueueIndexRecord withOccurrenceId(int occurrenceId) => _QueueIndexRecord(offset, size, occurrenceId);
}

class _QueueIndexRecord {
  _QueueIndexRecord(this.offset, this.size, this.occurrenceId, {this.retained = false, this.compactedIndex = 0});

  final int offset;
  final int size;
  final int occurrenceId;
  bool retained;
  int compactedIndex;

  Uint8List encode() {
    final bytes = Uint8List(_EntryIndex._recordBytes);
    final data = ByteData.view(bytes.buffer);
    data
      ..setUint64(0, offset, Endian.little)
      ..setUint32(8, size, Endian.little)
      ..setUint64(12, occurrenceId, Endian.little)
      ..setUint8(20, retained ? 1 : 0)
      ..setUint32(24, compactedIndex, Endian.little);
    return bytes;
  }

  static _QueueIndexRecord decode(Uint8List bytes, int offset) {
    final data = ByteData.sublistView(bytes, offset, offset + _EntryIndex._recordBytes);
    return _QueueIndexRecord(
      data.getUint64(0, Endian.little),
      data.getUint32(8, Endian.little),
      data.getUint64(12, Endian.little),
      retained: data.getUint8(20) != 0,
      compactedIndex: data.getUint32(24, Endian.little),
    );
  }
}

/// Fixed-width occurrence records with a bounded block cache and COW leases.
class _EntryIndex {
  _EntryIndex._(this.directory, this.file);

  static const _recordBytes = 32;
  static const _recordsPerBlock = 64;
  static const _maxBlocks = 128;
  static const _maxLength = 0x100000000;

  static _EntryIndex create(Directory? root) {
    final directory = (root ?? Directory.systemTemp).createTempSync('pleazyng-music-index-');
    try {
      return _EntryIndex._(directory, File('${directory.path}/occurrences').openSync(mode: FileMode.write));
    } catch (_) {
      directory.deleteSync(recursive: true);
      rethrow;
    }
  }

  final Directory directory;
  final RandomAccessFile file;
  final Map<int, Uint8List> _blocks = {};
  int _length = 0;
  int _references = 1;
  bool _closed = false;

  int get length => _length;
  int get references => _references;

  void retain() {
    if (_closed) throw StateError('Music queue index closed');
    _references++;
  }

  _EntryIndex copy(Directory? root) {
    final target = create(root);
    try {
      file.flushSync();
      file.setPositionSync(0);
      var remaining = _length * _recordBytes;
      while (remaining > 0) {
        final chunk = file.readSync(min(remaining, 1024 * 1024));
        if (chunk.isEmpty) throw const FormatException('Truncated music queue index');
        target.file.writeFromSync(chunk);
        remaining -= chunk.length;
      }
      target._length = _length;
      return target;
    } catch (_) {
      target.release();
      rethrow;
    }
  }

  _QueueIndexRecord read(int index) {
    RangeError.checkValidIndex(index, this);
    final blockNumber = index ~/ _recordsPerBlock;
    var block = _blocks.remove(blockNumber);
    if (block == null) {
      final firstRecord = blockNumber * _recordsPerBlock;
      final count = min(_recordsPerBlock, _length - firstRecord);
      file.setPositionSync(firstRecord * _recordBytes);
      block = file.readSync(count * _recordBytes);
      if (block.length != count * _recordBytes) throw const FormatException('Truncated music queue index');
    }
    _blocks[blockNumber] = block;
    while (_blocks.length > _maxBlocks) {
      _blocks.remove(_blocks.keys.first);
    }
    return _QueueIndexRecord.decode(block, (index % _recordsPerBlock) * _recordBytes);
  }

  void write(int index, _QueueIndexRecord record) {
    RangeError.checkValidIndex(index, this);
    final blockNumber = index ~/ _recordsPerBlock;
    file.setPositionSync(index * _recordBytes);
    final encoded = record.encode();
    try {
      file.writeFromSync(encoded);
    } catch (_) {
      _blocks.remove(blockNumber);
      rethrow;
    }
    final block = _blocks.remove(blockNumber);
    if (block != null) {
      final offset = (index % _recordsPerBlock) * _recordBytes;
      if (offset + _recordBytes <= block.length) {
        block.setRange(offset, offset + _recordBytes, encoded);
        _blocks[blockNumber] = block;
      }
    }
  }

  void append(_QueueIndexRecord record) {
    if (_length >= _maxLength) throw RangeError('Music queue exceeds its occurrence index format');
    final index = _length;
    _length++;
    try {
      write(index, record);
    } catch (_) {
      truncate(index);
      rethrow;
    }
  }

  void insert(int index, _QueueIndexRecord record) {
    RangeError.checkValueInInterval(index, 0, _length, 'index');
    if (_length >= _maxLength) throw RangeError('Music queue exceeds its occurrence index format');
    final originalLength = _length;
    _length++;
    try {
      for (var source = originalLength - 1; source >= index; source--) {
        write(source + 1, read(source));
      }
      write(index, record);
    } catch (_) {
      truncate(originalLength);
      rethrow;
    }
  }

  void removeRange(int start, int end) {
    RangeError.checkValidRange(start, end, _length);
    if (start == end) return;
    final removed = end - start;
    for (var source = end; source < _length; source++) {
      write(source - removed, read(source));
    }
    truncate(_length - removed);
  }

  void truncate(int length) {
    if (length < 0 || length > _length) throw RangeError.value(length, 'length');
    file.truncateSync(length * _recordBytes);
    _length = length;
    _blocks.clear();
  }

  void release() {
    if (_closed || --_references > 0) return;
    _closed = true;
    _blocks.clear();
    try {
      file.closeSync();
    } catch (_) {
      // Scratch cleanup cannot replace a playback result.
    }
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {
      // The OS also reclaims abandoned process scratch.
    }
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
  static const _maxItems = 96;
  static const _maxBytes = 8 * 1024 * 1024;
  static const _maxRecord = 8 * 1024 * 1024;
  static const _maxOrphanBytes = 8 * 1024 * 1024;

  void retain() {
    if (_closed) throw StateError('Music queue spool closed');
    _references++;
  }

  _MetadataRecord append(MediaItem item) {
    if (_closed) throw StateError('Music queue spool closed');
    final bytes = utf8.encode(jsonEncode(item.toJson()));
    if (bytes.length > _maxRecord) throw const FormatException('Music queue metadata record too large');
    final offset = _end;
    file.setPositionSync(offset);
    file.writeFromSync(bytes);
    _end += bytes.length;
    return _MetadataRecord(offset, bytes.length);
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
