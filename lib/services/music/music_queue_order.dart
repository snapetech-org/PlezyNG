import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A playback order that does not allocate an index for the common canonical
/// order, and spills large shuffled orders to a fixed-width scratch file.
/// Snapshots keep a stable lease; the mutable owner copies the file on write.
class MusicQueueOrder extends ListBase<int> {
  MusicQueueOrder({this.spill = false, this.scratchRoot, this.threshold = 512}) {
    if (threshold < 1) throw ArgumentError.value(threshold, 'threshold');
  }

  final bool spill;
  final Directory? scratchRoot;
  final int threshold;
  int _length = 0;
  bool _identity = true;
  List<int>? _memory;
  _OrderSpool? _spool;

  bool get isIdentity => _identity;
  bool get isSpilled => _spool != null;

  @override
  int get length => _length;

  @override
  set length(int value) {
    if (value < 0 || value > _length) throw UnsupportedError('Queue order can only be shortened');
    removeRange(value, _length);
  }

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this);
    if (_identity) return index;
    return _memory?[index] ?? _spool!.read(index);
  }

  @override
  void operator []=(int index, int value) {
    RangeError.checkValidIndex(index, this);
    _checkValue(value);
    if (_identity && value == index) return;
    _materializeIdentity();
    final memory = _memory;
    if (memory != null) {
      memory[index] = value;
    } else {
      _writableSpool().write(index, value);
    }
  }

  void resetIdentity(int length) {
    if (length < 0 || length > 0x100000000) throw RangeError.value(length, 'length');
    _releaseStorage();
    _length = length;
    _identity = true;
  }

  /// Appends the consecutive canonical indexes [start, start + count).
  void appendRange(int start, int count) {
    if (count < 0 || start < 0 || start > 0xffffffff || count > 0x100000000 - start || count > 0x100000000 - _length) {
      throw RangeError('Invalid canonical queue-index range');
    }
    if (count == 0) return;
    if (_identity && start == _length) {
      _length += count;
      return;
    }
    _materializeIdentity();
    _promoteFor(_length + count);
    final memory = _memory;
    if (memory != null) {
      memory.addAll(List<int>.generate(count, (offset) => start + offset, growable: false));
    } else {
      _writableSpool().appendRange(start, count);
    }
    _length += count;
  }

  /// Inserts consecutive canonical indexes without building a second large
  /// list when the playback order is disk-backed.
  void insertRange(int position, int start, int count) {
    RangeError.checkValueInInterval(position, 0, _length, 'position');
    if (count < 0 || start < 0 || start > 0xffffffff || count > 0x100000000 - start || count > 0x100000000 - _length) {
      throw RangeError('Invalid canonical queue-index range');
    }
    if (count == 0) return;
    if (_identity && position == _length && start == _length) {
      appendRange(start, count);
      return;
    }
    _materializeIdentity();
    _promoteFor(_length + count);
    final memory = _memory;
    if (memory != null) {
      memory.insertAll(position, List<int>.generate(count, (offset) => start + offset, growable: false));
    } else {
      _writableSpool().insertRange(position, start, count);
    }
    _length += count;
  }

  void swap(int first, int second) {
    RangeError.checkValidIndex(first, this);
    RangeError.checkValidIndex(second, this);
    if (first == second) return;
    final a = this[first];
    final b = this[second];
    this[first] = b;
    this[second] = a;
  }

  void shuffleFrom(int start, Random random) {
    RangeError.checkValueInInterval(start, 0, _length, 'start');
    for (var end = _length - 1; end > start; end--) {
      swap(end, start + random.nextInt(end - start + 1));
    }
  }

  void decrementAbove(int value) {
    if (_identity) return;
    final memory = _memory;
    if (memory != null) {
      for (var index = 0; index < memory.length; index++) {
        if (memory[index] > value) memory[index]--;
      }
    } else {
      _writableSpool().decrementAbove(value);
    }
  }

  void move(int from, int to) {
    if (from < 0 || from >= _length || to < 0 || to >= _length || from == to) return;
    final value = removeAt(from);
    insert(to, value);
  }

  void replaceWith(Iterable<int> values) {
    if (values is MusicQueueOrderSnapshot) {
      _releaseStorage();
      _length = values.length;
      _identity = values._identity;
      if (values._identity) return;
      if (values._spool case final spool?) {
        spool.retain();
        _spool = spool;
      } else {
        _memory = List<int>.of(values._memory!);
      }
      return;
    }

    resetIdentity(0);
    var identityCandidate = true;
    var count = 0;
    for (final value in values) {
      if (count >= 0x100000000) throw RangeError('Music queue order exceeds its index format');
      _checkValue(value);
      if (identityCandidate && value == count) {
        count++;
        continue;
      }
      if (identityCandidate) {
        _length = count;
        _materializeIdentity();
        identityCandidate = false;
      }
      _appendValue(value);
      count++;
    }
    if (identityCandidate) resetIdentity(count);
  }

  MusicQueueOrderSnapshot snapshot({bool validatedPermutation = false}) {
    if (_identity) {
      return MusicQueueOrderSnapshot._identity(_length, validatedPermutation);
    }
    if (_spool case final spool?) {
      return MusicQueueOrderSnapshot._spooled(_length, spool, validatedPermutation);
    }
    return MusicQueueOrderSnapshot._memory(List<int>.unmodifiable(_memory!), validatedPermutation);
  }

  @override
  void add(int element) {
    if (_length >= 0x100000000) throw RangeError('Music queue order exceeds its index format');
    _checkValue(element);
    if (_identity && element == _length && element <= 0xffffffff) {
      _length++;
      return;
    }
    _materializeIdentity();
    _appendValue(element);
  }

  @override
  void addAll(Iterable<int> iterable) {
    for (final element in iterable) {
      add(element);
    }
  }

  @override
  void insert(int index, int element) {
    RangeError.checkValueInInterval(index, 0, _length, 'index');
    if (_length >= 0x100000000) throw RangeError('Music queue order exceeds its index format');
    _checkValue(element);
    if (index == _length) {
      add(element);
      return;
    }
    _materializeIdentity();
    _promoteFor(_length + 1);
    final memory = _memory;
    if (memory != null) {
      memory.insert(index, element);
    } else {
      _writableSpool().insertValues(index, [element]);
    }
    _length++;
  }

  @override
  int removeAt(int index) {
    RangeError.checkValidIndex(index, this);
    final value = this[index];
    if (_identity && index == _length - 1) {
      _length--;
      return value;
    }
    _materializeIdentity();
    final memory = _memory;
    if (memory != null) {
      memory.removeAt(index);
    } else {
      _writableSpool().removeRange(index, index + 1);
    }
    _length--;
    return value;
  }

  @override
  void removeRange(int start, int end) {
    RangeError.checkValidRange(start, end, _length);
    if (start == end) return;
    if (_identity && end == _length) {
      _length = start;
      return;
    }
    _materializeIdentity();
    final memory = _memory;
    if (memory != null) {
      memory.removeRange(start, end);
    } else {
      _writableSpool().removeRange(start, end);
    }
    _length -= end - start;
  }

  @override
  void clear() => resetIdentity(0);

  void _appendValue(int value) {
    _checkValue(value);
    _promoteFor(_length + 1);
    final memory = _memory;
    if (memory != null) {
      memory.add(value);
    } else {
      _writableSpool().appendValues([value]);
    }
    _length++;
  }

  void _promoteFor(int requiredLength) {
    if (!spill || _spool != null || requiredLength <= threshold) return;
    final values = _memory ?? const <int>[];
    final spool = _OrderSpool.create(scratchRoot);
    try {
      spool.appendValues(values);
    } catch (_) {
      spool.release();
      rethrow;
    }
    _memory = null;
    _spool = spool;
  }

  void _materializeIdentity() {
    if (!_identity) return;
    if (spill && _length > threshold) {
      final spool = _OrderSpool.create(scratchRoot);
      try {
        spool.appendRange(0, _length);
      } catch (_) {
        spool.release();
        rethrow;
      }
      _spool = spool;
    } else {
      _memory = List<int>.generate(_length, (index) => index, growable: true);
    }
    _identity = false;
  }

  _OrderSpool _writableSpool() {
    final spool = _spool!;
    if (spool.references == 1) return spool;
    final copy = spool.copy();
    spool.release();
    _spool = copy;
    return copy;
  }

  void _releaseStorage() {
    _memory = null;
    _spool?.release();
    _spool = null;
    _identity = true;
    _length = 0;
  }

  static void _checkValue(int value) {
    if (value < 0 || value > 0xffffffff) throw RangeError.value(value, 'queue index');
  }
}

