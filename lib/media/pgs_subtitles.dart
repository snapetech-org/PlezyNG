import 'dart:typed_data';

/// Blu-ray PGS display sets, decoded independently of the video stream.
/// Keep compressed objects in the timeline; rasterize only the visible cue.
class PgsSubtitles {
  static const maxFileBytes = 64 * 1024 * 1024;
  static const _maxPixels = 4096 * 2160;
  final List<PgsCue> cues;

  PgsSubtitles._(this.cues);

  factory PgsSubtitles.parse(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxFileBytes) {
      throw const FormatException('PGS subtitle file size is invalid.');
    }
    final parser = _PgsParser();
    final reader = _PgsReader(bytes);
    var previousPts = 0;
    var wraps = 0;
    while (reader.remaining > 0) {
      if (reader.u16() != 0x5047) throw const FormatException('Invalid PGS segment signature.');
      final pts = reader.u32();
      if (previousPts - pts > 0x80000000) wraps++;
      previousPts = pts;
      reader.u32(); // Decode timestamp; presentation follows the PCS timestamp.
      final type = reader.u8();
      final payload = reader.take(reader.u16());
      parser.segment(type, payload, Duration(microseconds: ((pts + wraps * 0x100000000) * 1000000) ~/ 90000));
    }
    if (parser.pending != null || parser.fragments.isNotEmpty || parser.cues.isEmpty) {
      throw const FormatException('Incomplete PGS display set.');
    }
    return PgsSubtitles._(List.unmodifiable(parser.cues));
  }

  /// A clear display set ends the preceding image. Seek directly by media time.
  PgsCue? at(Duration position) {
    var low = 0;
    var high = cues.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (cues[middle].start <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 || cues[low - 1]._objects.isEmpty ? null : cues[low - 1];
  }
}

class PgsRaster {
  final int x, y, width, height;
  final bool forced;
  final Uint8List rgba;

  PgsRaster({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.forced,
    required this.rgba,
  });
}

class PgsCue {
  final Duration start;
  final int width, height;
  final List<_PgsPlacement> _objects;
  final Uint32List _palette;

  PgsCue._(this.start, this.width, this.height, this._objects, this._palette);

  /// RGBA. Flutter's RGBA8888 image decoder requires premultiplied alpha;
  /// straight alpha remains useful for comparing decoder output and exports.
  List<PgsRaster> rasterize({bool forcedOnly = false, bool premultiplied = false}) {
    final result = <PgsRaster>[];
    var pixels = 0;
    for (final object in _objects) {
      if (forcedOnly && !object.forced) continue;
      pixels += object.width * object.height;
      if (pixels > PgsSubtitles._maxPixels) throw const FormatException('PGS display set exceeds the pixel limit.');
      final indices = object.bitmap.decode();
      final rgba = Uint8List(object.width * object.height * 4);
      for (var y = 0; y < object.height; y++) {
        for (var x = 0; x < object.width; x++) {
          final color = _palette[indices[(object.top + y) * object.bitmap.width + object.left + x]];
          final offset = (y * object.width + x) * 4;
          final alpha = color & 255;
          rgba[offset] = premultiplied ? ((color >> 24) & 255) * alpha ~/ 255 : color >> 24;
          rgba[offset + 1] = premultiplied ? ((color >> 16) & 255) * alpha ~/ 255 : color >> 16;
          rgba[offset + 2] = premultiplied ? ((color >> 8) & 255) * alpha ~/ 255 : color >> 8;
          rgba[offset + 3] = alpha;
        }
      }
      result.add(
        PgsRaster(
          x: object.x,
          y: object.y,
          width: object.width,
          height: object.height,
          forced: object.forced,
          rgba: rgba,
        ),
      );
    }
    return result;
  }
}

class _PgsBitmap {
  final int width, height;
  final Uint8List rle;

  _PgsBitmap(this.width, this.height, this.rle);

  Uint8List decode() {
    final output = Uint8List(width * height);
    _process(output);
    return output;
  }

  void validate() => _process(null);

