import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Bounded streaming PCM reader shared by ASR, waveform analysis, and preprocessing.
final class SubtitleWavReader {
  SubtitleWavReader._({
    required this.file,
    required this.dataOffset,
    required this.dataBytes,
    required this.sampleRate,
    required this.channels,
    required this.blockAlign,
    required this.format,
    required this.bitsPerSample,
  });

  final RandomAccessFile file;
  final int dataOffset;
  final int dataBytes;
  final int sampleRate;
  final int channels;
  final int blockAlign;
  final int format;
  final int bitsPerSample;

  int get sourceFrames => dataBytes ~/ blockAlign;
  int get outputFrames => (sourceFrames * 16000) ~/ sampleRate;
  int get durationMs => (sourceFrames * 1000) ~/ sampleRate;

  static Future<SubtitleWavReader> open(String path) async {
    final file = await File(path).open(mode: FileMode.read);
    try {
      final fileLength = await file.length();
      if (fileLength < 44 || fileLength > 1024 * 1024 * 1024) {
        throw const FormatException('WAV input must be between 44 bytes and 1 GiB.');
      }
      final header = await _readExact(file, 12);
      if (ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
          ascii.decode(header.sublist(8, 12), allowInvalid: true) != 'WAVE') {
        throw const FormatException('Choose a standard RIFF/WAVE audio file.');
      }

      var sampleRate = 0;
      var channels = 0;
      var blockAlign = 0;
      var bitsPerSample = 0;
      var format = 0;
      var dataOffset = -1;
      var dataBytes = -1;

      while (await file.position() + 8 <= fileLength) {
        final chunkHeader = await _readExact(file, 8);
        final chunkName = ascii.decode(chunkHeader.sublist(0, 4), allowInvalid: true);
        final chunkSize = ByteData.sublistView(chunkHeader).getUint32(4, Endian.little);
        final contentStart = await file.position();
        if (chunkSize > fileLength || contentStart + chunkSize > fileLength) {
          throw const FormatException('WAV contains an invalid chunk length.');
        }

        if (chunkName == 'fmt ') {
          if (chunkSize < 16 || chunkSize > 4096) throw const FormatException('WAV format chunk is invalid.');
          final fmt = await _readExact(file, chunkSize);
          final data = ByteData.sublistView(fmt);
          format = data.getUint16(0, Endian.little);
          channels = data.getUint16(2, Endian.little);
          sampleRate = data.getUint32(4, Endian.little);
          blockAlign = data.getUint16(12, Endian.little);
          bitsPerSample = data.getUint16(14, Endian.little);
        } else if (chunkName == 'data') {
          dataOffset = contentStart;
          dataBytes = chunkSize;
        }

        final next = contentStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
        if (await file.position() != next) await file.setPosition(next);
        if (sampleRate != 0 && dataOffset >= 0) break;
      }

      final supported = format == 1 && const {8, 16, 24, 32}.contains(bitsPerSample) ||
          format == 3 && const {32, 64}.contains(bitsPerSample);
      if (!supported || channels < 1 || channels > 8) {
        throw const FormatException('Use uncompressed PCM or IEEE float WAV audio with up to eight channels.');
      }
      if (sampleRate < 8000 || sampleRate > 192000 || blockAlign != channels * (bitsPerSample ~/ 8) || dataBytes <= 0) {
        throw const FormatException('WAV sample rate or audio data is invalid.');
      }

      final reader = SubtitleWavReader._(
        file: file,
        dataOffset: dataOffset,
        dataBytes: dataBytes - (dataBytes % blockAlign),
        sampleRate: sampleRate,
        channels: channels,
        blockAlign: blockAlign,
        format: format,
        bitsPerSample: bitsPerSample,
      );
      final totalMs = reader.durationMs;
      if (totalMs <= 0 || totalMs > 8 * 60 * 60 * 1000) {
        throw const FormatException('WAV duration must be between one millisecond and eight hours.');
      }
      return reader;
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  Future<void> forEachMono16kChunk(
    Future<void> Function(Float32List samples) callback, {
    required int startMs,
    required int endMs,
  }) async {
    if (startMs < 0 || endMs <= startMs || endMs > durationMs) {
      throw const FormatException('The WAV interval must be inside its audio duration.');
    }
    const outputChunkFrames = 16000;
    final firstOutputFrame = ((startMs * 16000) ~/ 1000)
        .clamp(0, outputFrames)
        .toInt();
    final endOutputFrame = ((endMs * 16000 + 999) ~/ 1000)
        .clamp(firstOutputFrame, outputFrames)
        .toInt();
    for (var outputStart = firstOutputFrame; outputStart < endOutputFrame; outputStart += outputChunkFrames) {
      final count = (endOutputFrame - outputStart).clamp(0, outputChunkFrames).toInt();
      if (count == 0) break;
      final sourceStart = (outputStart * sampleRate) ~/ 16000;
      final lastPosition = ((outputStart + count - 1) * sampleRate) / 16000;
      final sourceEnd = (lastPosition.floor() + 2).clamp(sourceStart + 1, sourceFrames).toInt();
      final frameCount = sourceEnd - sourceStart;

      await file.setPosition(dataOffset + sourceStart * blockAlign);
      final bytes = await _readExact(file, frameCount * blockAlign);
      final view = ByteData.sublistView(bytes);
      double monoAt(int frame) {
        var total = 0.0;
        for (var channel = 0; channel < channels; channel++) {
          final offset = frame * blockAlign + channel * (bitsPerSample ~/ 8);
          double value;
          if (format == 3) {
            value = bitsPerSample == 32 ? view.getFloat32(offset, Endian.little) : view.getFloat64(offset, Endian.little);
          } else {
            value = switch (bitsPerSample) {
              8 => (view.getUint8(offset) - 128) / 128.0,
              16 => view.getInt16(offset, Endian.little) / 32768.0,
              24 => ((view.getUint8(offset) | (view.getUint8(offset + 1) << 8) |
                  (view.getInt8(offset + 2) << 16))) / 8388608.0,
              _ => view.getInt32(offset, Endian.little) / 2147483648.0,
            };
          }
          total += value.isFinite ? value.clamp(-1.0, 1.0) : 0.0;
        }
        return total / channels;
      }

      final output = Float32List(count);
      for (var index = 0; index < count; index++) {
        final sourcePosition = ((outputStart + index) * sampleRate / 16000) - sourceStart;
        final lower = sourcePosition.floor().clamp(0, frameCount - 1).toInt();
        final upper = (lower + 1).clamp(0, frameCount - 1).toInt();
        final fraction = (sourcePosition - lower).clamp(0.0, 1.0);
        final first = monoAt(lower);
        final second = monoAt(upper);
        output[index] = (first + (second - first) * fraction).clamp(-1.0, 1.0);
      }
      await callback(output);
    }
  }

  Future<void> close() => file.close();
}

Future<Uint8List> _readExact(RandomAccessFile file, int count) async {
  final bytes = BytesBuilder(copy: false);
  var read = 0;
  while (read < count) {
    final chunk = await file.read(count - read);
    if (chunk.isEmpty) throw const FormatException('WAV ended unexpectedly.');
    bytes.add(chunk);
    read += chunk.length;
  }
  return bytes.takeBytes();
}
