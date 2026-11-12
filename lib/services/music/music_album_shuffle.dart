import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../media/media_item.dart';
import 'music_queue_items.dart';
import 'music_queue_order.dart';

const _chunkSize = 2048;
const _chunkMemoryBudget = 8 * 1024 * 1024;
const _mergeFanIn = 16;
const _fixedRecordBytes = 29;
const _maxGroupKeyBytes = 16 * 1024 * 1024;

/// Builds a shuffled album order with bounded working memory. Tracks are
/// sorted in fixed-size runs and merged from scratch files; the returned order
/// has its own leased spool and does not depend on those temporary runs.
MusicQueueOrderSnapshot buildShuffledAlbumOrder({
  required MusicQueueItems items,
  required int currentCanonicalIndex,
  required Random random,
  Directory? scratchRoot,
}) {
  if (items.isEmpty) return MusicQueueOrder(spill: true, scratchRoot: scratchRoot).snapshot(validatedPermutation: true);
  RangeError.checkValidIndex(currentCanonicalIndex, items);

  final workspace = (scratchRoot ?? Directory.systemTemp).createTempSync('pleazyng-album-shuffle-');
  var runSequence = 0;
  File nextRun() => File('${workspace.path}/run-${runSequence++}.bin')..createSync(exclusive: true);
  final levels = <List<File>>[];

  try {
    final anchor = items[currentCanonicalIndex];
    final anchorKey = _groupKey(anchor, currentCanonicalIndex);
    final salt = random.nextInt(0x7fffffff);
    final chunk = <_AlbumOrderRecord>[];
    var chunkBytes = 0;

    void addRun(File candidate) {
      var level = 0;
      while (true) {
        while (levels.length <= level) {
          levels.add(<File>[]);
        }
        final bucket = levels[level];
        bucket.add(candidate);
        if (bucket.length < _mergeFanIn) return;

        final inputs = List<File>.of(bucket);
        candidate = _mergeRuns(inputs, nextRun());
        for (final input in inputs) {
          input.deleteSync();
        }
        bucket.clear();
        level++;
      }
    }

    void flushChunk() {
      if (chunk.isEmpty) return;
      chunk.sort(_compareRecords);
      final output = nextRun();
      final handle = output.openSync(mode: FileMode.write);
      try {
        for (final record in chunk) {
          _writeRecord(handle, record);
        }
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      chunk.clear();
      chunkBytes = 0;
      addRun(output);
    }

    for (var canonical = 0; canonical < items.length; canonical++) {
      final item = items[canonical];
      final groupKey = _groupKey(item, canonical);
      final keyBytes = groupKey.length * 2;
      if (keyBytes > _maxGroupKeyBytes) throw const FormatException('Music album identity is too large');
      if (chunk.isNotEmpty && chunkBytes + keyBytes + 64 > _chunkMemoryBudget) flushChunk();
      chunk.add(
        _AlbumOrderRecord(
          anchor: groupKey == anchorKey,
          priority: groupKey == anchorKey ? 0 : _priority(groupKey, salt),
          disc: item.parentIndex ?? 0,
          track: item.index ?? canonical,
          canonicalIndex: canonical,
          groupKey: groupKey,
        ),
      );
      chunkBytes += keyBytes + 64;
      if (chunk.length == _chunkSize || chunkBytes >= _chunkMemoryBudget) flushChunk();
    }
    flushChunk();

    var runs = levels.expand((bucket) => bucket).toList(growable: false);
    while (runs.length > 1) {
      final merged = <File>[];
      for (var start = 0; start < runs.length; start += _mergeFanIn) {
        final end = min(start + _mergeFanIn, runs.length);
        final inputs = runs.sublist(start, end);
        if (inputs.length == 1) {
          merged.add(inputs.single);
          continue;
        }
        final output = _mergeRuns(inputs, nextRun());
        for (final input in inputs) {
          input.deleteSync();
        }
        merged.add(output);
      }
      runs = merged;
    }

    if (runs.isEmpty) throw StateError('Album shuffle produced no sort runs');
    final staged = MusicQueueOrder(spill: true, scratchRoot: scratchRoot);
    try {
      staged.replaceWith(_canonicalIndexes(runs.single));
      return staged.snapshot(validatedPermutation: true);
    } finally {
      staged.clear();
    }
  } finally {
    workspace.deleteSync(recursive: true);
  }
}

Iterable<int> _canonicalIndexes(File run) sync* {
  final reader = _AlbumOrderRun(run);
  try {
    while (true) {
      final canonical = reader.advanceCanonicalIndex();
      if (canonical == null) return;
      yield canonical;
    }
  } finally {
    reader.close();
  }
}

File _mergeRuns(List<File> inputs, File output) {
  final readers = <_AlbumOrderRun>[];
  final heap = <_AlbumOrderRun>[];
  RandomAccessFile? outputHandle;
  var succeeded = false;
  try {
    outputHandle = output.openSync(mode: FileMode.write);
    for (final input in inputs) {
      final reader = _AlbumOrderRun(input);
      readers.add(reader);
      if (reader.advance()) _heapAdd(heap, reader);
    }
    while (heap.isNotEmpty) {
      final reader = _heapRemoveFirst(heap);
      _writeRecord(outputHandle, reader.current!);
      if (reader.advance()) _heapAdd(heap, reader);
    }
    outputHandle.flushSync();
    succeeded = true;
    return output;
  } finally {
    outputHandle?.closeSync();
    for (final reader in readers) {
      reader.close();
    }
    if (!succeeded && output.existsSync()) output.deleteSync();
  }
}

void _heapAdd(List<_AlbumOrderRun> heap, _AlbumOrderRun reader) {
  var index = heap.length;
  heap.add(reader);
  while (index > 0) {
    final parent = (index - 1) ~/ 2;
    if (_compareRecords(heap[parent].current!, reader.current!) <= 0) break;
    heap[index] = heap[parent];
    index = parent;
  }
  heap[index] = reader;
}

_AlbumOrderRun _heapRemoveFirst(List<_AlbumOrderRun> heap) {
  final first = heap.first;
  final last = heap.removeLast();
  if (heap.isEmpty) return first;
  var index = 0;
  while (true) {
    final left = index * 2 + 1;
    if (left >= heap.length) break;
    final right = left + 1;
    final child = right < heap.length && _compareRecords(heap[right].current!, heap[left].current!) < 0 ? right : left;
    if (_compareRecords(last.current!, heap[child].current!) <= 0) break;
    heap[index] = heap[child];
    index = child;
  }
  heap[index] = last;
  return first;
}

int _compareRecords(_AlbumOrderRecord left, _AlbumOrderRecord right) {
  if (left.anchor != right.anchor) return left.anchor ? -1 : 1;
  final priority = left.priority.compareTo(right.priority);
  if (priority != 0) return priority;
  final group = left.groupKey.compareTo(right.groupKey);
  if (group != 0) return group;
  final disc = left.disc.compareTo(right.disc);
  if (disc != 0) return disc;
  final track = left.track.compareTo(right.track);
  return track != 0 ? track : left.canonicalIndex.compareTo(right.canonicalIndex);
}

String _groupKey(MediaItem item, int canonical) {
  return item.parentId == null ? 'entry:$canonical' : '${item.serverId}:${item.parentId}';
}

int _priority(String groupKey, int salt) {
  // Keep intermediate integers within JavaScript's exact range for web builds.
  var value = (salt ^ 0x4cf5ad43) & 0x7fffffff;
  for (final unit in groupKey.codeUnits) {
    value = ((value ^ unit) * 31) & 0x7fffffff;
  }
  return value;
}

void _writeRecord(RandomAccessFile handle, _AlbumOrderRecord record) {
  final key = record.groupKey.codeUnits;
  final keyBytes = key.length * 2;
  if (keyBytes > _maxGroupKeyBytes) throw const FormatException('Music album identity is too large');
  final bytes = Uint8List(4 + _fixedRecordBytes + keyBytes);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, _fixedRecordBytes + keyBytes, Endian.little);
  data.setUint8(4, record.anchor ? 1 : 0);
  data.setUint32(5, record.priority, Endian.little);
  data.setInt64(9, record.disc, Endian.little);
  data.setInt64(17, record.track, Endian.little);
  data.setUint32(25, record.canonicalIndex, Endian.little);
  data.setUint32(29, key.length, Endian.little);
  for (var index = 0; index < key.length; index++) {
    data.setUint16(4 + _fixedRecordBytes + index * 2, key[index], Endian.little);
  }
  handle.writeFromSync(bytes);
}

