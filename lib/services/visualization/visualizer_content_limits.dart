import 'dart:convert';
import 'dart:typed_data';
import 'visualizer_preset_text.dart';

/// Header-only checks before handing community assets to a native decoder.
/// These bound allocations; they do not replace codec validation or isolation.
abstract final class VisualizerContentLimits {
  static const maxPresetBytes = 2 * 1024 * 1024;
  static const maxImageBytes = 16 * 1024 * 1024;
  static const maxImageDimension = 4096;
  static const maxImagePixels = 8 * 1024 * 1024;
  static const maxPackImagePixels = 32 * 1024 * 1024;
  static const imageExtensions = {'.png', '.jpg', '.jpeg', '.jfif', '.bmp', '.tga', '.gif', '.webp', '.dds'};
  static const _dataExtensions = {'.milk', '.milk2', '.json', '.txt', '.md', '.license'};
  static const _maxAnimationFrames = 120;
  static const _maxAnimationPixels = 16 * 1024 * 1024;

  static void checkAssetPath(String path, {bool isNotice = false}) {
    final name = path.split('/').last.toLowerCase();
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot);
    // Notices may be extensionless (LICENSE/COPYING), but never native/code files.
    if (_dataExtensions.contains(extension) || imageExtensions.contains(extension) || (isNotice && extension.isEmpty)) {
      return;
    }
    throw FormatException('Unsupported pack asset type: $path. Executable plugins are not imported.');
  }

  static void checkPreset(List<int> bytes) {
    final text = VisualizerPresetText.decode(bytes);
    final include = RegExp(r'(^|[=;])\s*`?\s*#\s*include\b', caseSensitive: false);
    for (final line in const LineSplitter().convert(text)) {
      final source = line.trimLeft();
      if (!source.startsWith('//') && include.hasMatch(source)) {
        throw const FormatException(
          'Shader includes are not allowed in imported presets. Keep assets inside the pack.',
        );
      }
    }
  }

  /// Returns pixels for the aggregate pack budget. No image is decoded here.
  static int imagePixels(String extension, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxImageBytes) {
      throw const FormatException('Texture is empty or exceeds the 16 MiB encoded limit.');
    }
    final data = ByteData.sublistView(bytes);
    int u16(int offset) => data.getUint16(offset, Endian.little);
    int u32(int offset) => data.getUint32(offset, Endian.little);
    int be32(int offset) => data.getUint32(offset, Endian.big);
    bool prefix(List<int> signature) =>
        bytes.length >= signature.length &&
        List.generate(signature.length, (i) => bytes[i] == signature[i]).every((v) => v);
    Never malformed() =>
        throw const FormatException('Texture header is malformed or uses an unsupported image layout.');
    int width = 0, height = 0;
    switch (extension.toLowerCase()) {
      case '.png':
        if (bytes.length < 33 ||
            !prefix([137, 80, 78, 71, 13, 10, 26, 10]) ||
            data.getUint32(8) != 13 ||
            ascii.decode(bytes.sublist(12, 16), allowInvalid: true) != 'IHDR') {
          malformed();
        }
        width = be32(16);
        height = be32(20);
        if (width <= 0 || height <= 0 || width > maxImageDimension ||
            height > maxImageDimension || width * height > maxImagePixels) {
          malformed();
        }
        var animationFrames = 0;
        var frameControls = 0;
        var sawIdat = false;
        var sawImageData = false;
        var sawIend = false;
        var offset = 8;
        while (offset < bytes.length) {
          if (offset + 8 > bytes.length) malformed();
          final length = be32(offset);
          if (length > bytes.length - offset - 12) malformed();
          final dataOffset = offset + 8;
          final end = offset + 12 + length;
          final type = ascii.decode(bytes.sublist(offset + 4, offset + 8), allowInvalid: true);
          switch (type) {
            case 'IHDR':
              if (offset != 8) malformed();
            case 'acTL':
              if (length != 8 || animationFrames != 0 || sawIdat) malformed();
              animationFrames = be32(dataOffset);
              if (animationFrames == 0 || animationFrames > _maxAnimationFrames ||
                  width * height * animationFrames > _maxAnimationPixels) {
                throw const FormatException('Animated PNG exceeds its declared frame or pixel budget.');
              }
            case 'fcTL':
              if (animationFrames == 0 || length != 26) malformed();
              final frameWidth = be32(dataOffset + 4);
              final frameHeight = be32(dataOffset + 8);
              final x = be32(dataOffset + 12);
              final y = be32(dataOffset + 16);
              if (frameWidth == 0 || frameHeight == 0 ||
                  x + frameWidth > width || y + frameHeight > height) {
                malformed();
              }
              frameControls++;
              if (frameControls > animationFrames) malformed();
            case 'IDAT':
              sawIdat = true;
              sawImageData = true;
            case 'fdAT':
              if (animationFrames == 0 || frameControls == 0 || length < 4) malformed();
              sawImageData = true;
            case 'IEND':
              if (length != 0 || end != bytes.length) malformed();
              sawIend = true;
          }
          offset = end;
          if (sawIend) break;
        }
        if (!sawIend || !sawIdat || !sawImageData) malformed();
        if (animationFrames != 0) {
          if (frameControls != animationFrames) malformed();
          return width * height * animationFrames;
        }
        if (frameControls != 0) malformed();
      case '.jpg' || '.jpeg' || '.jfif':
        if (!prefix([0xff, 0xd8])) malformed();
        var offset = 2;
        while (offset + 3 < bytes.length) {
          if (bytes[offset++] != 0xff) malformed();
          while (offset < bytes.length && bytes[offset] == 0xff) {
            offset++;
          }
          if (offset >= bytes.length) malformed();
          final marker = bytes[offset++];
          if (marker == 0xd9 || marker == 0xda) break;
          if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
          if (offset + 2 > bytes.length) malformed();
          final length = data.getUint16(offset);
          if (length < 2 || offset + length > bytes.length) malformed();
          if ({0xc0, 0xc1, 0xc2}.contains(marker)) {
            if (length < 8 || bytes[offset + 2] != 8) malformed();
            height = data.getUint16(offset + 3);
            width = data.getUint16(offset + 5);
            break;
          }
          offset += length;
        }
      case '.bmp':
        if (bytes.length < 54 || !prefix([66, 77]) || u32(14) < 40 || u16(26) != 1) malformed();
        width = data.getInt32(18, Endian.little);
        height = data.getInt32(22, Endian.little).abs();
      case '.tga':
        if (bytes.length < 18 || bytes[1] != 0) {
          malformed();
        }
        final grayscale = {3, 11}.contains(bytes[2]);
        if (grayscale
            ? !{8, 16}.contains(bytes[16])
            : !{2, 10}.contains(bytes[2]) || !{16, 24, 32}.contains(bytes[16])) {
          malformed();
        }
        width = u16(12);
        height = u16(14);
      case '.gif':
        if (bytes.length < 13 || !(prefix(ascii.encode('GIF87a')) || prefix(ascii.encode('GIF89a')))) malformed();
        width = u16(6);
        height = u16(8);
        var offset = 13;
        final screenFlags = bytes[10];
        if ((screenFlags & 0x80) != 0) {
          offset += 3 * (1 << ((screenFlags & 0x07) + 1));
          if (offset > bytes.length) malformed();
        }
        var frames = 0;
        var sawTrailer = false;
        while (offset < bytes.length) {
          final marker = bytes[offset++];
          if (marker == 0x3b) {
            sawTrailer = true;
            break;
          }
          if (marker == 0x2c) {
            if (offset + 9 > bytes.length) malformed();
            final left = u16(offset);
            final top = u16(offset + 2);
            final frameWidth = u16(offset + 4);
            final frameHeight = u16(offset + 6);
            final flags = bytes[offset + 8];
            offset += 9;
            if (frameWidth == 0 || frameHeight == 0 ||
                left + frameWidth > width || top + frameHeight > height) {
              malformed();
            }
            if ((flags & 0x80) != 0) {
              offset += 3 * (1 << ((flags & 0x07) + 1));
              if (offset > bytes.length) malformed();
            }
            if (offset >= bytes.length || bytes[offset] < 2 || bytes[offset] > 8) malformed();
            offset++;
            frames++;
            if (frames > _maxAnimationFrames || width * height * frames > _maxAnimationPixels) {
              throw const FormatException('Animated GIF exceeds its decoded frame or pixel budget.');
            }
            offset = _skipGifSubBlocks(bytes, offset, malformed);
            continue;
          }
          if (marker == 0x21) {
            if (offset >= bytes.length) malformed();
            final label = bytes[offset++];
            if (label == 0xff) {
              if (offset >= bytes.length) malformed();
              final size = bytes[offset++];
              offset += size;
              if (offset > bytes.length) malformed();
            }
            offset = _skipGifSubBlocks(bytes, offset, malformed);
            continue;
          }
          malformed();
        }
        if (!sawTrailer || frames == 0) malformed();
        if (width <= 0 || height <= 0 || width > maxImageDimension || height > maxImageDimension ||
            width * height > maxImagePixels) {
          malformed();
        }
        return width * height * frames;
      case '.dds':
        if (bytes.length < 128 ||
            !prefix(ascii.encode('DDS ')) ||
            u32(4) != 124 ||
            u32(76) != 32 ||
            u32(24) > 1 ||
            u32(28) > 13 ||
            u32(112) != 0) {
          malformed();
        }
        // Only bounded two-dimensional legacy DDS, not cubemaps/arrays/DX10.
        final fourCC = ascii.decode(bytes.sublist(84, 88), allowInvalid: true);
        if ((u32(80) & 4) != 0) {
          if (!{'DXT1', 'DXT3', 'DXT5'}.contains(fourCC)) malformed();
        } else if ((u32(80) & 64) == 0 || !{24, 32}.contains(u32(88))) {
          malformed();
        }
        width = u32(16);
        height = u32(12);
      case '.webp':
        if (bytes.length < 20 ||
            ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
            ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WEBP' ||
            u32(4) + 8 != bytes.length) {
          malformed();
        }
        int? canvasWidth, canvasHeight;
        var seenFrame = false;
        int u24(int offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
        void acceptFrame(int frameWidth, int frameHeight) {
          if (seenFrame ||
              (canvasWidth != null && (canvasWidth != frameWidth || canvasHeight != frameHeight))) {
            malformed();
          }
          width = frameWidth;
          height = frameHeight;
          seenFrame = true;
        }

        var offset = 12;
        while (offset < bytes.length) {
          if (offset + 8 > bytes.length) malformed();
          final kind = ascii.decode(bytes.sublist(offset, offset + 4), allowInvalid: true);
          final length = u32(offset + 4);
          final dataOffset = offset + 8;
          final end = dataOffset + length + (length & 1);
          if (end < dataOffset || end > bytes.length) malformed();
          if (kind == 'ANIM' || kind == 'ANMF') {
            throw const FormatException('Animated WebP textures are not supported. Use a static image or GIF.');
          }
          if (kind == 'VP8X') {
            if (offset != 12 || canvasWidth != null || length != 10) malformed();
            if ((bytes[dataOffset] & 2) != 0) {
              throw const FormatException('Animated WebP textures are not supported. Use a static image or GIF.');
            }
            canvasWidth = u24(dataOffset + 4) + 1;
            canvasHeight = u24(dataOffset + 7) + 1;
            width = canvasWidth;
            height = canvasHeight;
          } else if (kind == 'VP8 ') {
            if (length < 10 ||
                !List.generate(3, (i) => bytes[dataOffset + 3 + i] == [0x9d, 0x01, 0x2a][i]).every((v) => v)) {
              malformed();
            }
            acceptFrame(u16(dataOffset + 6) & 0x3fff, u16(dataOffset + 8) & 0x3fff);
          } else if (kind == 'VP8L') {
            if (length < 5 || bytes[dataOffset] != 0x2f) malformed();
            final packed = u32(dataOffset + 1);
            acceptFrame((packed & 0x3fff) + 1, ((packed >> 14) & 0x3fff) + 1);
          }
          offset = end;
        }
        if (!seenFrame) malformed();
      default:
        throw const FormatException('Unsupported texture format.');
    }
    if (width <= 0 ||
        height <= 0 ||
        width > maxImageDimension ||
        height > maxImageDimension ||
        width * height > maxImagePixels) {
      throw const FormatException('Textures must be at most 4096 pixels per side and 8 megapixels.');
    }
    return width * height;
  }

  static int _skipGifSubBlocks(Uint8List bytes, int offset, Never Function() malformed) {
    while (offset < bytes.length) {
      final length = bytes[offset++];
      if (length == 0) return offset;
      offset += length;
      if (offset > bytes.length) malformed();
    }
    return malformed();
  }
}
