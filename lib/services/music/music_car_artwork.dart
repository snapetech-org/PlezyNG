import 'dart:typed_data';
import 'dart:ui' as ui;

/// A small, in-memory presentation cache. Keys bind ephemeral car catalog ids to their authorized image;
/// neither credentials nor paths cross the native catalog boundary.
class MusicCarArtwork {
  static const int maxInputBytes = 4 * 1024 * 1024;
  static const int maxOutputBytes = 512 * 1024;
  final _cache = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List?>>{};
  int _epoch = 0;

  void clear() {
    _epoch++;
    _cache.clear();
    // Retired reads keep their slots until they finish, including after clear().
  }

  Future<Uint8List?> load({
    required String id,
    required int size,
    required Future<Uint8List?> Function() read,
    required bool Function() isCurrent,
  }) async {
    final epoch = _epoch;
    bool current() => epoch == _epoch && isCurrent();
    if (!current() || size < 32 || size > 256) return null;
    final key = '$id:$size';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final pendingKey = '$epoch:$key';
    final existing = _pending[pendingKey];
    if (existing != null) {
      final result = await existing;
      return current() ? result : null;
    }
    // Native queues at most three requests; reject other callers' excess work.
    if (_pending.length >= 3) return null;
    final future = _render(read, size, current);
    _pending[pendingKey] = future;
    try {
      final bytes = await future;
      if (!current() || bytes == null) return null;
      if (_cache.length >= 32) _cache.remove(_cache.keys.first);
      _cache[key] = bytes;
      return bytes;
    } finally {
      _pending.removeWhere((key, value) => key == pendingKey && identical(value, future));
    }
  }

  Future<Uint8List?> _render(Future<Uint8List?> Function() read, int size, bool Function() current) async {
    try {
      final bytes = await read();
      if (!current() || bytes == null || bytes.isEmpty || bytes.length > maxInputBytes) return null;
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          if (!current() ||
              descriptor.width <= 0 ||
              descriptor.height <= 0 ||
              descriptor.width > 16384 ||
              descriptor.height > 16384 ||
              descriptor.width * descriptor.height > 16000000) {
            return null;
          }
          final longest = descriptor.width > descriptor.height ? descriptor.width : descriptor.height;
          final scale = (size / longest).clamp(0.0, 1.0);
          final width = (descriptor.width * scale).round().clamp(1, size);
          final height = (descriptor.height * scale).round().clamp(1, size);
          final codec = await descriptor.instantiateCodec(targetWidth: width, targetHeight: height);
          try {
            final frame = await codec.getNextFrame();
            try {
              if (!current()) return null;
              final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
              if (!current() || data == null || data.lengthInBytes > maxOutputBytes) return null;
              return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      // Artwork failure must not make the car catalog or transport unavailable.
      return null;
    }
  }
}