  void _process(Uint8List? output) {
    final reader = _PgsReader(rle);
    var x = 0;
    var y = 0;
    while (reader.remaining > 0) {
      final value = reader.u8();
      var color = value;
      var count = 1;
      if (value == 0) {
        final flags = reader.u8();
        if (flags == 0) {
          if (x != width || y >= height) throw const FormatException('Invalid PGS bitmap row.');
          x = 0;
          y++;
          continue;
        }
        count = flags & 0x3f;
        if (flags & 0x40 != 0) count = (count << 8) | reader.u8();
        color = flags & 0x80 != 0 ? reader.u8() : 0;
      }
      if (count == 0 || y >= height || x + count > width) {
        throw const FormatException('PGS bitmap run exceeds its row.');
      }
      output?.fillRange(y * width + x, y * width + x + count, color);
      x += count;
    }
    if (!((y == height && x == 0) || (y == height - 1 && x == width))) {
      throw const FormatException('Incomplete PGS bitmap.');
    }
  }
}

class _PgsPlacement {
  final _PgsBitmap bitmap;
  final int x, y, left, top, width, height;
  final bool forced;

  _PgsPlacement(this.bitmap, this.x, this.y, this.left, this.top, this.width, this.height, this.forced);
}

class _PgsReference {
  final int id, window, x, y;
  final bool forced;
  final List<int>? crop;

  _PgsReference(this.id, this.window, this.x, this.y, this.forced, this.crop);
}

class _PgsComposition {
  final Duration pts;
  final int width, height, palette;
  final List<_PgsReference> objects;

  _PgsComposition(this.pts, this.width, this.height, this.palette, this.objects);
}

class _PgsFragment {
  final int width, height, version, size;
  final BytesBuilder bytes = BytesBuilder(copy: false);

  _PgsFragment(this.width, this.height, this.version, this.size);
}

class _PgsParser {
  final cues = <PgsCue>[];
  final palettes = <int, Uint32List>{};
  final bitmaps = <int, _PgsBitmap>{};
  final fragments = <int, _PgsFragment>{};
  final windows = <int, List<int>>{};
  _PgsComposition? pending;

