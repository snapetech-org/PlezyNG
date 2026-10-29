import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'subtitle_analysis_source.dart';

/// OpenSubtitles' size/first/last-block fingerprint, never a content digest.
/// Only owned files and an owning adapter's loopback capability are accepted.
final class SubtitleMovieHash {
  static const _block = 64 * 1024;
  static const _budget = Duration(seconds: 8);

  static Future<({String movieHash, int fileSize})?> read({
    required int fileSize,
    required bool Function() isCurrent,
    required Future<SubtitleAnalysisSource> Function() open,
  }) async {
    if (fileSize < 2 * _block || fileSize > 9007199254740991 || !isCurrent()) return null;
    final clock = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3)..autoUncompress = false;
    SubtitleAnalysisSource? source;
    var retired = false;
    bool current() => !retired && clock.elapsed < _budget && isCurrent() && (source?.isCurrent() ?? true);
    void retire() {
      retired = true;
      client.close(force: true);
    }
    Future<T> bounded<T>(Future<T> value) {
      final remaining = _budget - clock.elapsed;
      if (!current() || remaining <= Duration.zero) {
        // Consume late errors from work which already started.
        unawaited(value.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
        throw StateError('Fingerprint source retired.');
      }
      return value.timeout(remaining);
    }
    final deadline = Timer(_budget, retire);
    final ownership = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!current()) retire();
    });
    try {
      source = await bounded(open().then((lease) async {
        if (!current()) {
          await lease.close();
          throw StateError('Fingerprint lease arrived after its deadline.');
        }
        return lease;
      }));
      final lease = source!;
      final uri = lease.uri;
      final blocks = <Uint8List>[];
      if (uri.scheme == 'file') {
        final file = File.fromUri(uri);
        final before = await bounded(file.stat());
        if (before.type != FileSystemEntityType.file || before.size != fileSize) return null;
        final input = await bounded(file.open(mode: FileMode.read).then((handle) async {
          if (!current()) {
            await handle.close();
            throw StateError('Fingerprint file opened after its deadline.');
          }
          return handle;
        }));
        try {
          for (final offset in [0, fileSize - _block]) {
            await bounded(input.setPosition(offset));
            final bytes = BytesBuilder(copy: false);
            while (bytes.length < _block) {
              final part = await bounded(input.read(_block - bytes.length));
              if (part.isEmpty || !current()) return null;
              bytes.add(part);
            }
            blocks.add(bytes.takeBytes());
          }
          if (await bounded(input.length()) != fileSize) return null;
          final after = await bounded(file.stat());
          if (after.type != before.type || after.size != before.size ||
              after.modified != before.modified || after.changed != before.changed) return null;
        } finally {
          await input.close();
        }
      } else {
        if (uri.scheme != 'http' || !const {'127.0.0.1', '::1'}.contains(uri.host) ||
            uri.userInfo.isNotEmpty || uri.hasFragment || uri.hasQuery) return null;
        String? etag, modified;
        for (final offset in [0, fileSize - _block]) {
          final request = await bounded(client.getUrl(uri));
          request.followRedirects = false;
          request.maxRedirects = 0;
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + _block - 1}');
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          try {
            final response = await bounded(request.close());
            final range = response.headers.value(HttpHeaders.contentRangeHeader);
            final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
            if (!current() || response.statusCode != HttpStatus.partialContent ||
                range != 'bytes $offset-${offset + _block - 1}/$fileSize' ||
                response.contentLength != -1 && response.contentLength != _block ||
                encoding != null && encoding.toLowerCase() != 'identity') return null;
            final nextEtag = response.headers.value(HttpHeaders.etagHeader);
            final nextModified = response.headers.value(HttpHeaders.lastModifiedHeader);
            if (blocks.isNotEmpty && (nextEtag != etag || nextModified != modified)) return null;
            etag = nextEtag;
            modified = nextModified;
            final bytes = BytesBuilder(copy: false);
            await bounded(() async {
              await for (final part in response) {
                if (!current() || bytes.length + part.length > _block) {
                  throw const FormatException('Fingerprint range exceeded its bound.');
                }
                bytes.add(part);
              }
            }());
            if (bytes.length != _block || !current()) return null;
            blocks.add(bytes.takeBytes());
          } finally {
            request.abort();
          }
        }
      }
      if (!current() || blocks.length != 2) return null;
      final mask = (BigInt.one << 64) - BigInt.one;
      var hash = BigInt.from(fileSize);
      for (final bytes in blocks) {
        final words = ByteData.sublistView(bytes);
        for (var at = 0; at < _block; at += 8) {
          // Avoid a signed 64-bit intermediate on native Dart targets.
          final word = BigInt.from(words.getUint32(at, Endian.little)) |
              (BigInt.from(words.getUint32(at + 4, Endian.little)) << 32);
          hash = (hash + word) & mask;
        }
      }
      return (movieHash: hash.toRadixString(16).padLeft(16, '0'), fileSize: fileSize);
    } on Object {
      // Optional precision: ordinary title/ID search remains available.
      return null;
    } finally {
      retire();
      deadline.cancel();
      ownership.cancel();
      try { await source?.close(); } on Object { /* Best-effort capability release. */ }
    }
  }
}