Uint8List _readExactly(RandomAccessFile handle, int count) {
  final bytes = Uint8List(count);
  var read = 0;
  while (read < count) {
    final actual = handle.readIntoSync(bytes, read, count);
    if (actual <= 0) throw const FormatException('Truncated album shuffle run');
    read += actual;
  }
  return bytes;
}

class _AlbumOrderRecord {
  const _AlbumOrderRecord({
    required this.anchor,
    required this.priority,
    required this.disc,
    required this.track,
    required this.canonicalIndex,
    required this.groupKey,
  });

  final bool anchor;
  final int priority;
  final int disc;
  final int track;
  final int canonicalIndex;
  final String groupKey;
}

class _AlbumOrderRun {
  _AlbumOrderRun(File file) : _handle = file.openSync(mode: FileMode.read), _remaining = file.lengthSync();

  final RandomAccessFile _handle;
  int _remaining;
  _AlbumOrderRecord? current;

  int? advanceCanonicalIndex() {
    if (_remaining == 0) return null;
    if (_remaining < 4) throw const FormatException('Truncated album shuffle record header');
    final header = _readExactly(_handle, 4);
    final recordBytes = ByteData.sublistView(header).getUint32(0, Endian.little);
    if (recordBytes < _fixedRecordBytes || recordBytes > _fixedRecordBytes + _maxGroupKeyBytes) {
      throw const FormatException('Invalid album shuffle record size');
    }
    if (_remaining < recordBytes + 4) throw const FormatException('Truncated album shuffle record');
    final bytes = _readExactly(_handle, _fixedRecordBytes);
    final data = ByteData.sublistView(bytes);
    final keyUnits = data.getUint32(25, Endian.little);
    if (recordBytes != _fixedRecordBytes + keyUnits * 2 || data.getUint8(0) > 1) {
      throw const FormatException('Invalid album shuffle record');
    }
    _handle.setPositionSync(_handle.positionSync() + keyUnits * 2);
    _remaining -= recordBytes + 4;
    return data.getUint32(21, Endian.little);
  }

