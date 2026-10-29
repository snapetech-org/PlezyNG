import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// A separate decoder with no audio-output or playback-control operations.
/// Native framework support is format/device-specific; macOS may fall back to
/// the installed FFmpeg executable. All paths are confined to owned transports.
final class SubtitleAnalysisDecoder {
  static const _channel = MethodChannel('com.plezy/subtitle_analysis');
  static bool get available => !const bool.fromEnvironment('PLEZY_TIZEN') && !const bool.fromEnvironment('PLEZY_WEBOS') &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux || Platform.isWindows);
  String? _id;
  Process? _process;
  bool _cancelled = false;
  String backend = 'Separate analysis decoder';

  Future<void> cancel() async {
    _cancelled = true;
    _process?.kill(ProcessSignal.sigkill);
    final id = _id;
    if (id != null) {
      try { await _channel.invokeMethod<void>('cancel', {'id': id}).timeout(const Duration(seconds: 2)); } catch (_) {}
    }
  }

  Future<void> decode({required Uri uri, required int startMs, required int endMs, required int audioOrdinal,
      required File destination, required bool Function() isCurrent}) async {
    if (_id != null) throw StateError('This analysis decoder is already in use');
    if (uri.userInfo.isNotEmpty || uri.hasFragment || !(uri.scheme == 'file' && uri.host.isEmpty || uri.scheme == 'http' && uri.host == '127.0.0.1') ||
        startMs < 0 || endMs <= startMs || endMs > 28800000 || endMs - startMs > 64000 || audioOrdinal < 0 || audioOrdinal > 63) {
      throw const FormatException('Invalid owned media source or bounded analysis window');
    }
    final random = Random.secure();
    final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _id = id; _cancelled = false;
    bool current() { try { return !_cancelled && isCurrent(); } catch (_) { return false; } }
    final guard = Timer.periodic(const Duration(milliseconds: 250), (_) { if (!current()) unawaited(cancel()); });
    try {
      if (!current()) throw StateError('Analysis source changed');
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        try {
          final capabilities = await _channel.invokeMapMethod<String, dynamic>('capabilities').timeout(const Duration(seconds: 3));
          if (capabilities?['version'] != 1) throw UnsupportedError('Native analysis decoder is not installed');
          backend = capabilities?['backend'] as String? ?? 'Native audio decoder';
          final pcm = await _channel.invokeMethod<Uint8List>('decode', {'id': id, 'uri': uri.toString(),
            'startMs': startMs, 'endMs': endMs, 'audioOrdinal': audioOrdinal}).timeout(const Duration(seconds: 95));
          if (!current()) throw StateError('Analysis source changed');
          if (pcm == null || pcm.length != (endMs-startMs)*32) throw const FormatException('Native decoder returned an invalid audio window');
          await destination.writeAsBytes(_wav(pcm), flush: true);
          return;
        } catch (_) {
          try { await _channel.invokeMethod<void>('cancel', {'id': id}).timeout(const Duration(seconds: 2)); } catch (_) {}
          if (!Platform.isMacOS || !current()) rethrow;
        }
      }
      backend = 'FFmpeg separate audio decoder';
      final process = await Process.start(Platform.environment['PLEZY_FFMPEG'] ?? 'ffmpeg', [
        '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-rw_timeout', '20000000',
        '-protocol_whitelist', uri.scheme == 'file' ? 'file,pipe' : 'http,tcp,pipe',
        '-format_whitelist', 'matroska,webm,mov,avi,mp3,wav,flac,ogg,aac,ac3,eac3,mpegts,mpeg',
        '-ss', (startMs/1000).toStringAsFixed(3), '-i', uri.scheme == 'file' ? uri.toFilePath() : uri.toString(),
        '-map', '0:a:$audioOrdinal', '-vn', '-sn', '-t', ((endMs-startMs)/1000).toStringAsFixed(3),
        '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', '-f', 'wav', '-fs', '2100000', destination.path,
      ], runInShell: false);
      _process = process;
      if (!current()) process.kill(ProcessSignal.sigkill);
      final drains = [process.stdout.drain<void>(), process.stderr.drain<void>()];
      final code = await process.exitCode.timeout(const Duration(seconds: 90), onTimeout: () {
        process.kill(ProcessSignal.sigkill); throw TimeoutException('Analysis decoder timed out');
      });
      await Future.wait(drains);
      if (code != 0 || !current()) throw StateError('Analysis decoder failed or its source changed');
    } finally {
      guard.cancel(); _process?.kill(ProcessSignal.sigkill); _process = null; _id = null;
    }
  }
  static Uint8List _wav(Uint8List pcm) {
    final output = Uint8List(44+pcm.length), header = ByteData(44);
    void tag(int offset, String value) { for (var i=0; i<value.length; i++) { header.setUint8(offset+i, value.codeUnitAt(i)); } }
    tag(0,'RIFF'); header.setUint32(4,36+pcm.length,Endian.little); tag(8,'WAVE'); tag(12,'fmt ');
    header.setUint32(16,16,Endian.little); header.setUint16(20,1,Endian.little); header.setUint16(22,1,Endian.little);
    header.setUint32(24,16000,Endian.little); header.setUint32(28,32000,Endian.little); header.setUint16(32,2,Endian.little); header.setUint16(34,16,Endian.little);
    tag(36,'data'); header.setUint32(40,pcm.length,Endian.little);
    output.setRange(0,44,header.buffer.asUint8List()); output.setRange(44,output.length,pcm); return output;
  }
}
