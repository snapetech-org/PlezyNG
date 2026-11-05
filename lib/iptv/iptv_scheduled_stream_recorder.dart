import 'dart:async';
import 'dart:io';

import 'iptv_hls_archive.dart';

import '../sources/source_transport.dart';

/// Captures direct HTTP streams and AES-128 or clear HLS while PlezyNG is
/// running. HLS is retained as a self-contained local playlist archive so
/// separate renditions and initialization changes remain intact.
class IptvScheduledStreamRecorder {
  IptvScheduledStreamRecorder({
    required this.uri,
    required this.allowHttp,
    this.headers = const {},
    required this.outputFile,
    required this.endsAt,
    this.archiveDirectory,
  });

  final Uri uri;
  final bool allowHttp;
  final Map<String, String> headers;
  final File outputFile;
  final DateTime endsAt;
  final Directory? archiveDirectory;
  IptvHlsArchive? _archive;
  int get archivedMediaBytes => _archive?.mediaBytes ?? 0;

  SourceTransport? _transport;
  StreamSubscription<List<int>>? _subscription;
  Completer<void>? _directDone;
  Timer? _stopTimer;
  bool _stopped = false;
  String _fileExtension = '.ts';
  String get fileExtension => _fileExtension;

  Future<String> record() async {
    if (uri.path.toLowerCase().endsWith('.m3u8')) {
      return _recordHls(uri);
    }
    if (await _recordDirect(uri)) return _recordHls(uri);
    final filename = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final extension = RegExp(
      r'\.(ts|mp2t|m2ts|mp4|m4v|mkv|mp3|aac|m4a|mpg|mpeg|webm)$',
      caseSensitive: false,
    ).firstMatch(filename)?.group(1)?.toLowerCase();
    _fileExtension = extension == null ? '.ts' : '.$extension';
    return _fileExtension;
  }

  Future<void> stop() async {
    _stopped = true;
    _stopTimer?.cancel();
    await _archive?.stop();
    await _subscription?.cancel();
    final directDone = _directDone;
    if (directDone != null && !directDone.isCompleted) directDone.complete();
    _transport?.close();
  }

  Future<bool> _recordDirect(Uri source) async {
    final transport = SourceTransport(allowHttp: allowHttp);
    _transport = transport;
    final response = await transport.send('GET', source, headers: headers, redirects: true);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      SourceTransport.check(response.statusCode);
    }
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('mpegurl') || contentType.contains('x-mpegurl')) {
      await response.stream.drain<void>();
      transport.close();
      _transport = null;
      return true;
    }
    final sink = outputFile.openWrite(mode: FileMode.writeOnly);
    final done = Completer<void>();
    _directDone = done;
    var reachedScheduledEnd = false;
    late final StreamSubscription<List<int>> subscription;
    void finish([Object? error, StackTrace? stackTrace]) {
      if (done.isCompleted) return;
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error, stackTrace ?? StackTrace.current);
      }
    }

    subscription = response.stream.listen(
      (bytes) {
        subscription.pause();
        sink.add(bytes);
        unawaited(sink.flush().then((_) => subscription.resume(), onError: (Object error, StackTrace stackTrace) {
          finish(error, stackTrace);
        }));
      },
      onError: (Object error, StackTrace stackTrace) => finish(error, stackTrace),
      onDone: finish,
      cancelOnError: true,
    );
    _subscription = subscription;
    _stopTimer = Timer(
      endsAt.difference(DateTime.now()).isNegative ? Duration.zero : endsAt.difference(DateTime.now()),
      () {
        reachedScheduledEnd = true;
        _stopped = true;
        unawaited(subscription.cancel().then((_) => finish()));
      },
    );
    try {
      await done.future;
      if (!reachedScheduledEnd && !_stopped && DateTime.now().isBefore(endsAt)) {
        throw const FileSystemException('Stream ended before the scheduled programme ended');
      }
    } finally {
      _stopTimer?.cancel();
      await subscription.cancel();
      await sink.flush();
      await sink.close();
      transport.close();
      _transport = null;
      _directDone = null;
    }
    if (_stopped && await outputFile.length() == 0) throw const FileSystemException('No stream data received');
    return false;
  }

  Future<String> _recordHls(Uri source) async {
    _fileExtension = '.m3u8';
    final archive = IptvHlsArchive(
      uri: source,
      allowHttp: allowHttp,
      headers: headers,
      output: outputFile,
      directory: archiveDirectory ?? Directory('${outputFile.path}.media'),
      endsAt: endsAt,
    );
    _archive = archive;
    await archive.record();
    return _fileExtension;
  }
}
