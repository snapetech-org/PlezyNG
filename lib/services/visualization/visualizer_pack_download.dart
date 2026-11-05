import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'visualizer_catalog_entry.dart';

/// A partial archive is never an installed pack. Only the store can verify and
/// activate it, after rechecking the current signed catalog.
class VisualizerPackDownload {
  const VisualizerPackDownload({
    required this.identity,
    required this.sha256,
    required this.received,
    required this.total,
    required this.resumable,
  });
  final String identity, sha256;
  final int received, total;
  final bool resumable;
  double get progress => received / total;
}

/// Bounded durable downloads. Opening the library only reads local records;
/// retries require an explicit install action and fresh catalog authorization.
class VisualizerPackDownloader {
  VisualizerPackDownloader(this.directory, this.client);
  final Directory directory;
  final http.Client client;
  static const maxPending = 8;
  static const maxBytes = 32 * 1024 * 1024;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _strongEtag = RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$');

  File _part(String digest) => File(p.join(directory.path, '$digest.part'));
  File _record(String digest) => File(p.join(directory.path, '$digest.json'));
  static String? _etag(String? value) =>
      value != null && value.length <= 1024 && _strongEtag.hasMatch(value) ? value : null;

  Future<Map<String, dynamic>?> _read(String digest) async {
    try {
      final record = _record(digest);
      if (await FileSystemEntity.type(record.path, followLinks: false) != FileSystemEntityType.file ||
          await record.length() > 8192 ||
          await FileSystemEntity.type(_part(digest).path, followLinks: false) != FileSystemEntityType.file) return null;
      final value = jsonDecode(await record.readAsString());
      if (value is! Map<String, dynamic> || value['schema'] != 1 || value['sha256'] != digest ||
          value['identity'] is! String || (value['identity'] as String).length > 161 ||
          value['url'] is! String || (value['url'] as String).length > 1024 ||
          value['bytes'] is! int || value['bytes'] <= 0 || value['bytes'] > maxBytes ||
          (value['etag'] != null && _etag(value['etag'] is String ? value['etag'] as String : null) == null)) return null;
      final length = await _part(digest).length();
      if (length > value['bytes']) return null;
      return value;
    } on Object {
      return null;
    }
  }