  bool advance() {
    if (_remaining == 0) {
      current = null;
      return false;
    }
    if (_remaining < 4) throw const FormatException('Truncated album shuffle record header');
    final header = _readExactly(_handle, 4);
    final recordBytes = ByteData.sublistView(header).getUint32(0, Endian.little);
    if (recordBytes < _fixedRecordBytes || recordBytes > _fixedRecordBytes + _maxGroupKeyBytes) {
      throw const FormatException('Invalid album shuffle record size');
    }
    if (_remaining < recordBytes + 4) throw const FormatException('Truncated album shuffle record');
    final bytes = _readExactly(_handle, recordBytes);
    _remaining -= recordBytes + 4;
    final data = ByteData.sublistView(bytes);
    final keyUnits = data.getUint32(25, Endian.little);
    if (recordBytes != _fixedRecordBytes + keyUnits * 2 || data.getUint8(0) > 1) {
      throw const FormatException('Invalid album shuffle record');
    }
    final codeUnits = Uint16List(keyUnits);
    for (var index = 0; index < keyUnits; index++) {
      codeUnits[index] = data.getUint16(_fixedRecordBytes + index * 2, Endian.little);
    }
    final groupKey = String.fromCharCodes(codeUnits);
    current = _AlbumOrderRecord(
      anchor: data.getUint8(0) == 1,
      priority: data.getUint32(1, Endian.little),
      disc: data.getInt64(5, Endian.little),
      track: data.getInt64(13, Endian.little),
      canonicalIndex: data.getUint32(21, Endian.little),
      groupKey: groupKey,
    );
    return true;
  }

  void close() => _handle.closeSync();
}