/// Immutable queue-order view. Disk-backed snapshots retain the source file;
/// later mutations clone it before writing, so queue and persistence views are
/// stable without an O(n) in-memory copy.
class MusicQueueOrderSnapshot extends ListBase<int> {
  MusicQueueOrderSnapshot._identity(this._length, this._validatedPermutation)
    : _identity = true,
      _memory = null,
      _spool = null;

  MusicQueueOrderSnapshot._memory(List<int> memory, this._validatedPermutation)
    : _length = memory.length,
      _identity = false,
      _memory = memory,
      _spool = null;

  MusicQueueOrderSnapshot._spooled(this._length, _OrderSpool spool, this._validatedPermutation)
    : _identity = false,
      _memory = null,
      _spool = spool {
    spool.retain();
    _leases.attach(this, spool);
  }

  static final Finalizer<_OrderSpool> _leases = Finalizer<_OrderSpool>((spool) => spool.release());
  final int _length;
  final bool _identity;
  final List<int>? _memory;
  final _OrderSpool? _spool;
  final bool _validatedPermutation;
  bool get isValidatedPermutation => _validatedPermutation;

  @override
  int get length => _length;
  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this);
    if (_identity) return index;
    return _memory?[index] ?? _spool!.read(index);
  }

  @override
  set length(int value) => throw UnsupportedError('Immutable music queue order');
  @override
  void operator []=(int index, int value) => throw UnsupportedError('Immutable music queue order');
}

