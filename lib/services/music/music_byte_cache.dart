import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../utils/platform_http_client_io.dart' as platform;
import '../../utils/safe_http_redirects.dart';
import '../../utils/serial_future_queue.dart';
import '../../utils/connectivity_link_type.dart';
import '../connectivity_probe.dart';

/// Disposable, complete-file music prefetch. Pinned downloads never enter this
/// directory. Credentials appear only in an in-memory request and its digest;
/// no URL, headers, metadata or account token is written to the cache.
class MusicByteCache {
  MusicByteCache({
    required String scope,
    Future<Directory> Function()? directory,
    http.Client Function()? client,
    Future<bool> Function()? unmetered,
    this.deadline = const Duration(seconds: 45),
  }) : _scope = sha256.convert(utf8.encode(scope)).toString(),
       _directory = directory ?? getTemporaryDirectory,
       _client = client ?? (() => SafeRedirectClient(platform.createPlatformClient())),
       _unmetered = unmetered ?? (() async => (await ConnectivityProbe.check()).hasWifiOrEthernet);

  final String _scope;
  final Future<Directory> Function() _directory;
  final http.Client Function() _client;
  final Future<bool> Function() _unmetered;
  final Duration deadline;
  final SerialFutureQueue _writes = SerialFutureQueue();
  final Map<String, Future<File?>> _pending = {};
  final Set<http.Client> _clients = {};
  int _epoch = 0;
  bool _closed = false;

  Future<Directory> _root() async => Directory('${(await _directory()).path}/music-prefetch/$_scope');
  String _key(String url, Map<String, String>? headers) {
    final fields = (headers ?? const <String, String>{}).entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              url,
              fields.map((e) => [e.key, e.value]).toList(),
            ]),
          ),
        )
        .toString();
  }

  Future<File?> lookup(String url, Map<String, String>? headers, {required bool Function() current}) async {
    if (_closed || !current()) return null;
    final file = File('${(await _root()).path}/${_key(url, headers)}.audio');
    if (!await file.exists() || _closed || !current()) return null;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size == 0 || _closed || !current()) return null;
    await file.setLastModified(DateTime.now());
    return !_closed && current() ? file : null;
  }

  Future<File?> prefetch(
    String url,
    Map<String, String>? headers, {
    required int budgetBytes,
    required bool wifiOnly,
    required bool Function() current,
  }) {
    if (_closed || budgetBytes <= 0 || !current()) return Future.value();
    final uri = Uri.tryParse(url);
    // Playlists and transcoding streams are not complete representations.
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme) || uri.userInfo.isNotEmpty) return Future.value();
    final key = _key(url, headers);
    final existing = _pending[key];
    if (existing != null) return existing;
    final epoch = _epoch;
    late final Future<File?> task;
    task = _writes
        .run(() async {
          bool valid() => !_closed && epoch == _epoch && current();
          if (!valid() || wifiOnly && !await _unmetered() || !valid()) return null;
          try {
            final cached = await lookup(url, headers, current: valid);
            if (cached != null && await cached.length() <= budgetBytes) return cached;
            final root = await _root();
            if (!valid()) return null;
            await root.create(recursive: true);
            await _prune(root, budgetBytes);
            return await _download(root, key, uri, headers, budgetBytes, valid);
          } catch (_) {
            // Disk full, unsupported storage and failed optional prefetch leave
            // the original authorized playback source intact.
            return null;
          }
        })
        .whenComplete(() {
          if (identical(_pending[key], task)) _pending.remove(key);
        });
    _pending[key] = task;
    return task;
  }

  Future<File?> _download(
    Directory root,
    String key,
    Uri uri,
    Map<String, String>? headers,
    int budget,
    bool Function() valid,
  ) async {
    final client = _client();
    _clients.add(client);
    final part = File('${root.path}/$key.part');
    final destination = File('${root.path}/$key.audio');
    final abort = Completer<void>();
    final timer = Timer(deadline, () {
      if (!abort.isCompleted) abort.complete();
      client.close();
    });
    RandomAccessFile? output;
    try {
      final request = http.AbortableRequest('GET', uri, abortTrigger: abort.future)
        ..headers.addAll(headers ?? const {})
        ..headers['Accept-Encoding'] = 'identity';
      final response = await client.send(request).timeout(deadline);
      final type = response.headers['content-type']?.split(';').first.trim().toLowerCase() ?? '';
      if (!valid() ||
          response.statusCode != 200 ||
          !(type.startsWith('audio/') || const {'application/octet-stream', 'binary/octet-stream'}.contains(type)) ||
          type.contains('mpegurl') ||
          type.contains('playlist') ||
          (response.contentLength ?? 0) > budget) {
        await response.stream.listen(null).cancel();
        return null;
      }
      // Reserve the complete representation before writing. Unknown lengths
      // reserve the whole quota, keeping partial + completed files bounded.
      await _prune(root, budget - (response.contentLength ?? budget));
      output = await part.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in response.stream.timeout(deadline)) {
        received += chunk.length;
        if (!valid() || abort.isCompleted || received > budget) return null;
        await output.writeFrom(chunk);
      }
      if (!valid() ||
          abort.isCompleted ||
          received == 0 ||
          response.contentLength != null && received != response.contentLength) {
        return null;
      }
      await output.close();
      output = null;
      if (!valid()) return null;
      return await part.rename(destination.path);
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      client.close();
      _clients.remove(client);
      await output?.close();
      if (await part.exists()) await part.delete();
    }
  }

  Future<void> _prune(Directory root, int budget) async {
    final entries = <(File, FileStat)>[];
    var size = 0;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! File) continue;
      if (entry.path.endsWith('.part')) {
        await entry.delete();
      } else if (entry.path.endsWith('.audio')) {
        final stat = await entry.stat();
        entries.add((entry, stat));
        size += stat.size;
      }
    }
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in entries) {
      if (size <= budget) break;
      await file.delete();
      size -= stat.size;
    }
  }

  /// Profile teardown aborts traffic before queued writes can promote bytes.
  void dispose() {
    _closed = true;
    _epoch++;
    for (final client in _clients.toList()) {
      client.close();
    }
  }

  Future<void> clear() {
    _epoch++;
    for (final client in _clients.toList()) {
      client.close();
    }
    return _writes.run(() async {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
    });
  }
}
