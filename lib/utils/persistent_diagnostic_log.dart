import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// App-private diagnostics when the native embedder discards stdout. Callers
/// supply redacted records; disk errors must never affect playback.
class PersistentDiagnosticLog {
  PersistentDiagnosticLog(this.file, {this.maxBytes = 2 * 1024 * 1024, this.maxPendingBytes = 64 * 1024});

  final File file;
  final int maxBytes;
  final int maxPendingBytes;
  final Queue<Uint8List> _pending = Queue();
  int _pendingBytes = 0;
  int? _size;
  bool _disabled = false;
  bool _closed = false;
  Future<void>? _writing;

  void add(String redactedRecord) {
    if (_disabled || _closed || maxBytes <= 0 || maxPendingBytes <= 0) return;
    final bounded = redactedRecord.length > 4096 ? '${redactedRecord.substring(0, 4096)}…' : redactedRecord;
    final bytes = Uint8List.fromList(utf8.encode('$bounded\n'));
    if (bytes.length > maxPendingBytes || bytes.length > maxBytes) return;
    while (_pendingBytes + bytes.length > maxPendingBytes && _pending.isNotEmpty) {
      _pendingBytes -= _pending.removeFirst().length;
    }
    _pending.add(bytes);
    _pendingBytes += bytes.length;
    _writing ??= Future<void>.microtask(_drain);
  }

  Future<void> _drain() async {
    try {
      if (_size == null) {
        await file.parent.create(recursive: true);
        final kind = await FileSystemEntity.type(file.path, followLinks: false);
        if (kind != FileSystemEntityType.notFound && kind != FileSystemEntityType.file) {
          throw const FileSystemException('Diagnostic path is not a regular file.');
        }
        _size = kind == FileSystemEntityType.file ? await file.length() : 0;
      }
      while (_pending.isNotEmpty) {
        final batch = BytesBuilder(copy: false);
        while (_pending.isNotEmpty && batch.length + _pending.first.length <= maxBytes) {
          final bytes = _pending.removeFirst();
          _pendingBytes -= bytes.length;
          batch.add(bytes);
        }
        if (_size! + batch.length > maxBytes) {
          final previous = File('${file.path}.previous');
          if (await previous.exists()) await previous.delete();
          if (await file.exists()) await file.rename(previous.path);
          _size = 0;
        }
        await file.writeAsBytes(batch.takeBytes(), mode: FileMode.append);
        _size = await file.length();
      }
    } catch (_) {
      _disabled = true;
      _pending.clear();
      _pendingBytes = 0;
    } finally {
      _writing = null;
    }
  }

  Future<void> flush() async {
    final writing = _writing;
    if (writing != null) await writing;
  }

  Future<void> close() async {
    _closed = true;
    await flush();
  }
}
