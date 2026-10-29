import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'subtitle_analysis_source.dart';

/// Stages an explicitly chosen owned source for the upload-only companion.
/// Source renewal/credentials stay behind the existing loopback gateway. This
/// never submits a remote URL to the companion or changes the audible player.
abstract final class SubtitleSourceUpload {
  static const maximumBytes = 1024 * 1024 * 1024;
  static Future<({File file, int timelineOffsetMs})> stage(SubtitleAnalysisSource source, {
    required bool Function() isCurrent, void Function(int bytes, int? total)? onProgress,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    File? target;
    RandomAccessFile? output;
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    var complete = false;
    bool current() {
      try { return isCurrent() && source.isCurrent() && DateTime.now().isBefore(deadline); }
      catch (_) { return false; }
    }
    final timer = Timer.periodic(const Duration(milliseconds: 250), (_) { if (!current()) client.close(force: true); });
    try {
      if (!current()) throw StateError('Source copy cancelled');
      if (source.durationMs != null && source.durationMs! > 3600000) throw UnsupportedError('The companion accepts an opened media file up to one hour');
      if (source.timelineOffsetMs < 0 || source.timelineOffsetMs > 7 * 3600000) throw UnsupportedError('Source time offset exceeds the companion bound');
      final root = await getTemporaryDirectory();
      target = File(p.join(root.path, 'plezy_companion_source_${const Uuid().v4()}.media'));
      Stream<List<int>> stream;
      int? total;
      File? local;
      FileStat? stat;
      if (source.uri.scheme == 'file') {
        local = File.fromUri(source.uri); stat = await local.stat();
        if (stat.type != FileSystemEntityType.file || stat.size <= 0 || stat.size > maximumBytes) throw const FormatException('Choose a media file up to 1 GiB');
        total = stat.size; stream = local.openRead();
      } else {
        final address = InternetAddress.tryParse(source.uri.host);
        if (source.uri.scheme != 'http' || address?.isLoopback != true || source.uri.userInfo.isNotEmpty) {
          throw UnsupportedError('The source must expose its owned local analysis gateway');
        }
        final request = await client.getUrl(source.uri);
        request.followRedirects = false;
        final response = await request.close().timeout(const Duration(seconds: 20));
        if (response.statusCode != HttpStatus.ok || response.contentLength > maximumBytes) throw const FormatException('Source is unavailable or exceeds 1 GiB');
        total = response.contentLength >= 0 ? response.contentLength : null;
        final type = response.headers.contentType?.mimeType.toLowerCase();
        if (type == 'application/vnd.apple.mpegurl' || type == 'application/x-mpegurl' || type == 'application/dash+xml') {
          throw UnsupportedError('Playlist sources need a media decoder; only a complete file can be uploaded');
        }
        stream = response;
      }
      output = await target.open(mode: FileMode.writeOnly);
      var bytes = 0;
      var nextProgress = DateTime.now();
      await for (final chunk in stream.timeout(const Duration(seconds: 20))) {
        if (!current()) throw StateError('Source copy cancelled or playback changed');
        bytes += chunk.length;
        if (bytes > maximumBytes) throw const FormatException('Source copy exceeds 1 GiB');
        await output.writeFrom(chunk);
        if (!DateTime.now().isBefore(nextProgress)) {
          onProgress?.call(bytes, total); nextProgress = DateTime.now().add(const Duration(milliseconds: 250));
        }
      }
      if (bytes == 0 || total != null && bytes != total || !current()) throw StateError('Source copy is incomplete');
      if (local != null) {
        final after = await local.stat();
        if (after.type != FileSystemEntityType.file || after.size != stat!.size || after.modified != stat!.modified) throw StateError('The media file changed during copying');
      }
      await output.flush(); await output.close(); output = null;
      onProgress?.call(bytes, bytes);
      complete = true;
      return (file: target, timelineOffsetMs: source.timelineOffsetMs);
    } finally {
      timer.cancel(); client.close(force: true);
      try { await output?.close(); } catch (_) {}
      if (!complete) { try { await target?.delete(); } catch (_) {} }
      try { await source.close(); } catch (_) {}
    }
  }
}