class _OrderSpool {
  _OrderSpool._(this.directory, this.file, this._handle, this.length);

  static const _entriesPerBlock = 4096;
  static const _blockBytes = _entriesPerBlock * 4;
  static const _maxCachedBlocks = 16;

  static _OrderSpool create(Directory? root) {
    final directory = (root ?? Directory.systemTemp).createTempSync('pleazyng-music-order-');
    try {
      final file = File('${directory.path}/order');
      return _OrderSpool._(directory, file, file.openSync(mode: FileMode.write), 0);
    } catch (_) {
      directory.deleteSync(recursive: true);
      rethrow;
    }
  }

  final Directory directory;
  final File file;
  final RandomAccessFile _handle;
  final LinkedHashMap<int, Uint32List> _cache = LinkedHashMap<int, Uint32List>();
  int length;
  int references = 1;
  bool _closed = false;

  _OrderSpool copy() {
    if (_closed) throw StateError('Music queue order spool closed');
    _handle.flushSync();
    final target = _OrderSpool.create(directory.parent);
    try {
      for (var start = 0; start < length; start += _entriesPerBlock) {
        final count = min(_entriesPerBlock, length - start);
        target._writeBytes(start * 4, _readBytes(start * 4, count * 4));
      }
      target.length = length;
      target._handle.truncateSync(length * 4);
      target._handle.setPositionSync(length * 4);
      return target;
    } catch (_) {
      target.release();
      rethrow;
    }
  }

  void retain() {
    if (_closed) throw StateError('Music queue order spool closed');
    references++;
  }

  void release() {
    if (_closed || --references > 0) return;
    _closed = true;
    _cache.clear();
    try {
      _handle.closeSync();
    } on Object {
      // Best-effort cleanup; a later process cleanup can remove the scratch file.
    }
    try {
      directory.deleteSync(recursive: true);
    } on Object {
      // Do not let temporary-file cleanup interrupt queue teardown.
    }
  }

  int read(int index) {
    if (index < 0 || index >= length) throw RangeError.index(index, this);
    final blockNumber = index ~/ _entriesPerBlock;
    final block = _block(blockNumber);
    return block[index - blockNumber * _entriesPerBlock];
  }

  void write(int index, int value) {
    RangeError.checkValidIndex(index, this);
    final blockNumber = index ~/ _entriesPerBlock;
    final block = _block(blockNumber);
    block[index - blockNumber * _entriesPerBlock] = value;
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
    _writeBytes(index * 4, bytes);
  }

  void decrementAbove(int value) {
    for (var start = 0; start < length; start += _entriesPerBlock) {
      final count = min(_entriesPerBlock, length - start);
      final block = _block(start ~/ _entriesPerBlock);
      var changed = false;
      for (var offset = 0; offset < count; offset++) {
        if (block[offset] > value) {
          block[offset]--;
          changed = true;
        }
      }
      if (changed) _writeValues(start, block);
    }
  }

  void appendRange(int start, int count) {
    var appended = 0;
    while (appended < count) {
      final size = min(_entriesPerBlock, count - appended);
      final values = Uint32List(size);
      for (var i = 0; i < size; i++) {
        values[i] = start + appended + i;
      }
      _appendBlock(values);
      appended += size;
    }
  }

