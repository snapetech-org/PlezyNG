import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../mpv/mpv.dart';
import 'subtitle_retimer.dart';

/// An immutable, bounded copy of a selected native text sidecar. Embedded
/// streams must first use the existing extraction/import path. Credentials and
/// transport locations never enter the exported provenance.
final class SubtitleCueDocument {
  SubtitleCueDocument._(this.bytes, this.extension, this.cues);
  final Uint8List bytes;
  final String extension;
  final List<SubtitleCue> cues;
  String get digest => sha256.convert(bytes).toString();

  static String? format(SubtitleTrack? track) {
    if (track == null || track.isContainer || track.uri?.isNotEmpty != true ||
        const ['no', 'auto'].contains(track.id)) return null;
    final raw = track.uri!;
    final uri = Uri.tryParse(raw);
    final extension = p.extension(uri?.path ?? raw).toLowerCase();
    if (const ['.srt', '.vtt', '.ass', '.ssa'].contains(extension)) return extension;
    return switch (track.codec?.toLowerCase()) {
      'subrip' || 'srt' => '.srt',
      'webvtt' || 'vtt' => '.vtt',
      'ass' => '.ass',
      'ssa' => '.ssa',
      _ => null,
    };
  }

  static Future<SubtitleCueDocument> read(SubtitleTrack track, {required void Function() checkCurrent}) async {
    checkCurrent();
    final extension = format(track);
    if (extension == null) throw const FormatException('Selected subtitle has no inspectable text sidecar.');
    final raw = track.uri!;
    if (raw.length > 16384 || raw.contains('\u0000')) throw const FormatException('Invalid subtitle location.');
    final uri = p.isAbsolute(raw) ? Uri.file(raw) : Uri.tryParse(raw);
    if (uri == null || (uri.hasScheme && !const ['file', 'https', 'http'].contains(uri.scheme))) {
      throw const FormatException('Unsupported subtitle transport.');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    void check() {
      checkCurrent();
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('Subtitle read expired.');
    }
    Future<Uint8List> collect(Stream<List<int>> input, int expected) async {
      if (expected > SubtitleRetimer.maximumInputBytes || expected == 0) {
        throw const FormatException('Subtitle exceeds the cue-inspection size limit.');
      }
      final output = BytesBuilder(copy: false);
      await for (final chunk in input.timeout(const Duration(seconds: 5))) {
        check();
        if (output.length + chunk.length > SubtitleRetimer.maximumInputBytes) {
          throw const FormatException('Subtitle exceeds the cue-inspection size limit.');
        }
        output.add(chunk);
      }
      if (output.isEmpty || (expected >= 0 && output.length != expected)) {
        throw const FormatException('Subtitle changed or was truncated during inspection.');
      }
      return output.takeBytes();
    }
    Uint8List bytes;
    if (!uri.hasScheme || uri.scheme == 'file') {
      final file = File(uri.scheme == 'file' ? uri.toFilePath() : raw);
      final size = await file.length();
      check();
      bytes = await collect(file.openRead(), size);
    } else {
      if (uri.userInfo.isNotEmpty || uri.host.isEmpty) throw const FormatException('Invalid subtitle transport.');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      try {
        var target = uri;
        Uint8List? received;
        for (var attempt = 0; attempt < 4; attempt++) {
          check();
          final request = await client.getUrl(target).timeout(const Duration(seconds: 5));
          request.followRedirects = false;
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          final response = await request.close().timeout(const Duration(seconds: 5));
          check();
          if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null) throw const FormatException('Subtitle redirect has no destination.');
            final next = target.resolve(location);
            // A sidecar's signed query is authority for that origin only. Do not
            // follow a redirect into another host, protocol or authenticated URL.
            if (next.origin != uri.origin || next.userInfo.isNotEmpty) {
              throw const FormatException('Subtitle redirect changed its origin.');
            }
            await response.listen((_) {}).cancel();
            target = next;
            continue;
          }
          if (response.statusCode != 200) throw const FormatException('Subtitle could not be read.');
          received = await collect(response, response.contentLength);
          break;
        }
        if (received == null) throw const FormatException('Subtitle redirected too many times.');
        bytes = received;
      } finally { client.close(force: true); }
    }
    check();
    final cues = SubtitleRetimer.parseCues(sourceBytes: bytes, extension: extension);
    checkCurrent();
    return SubtitleCueDocument._(bytes, extension, List.unmodifiable(cues));
  }

  /// A ZIP avoids writing over the original sidecar and retains the unmodified
  /// source alongside the corrected derivative and its explicit clock mapping.
  Uint8List exportBundle(SubtitleRetimingResult result, {required int delayMs,
      required double rate, required int itemOffsetMs, required String lane}) {
    final manifest = utf8.encode(const JsonEncoder.withIndent('  ').convert({
      'schema': 1, 'type': 'plezyng.subtitle.native-retiming',
      'clock': 'opened-file', 'itemOffsetMs': itemOffsetMs, 'lane': lane,
      'mapping': 'outputMs = sourceMs * rate + delayMs', 'rate': rate, 'delayMs': delayMs,
      'originalSha256': digest, 'correctedSha256': sha256.convert(result.bytes).toString(),
      'format': result.format, 'retimedCueCount': result.retimedCueCount,
      'omittedBeforeZero': result.clippedCueCount,
      'renderingQualified': false,
    }));
    final archive = Archive()
      ..addFile(ArchiveFile('original$extension', bytes.length, bytes))
      ..addFile(ArchiveFile('corrected$extension', result.bytes.length, result.bytes))
      ..addFile(ArchiveFile('provenance.json', manifest.length, manifest));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Mobile document pickers consume bytes themselves; desktop pickers return
  /// a destination. Commit that destination through a recoverable replacement.
  static Future<void> finishExport(String path, Uint8List bytes) async {
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) return;
    if (p.extension(path).toLowerCase() != '.zip') throw const FormatException('A ZIP destination is required.');
    final target = File(path), nonce = DateTime.now().microsecondsSinceEpoch;
    final partial = File('$path.$nonce.pending'), backup = File('$path.$nonce.backup');
    var backedUp = false;
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (await target.exists()) { await target.rename(backup.path); backedUp = true; }
      try { await partial.rename(path); }
      catch (_) { if (backedUp && await backup.exists()) await backup.rename(path); rethrow; }
      if (backedUp) { try { await backup.delete(); } catch (_) {} }
    } finally { if (await partial.exists()) await partial.delete(); }
  }
}