  void segment(int type, Uint8List bytes, Duration pts) {
    final reader = _PgsReader(bytes);
    switch (type) {
      case 0x14:
        final id = reader.u8();
        reader.u8();
        if (reader.remaining % 5 != 0) throw const FormatException('Invalid PGS palette.');
        final palette = Uint32List.fromList(palettes[id] ?? Uint32List(256));
        while (reader.remaining > 0) {
          final entry = reader.u8();
          final y = reader.u8() - 16;
          final cr = reader.u8() - 128;
          final cb = reader.u8() - 128;
          final a = reader.u8();
          final r = ((298 * y + 409 * cr + 128) >> 8).clamp(0, 255);
          final g = ((298 * y - 100 * cb - 208 * cr + 128) >> 8).clamp(0, 255);
          final b = ((298 * y + 516 * cb + 128) >> 8).clamp(0, 255);
          palette[entry] = (r << 24) | (g << 16) | (b << 8) | a;
        }
        palettes[id] = palette;
      case 0x15:
        final id = reader.u16();
        final version = reader.u8();
        final flags = reader.u8();
        if (flags & 0x80 != 0) {
          final size = reader.u24() - 4;
          final width = reader.u16();
          final height = reader.u16();
          if (size <= 0 ||
              size > 16 * 1024 * 1024 ||
              width == 0 ||
              height == 0 ||
              width * height > PgsSubtitles._maxPixels) {
            throw const FormatException('PGS object dimensions or size are invalid.');
          }
          if (fragments.length >= 64 && !fragments.containsKey(id)) {
            throw const FormatException('Too many PGS objects.');
          }
          fragments[id] = _PgsFragment(width, height, version, size);
        }
        final fragment = fragments[id];
        if (fragment == null ||
            fragment.version != version ||
            fragment.bytes.length + reader.remaining > fragment.size) {
          throw const FormatException('Invalid PGS object fragment.');
        }
        fragment.bytes.add(reader.take(reader.remaining));
        if (flags & 0x40 != 0) {
          if (fragment.bytes.length != fragment.size) throw const FormatException('Incomplete PGS object fragment.');
          final bitmap = _PgsBitmap(fragment.width, fragment.height, fragment.bytes.takeBytes());
          bitmap.validate();
          bitmaps[id] = bitmap;
          fragments.remove(id);
        }
      case 0x16:
        if (pending != null) throw const FormatException('Unterminated PGS display set.');
        final width = reader.u16();
        final height = reader.u16();
        reader.u8(); // Frame rate.
        reader.u16(); // Composition sequence.
        final state = reader.u8();
        reader.u8(); // Palette update flag.
        final palette = reader.u8();
        final count = reader.u8();
        if (width == 0 || height == 0 || width > 4096 || height > 2160 || count > 64) {
          throw const FormatException('PGS canvas dimensions or object count are invalid.');
        }
        if (state == 0x80) {
          palettes.clear();
          bitmaps.clear();
          fragments.clear();
          windows.clear();
        }
        final objects = <_PgsReference>[];
        for (var i = 0; i < count; i++) {
          final id = reader.u16();
          final window = reader.u8();
          final flags = reader.u8();
          final x = reader.u16();
          final y = reader.u16();
          final crop = flags & 0x80 != 0 ? List.generate(4, (_) => reader.u16()) : null;
          objects.add(_PgsReference(id, window, x, y, flags & 0x40 != 0, crop));
        }
        if (reader.remaining != 0) throw const FormatException('Invalid PGS composition length.');
        pending = _PgsComposition(pts, width, height, palette, objects);
      case 0x17:
        final count = reader.u8();
        for (var i = 0; i < count; i++) {
          windows[reader.u8()] = List.generate(4, (_) => reader.u16());
        }
        if (reader.remaining != 0) throw const FormatException('Invalid PGS window length.');
      case 0x80:
        final composition = pending;
        if (bytes.isNotEmpty || composition == null || fragments.isNotEmpty) {
          throw const FormatException('Invalid PGS display set end.');
        }
        if (cues.length >= 100000 || (cues.isNotEmpty && composition.pts < cues.last.start)) {
          throw const FormatException('Invalid PGS display set timeline.');
        }
        final palette = palettes[composition.palette];
        if (composition.objects.isNotEmpty && palette == null) throw const FormatException('Missing PGS palette.');
        final objects = <_PgsPlacement>[];
        for (final reference in composition.objects) {
          final bitmap = bitmaps[reference.id];
          if (bitmap == null) throw const FormatException('Missing PGS bitmap.');
          final crop = reference.crop ?? [0, 0, bitmap.width, bitmap.height];
          if (crop[2] == 0 || crop[3] == 0 || crop[0] + crop[2] > bitmap.width || crop[1] + crop[3] > bitmap.height) {
            throw const FormatException('Invalid PGS object crop.');
          }
          final window = windows[reference.window] ?? [0, 0, composition.width, composition.height];
          if (window[2] == 0 ||
              window[3] == 0 ||
              window[0] + window[2] > composition.width ||
              window[1] + window[3] > composition.height) {
            throw const FormatException('Invalid PGS display window.');
          }
          final x = reference.x;
          final y = reference.y;
          final left = x.clamp(window[0], composition.width);
          final top = y.clamp(window[1], composition.height);
          final right = (x + crop[2]).clamp(0, (window[0] + window[2]).clamp(0, composition.width));
          final bottom = (y + crop[3]).clamp(0, (window[1] + window[3]).clamp(0, composition.height));
          if (right <= left || bottom <= top) continue;
          objects.add(
            _PgsPlacement(
              bitmap,
              left,
              top,
              crop[0] + left - x,
              crop[1] + top - y,
              right - left,
              bottom - top,
              reference.forced,
            ),
          );
        }
        cues.add(
          PgsCue._(
            composition.pts,
            composition.width,
            composition.height,
            List.unmodifiable(objects),
            palette ?? Uint32List(256),
          ),
        );
        pending = null;
      default:
        throw const FormatException('Unknown PGS segment type.');
    }
  }
}

class _PgsReader {
  final Uint8List bytes;
  int offset = 0;
  _PgsReader(this.bytes);
  int get remaining => bytes.length - offset;
  int u8() {
    if (remaining < 1) throw const FormatException('Truncated PGS segment.');
    return bytes[offset++];
  }

  int u16() => (u8() << 8) | u8();
  int u24() => (u16() << 8) | u8();
  int u32() => (u24() << 8) | u8();
  Uint8List take(int count) {
    if (count < 0 || remaining < count) throw const FormatException('Truncated PGS segment payload.');
    final start = offset;
    offset += count;
    return Uint8List.sublistView(bytes, start, offset);
  }
}