  Future<void> _write(String digest, Map<String, Object?> value) async {
    final target = _record(digest), temporary = File('${_record(digest).path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    // A crash in this gap loses resumability, never exposes an unverified pack.
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  Future<void> discard(String digest) async {
    if (!_digest.hasMatch(digest)) throw const FormatException('Invalid download identity.');
    for (final file in [_part(digest), _record(digest), File('${_record(digest).path}.tmp')]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.notFound) {
        await file.delete();
      }
    }
  }

  Future<List<VisualizerPackDownload>> pending() async {
    if (!await directory.exists()) return const [];
    final result = <VisualizerPackDownload>[];
    final records = <File>[];
    await for (final item in directory.list(followLinks: false)) {
      if (item is File && p.basename(item.path).endsWith('.json') && _digest.hasMatch(p.basenameWithoutExtension(item.path))) {
        records.add(item);
      }
    }
    // Keep the newest bounded set after a crash; bytes are bounded per record.
    records.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final retained = <String>{};
    for (final record in records) {
      final digest = p.basenameWithoutExtension(record.path), data = await _read(p.basenameWithoutExtension(record.path));
      if (data == null || result.length >= maxPending) {
        await discard(digest);
        continue;
      }
      retained.add(digest);
      result.add(VisualizerPackDownload(
        identity: data['identity'] as String,
        sha256: digest,
        received: await _part(digest).length(),
        total: data['bytes'] as int,
        resumable: data['etag'] != null,
      ));
    }
    await for (final item in directory.list(followLinks: false)) {
      final name = p.basename(item.path);
      if (item is File && name.endsWith('.part') && _digest.hasMatch(p.basenameWithoutExtension(name)) &&
          !retained.contains(p.basenameWithoutExtension(name))) await item.delete();
      if (item is File && name.endsWith('.json.tmp') && _digest.hasMatch(name.substring(0, name.length - 9))) {
        await item.delete();
      }
    }
    return result;
  }

  Future<File> download(
    VisualizerPackCatalogEntry entry, {
    required Future<void> abortTrigger,
    required void Function() checkCancellation,
    void Function(double)? onProgress,
  }) async {
    if (!_digest.hasMatch(entry.sha256) || entry.archiveBytes <= 0 || entry.archiveBytes > maxBytes) {
      throw const FormatException('Invalid bounded pack download.');
    }
    final uri = Uri.parse(entry.archiveUrl);
    if (uri.scheme != 'https' || uri.host != 'raw.githubusercontent.com' || uri.userInfo.isNotEmpty || uri.hasPort) {
      throw const FormatException('The pack catalog contains an untrusted download host.');
    }
    await directory.create(recursive: true);
    final existing = await pending();
    if (!existing.any((item) => item.sha256 == entry.sha256) && existing.length >= maxPending) {
      await discard(existing.last.sha256);
    }
    var saved = await _read(entry.sha256);
    if (saved != null && (saved['url'] != entry.archiveUrl || saved['bytes'] != entry.archiveBytes ||
        saved['identity'] != entry.identity)) {
      await discard(entry.sha256);
      saved = null;
    }
    final file = _part(entry.sha256);
    var offset = saved == null ? 0 : await file.length();
    checkCancellation();
    // The store still hashes and validates an already downloaded archive.
    if (offset == entry.archiveBytes) return file;
    if (saved?['etag'] == null) offset = 0;
    for (var attempt = 0; attempt < 2; attempt++) {
      checkCancellation();
      final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger)..followRedirects = false;
      request.headers['Accept-Encoding'] = 'identity';
      if (offset > 0) {
        request.headers['Range'] = 'bytes=$offset-';
        request.headers['If-Range'] = saved!['etag'] as String;
      }
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      final tag = _etag(response.headers['etag']);
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(response.headers['content-range'] ?? '');
      final partial = response.statusCode == HttpStatus.partialContent && offset > 0 &&
          tag == saved?['etag'] && range != null && int.tryParse(range[1]!) == offset &&
          int.tryParse(range[2]!) == entry.archiveBytes - 1 && int.tryParse(range[3]!) == entry.archiveBytes;
      if (response.statusCode != HttpStatus.ok && !partial) {
        await response.stream.listen(null).cancel();
        if (offset > 0 && (response.statusCode == HttpStatus.partialContent || response.statusCode == HttpStatus.requestedRangeNotSatisfiable)) {
          await discard(entry.sha256);
          saved = null;
          offset = 0;
          continue;
        }
        throw HttpException('Pack download failed with HTTP ${response.statusCode}.', uri: uri);
      }
      if (!partial) offset = 0; // A changed or unsupported range starts cleanly.
      if ((response.headers['content-encoding'] ?? 'identity').toLowerCase() != 'identity' ||
          (response.contentLength != null && response.contentLength != entry.archiveBytes - offset)) {
        await response.stream.listen(null).cancel();
        await discard(entry.sha256);
        throw const FormatException('The downloaded pack size or encoding does not match its catalog.');
      }
      final handle = await file.open(mode: offset > 0 ? FileMode.append : FileMode.write);
      var received = offset;
      try {
        await _write(entry.sha256, {
          'schema': 1, 'identity': entry.identity, 'sha256': entry.sha256,
          'url': entry.archiveUrl, 'bytes': entry.archiveBytes, 'etag': tag,
        });
        onProgress?.call(received / entry.archiveBytes);
        await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
          checkCancellation();
          if (received + chunk.length > entry.archiveBytes) {
            throw const FormatException('The pack archive exceeds its catalog size.');
          }
          await handle.writeFrom(chunk);
          received += chunk.length;
          onProgress?.call(received / entry.archiveBytes);
        }
      } finally {
        try {
          await handle.flush();
        } finally {
          await handle.close();
        }
      }
      if (received != entry.archiveBytes) throw const HttpException('The downloaded pack is incomplete. Retry to resume.');
      return file;
    }
    throw const HttpException('The server could not provide a valid pack download.');
  }
}