  void appendValues(Iterable<int> values) {
    if (values is List<int>) {
      for (var start = 0; start < values.length; start += _entriesPerBlock) {
        final count = min(_entriesPerBlock, values.length - start);
        final block = Uint32List(count);
        for (var index = 0; index < count; index++) {
          final value = values[start + index];
          if (value < 0 || value > 0xffffffff) throw RangeError.value(value, 'queue index');
          block[index] = value;
        }
        _appendBlock(block);
      }
      return;
    }
    final block = Uint32List(_entriesPerBlock);
    var used = 0;
    for (final value in values) {
      if (value < 0 || value > 0xffffffff) throw RangeError.value(value, 'queue index');
      block[used++] = value;
      if (used == block.length) {
        _appendBlock(block);
        used = 0;
      }
    }
    if (used > 0) _appendBlock(block.sublist(0, used));
  }

  void insertRange(int index, int start, int count) {
    if (count == 0) return;
    _checkInsert(index);
    _shiftRight(index, count);
    var inserted = 0;
    while (inserted < count) {
      final size = min(_entriesPerBlock, count - inserted);
      final values = Uint32List(size);
      for (var i = 0; i < size; i++) {
        values[i] = start + inserted + i;
      }
      _writeValues(index + inserted, values);
      inserted += size;
    }
    length += count;
    _cache.clear();
  }

  void insertValues(int index, List<int> values) {
    if (values.isEmpty) return;
    _checkInsert(index);
    _shiftRight(index, values.length);
    _writeValues(index, values);
    length += values.length;
    _cache.clear();
  }

  void removeRange(int start, int end) {
    if (start < 0 || end < start || end > length) throw RangeError('Invalid queue-order range');
    final count = end - start;
    if (count == 0) return;
    var source = end;
    while (source < length) {
      final size = min(_entriesPerBlock, length - source);
      final bytes = _readBytes(source * 4, size * 4);
      _writeBytes((source - count) * 4, bytes);
      source += size;
    }
    length -= count;
    _handle.truncateSync(length * 4);
    _handle.setPositionSync(length * 4);
    _cache.clear();
  }

  Uint32List _block(int blockNumber) {
    final cached = _cache.remove(blockNumber);
    if (cached != null) {
      _cache[blockNumber] = cached;
      return cached;
    }
    final start = blockNumber * _entriesPerBlock;
    final count = min(_entriesPerBlock, length - start);
    final bytes = _readBytes(start * 4, count * 4);
    final data = ByteData.sublistView(bytes);
    final values = Uint32List(count);
    for (var index = 0; index < count; index++) {
      values[index] = data.getUint32(index * 4, Endian.little);
    }
    _cache[blockNumber] = values;
    if (_cache.length > _maxCachedBlocks) _cache.remove(_cache.keys.first);
    return values;
  }

  void _appendBlock(Uint32List values) {
    _writeValues(length, values);
    length += values.length;
  }

  void _shiftRight(int index, int count) {
    final byteCount = count * 4;
    _handle.truncateSync((length + count) * 4);
    var sourceEnd = length * 4;
    final destinationStart = index * 4;
    while (sourceEnd > destinationStart) {
      final sourceStart = max(destinationStart, sourceEnd - _blockBytes);
      final bytes = _readBytes(sourceStart, sourceEnd - sourceStart);
      _writeBytes(sourceStart + byteCount, bytes);
      sourceEnd = sourceStart;
    }
  }

  void _writeValues(int index, Iterable<int> values) {
    final list = values is List<int> ? values : values.toList(growable: false);
    if (list.isEmpty) return;
    final bytes = Uint8List(list.length * 4);
    final data = ByteData.sublistView(bytes);
    for (var offset = 0; offset < list.length; offset++) {
      final value = list[offset];
      if (value < 0 || value > 0xffffffff) throw RangeError.value(value, 'queue index');
      data.setUint32(offset * 4, value, Endian.little);
    }
    _writeBytes(index * 4, bytes);
    _cache.clear();
  }

  Uint8List _readBytes(int offset, int count) {
    final bytes = Uint8List(count);
    _handle.setPositionSync(offset);
    var read = 0;
    while (read < count) {
      final actual = _handle.readIntoSync(bytes, read, count);
      if (actual <= 0) throw const FormatException('Truncated music queue order spool');
      read += actual;
    }
    return bytes;
  }

  void _writeBytes(int offset, List<int> bytes) {
    _handle.setPositionSync(offset);
    _handle.writeFromSync(bytes);
  }

  void _checkInsert(int index) {
    if (_closed) throw StateError('Music queue order spool closed');
    RangeError.checkValueInInterval(index, 0, length, 'index');
  }
}
