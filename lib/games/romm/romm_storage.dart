import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'romm_client.dart';
import 'romm_models.dart';

/// A profile's downloads and pending saves never share another profile's paths.
/// Manifests are committed after bytes; interrupted writes are recoverable.
class RommStorage extends ChangeNotifier {
  RommStorage({required this.profileId, required this.current, required this.client, required this.connection});
  final String profileId;
  final bool Function() current;
  final Future<RommClient> Function(String) client;
  final RommConnection Function(String) connection;
  Directory? _root;
  final downloads = <String, Map<String, dynamic>>{};
  final pending = <String, Map<String, dynamic>>{};
  final progress = <String, double>{};
  final failures = <String, String>{};
  final _active = <String, RommClient>{};
  final _syncing = <String>{};
  final _syncLineages = <String, Future<void>>{};
  final _saveReservations = <String, int>{};
  final _downloadLocks = <String>{};
  final _uploadedHashes = <String, String>{};
  final _partialSizes = <String, int>{};
  final _partialGames = <String, Map<String, dynamic>>{};
  Iterable<Map<String, dynamic>> get partialGames => _partialGames.values;
  final browserPorts = <String, int>{};
  Future<void> _writes = Future.value();
  static final _owners = <String, RommStorage>{};
  final _tasks = <Future<void>>{};
  Future<T> _track<T>(Future<T> operation) {
    final settled = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _tasks.add(settled);
    unawaited(settled.then((_) { _tasks.remove(settled); }));
    return operation;
  }
  Future<void> _drain() async {
    while (_tasks.isNotEmpty) { await Future.wait(_tasks.toList()); }
  }
  bool _disposed = false;
  int quota = 10 * 1024 * 1024 * 1024;
  bool get live => !_disposed && current();
  void check() { if (!live) throw const RommFailure('romm.cancelled'); }
  void changed() { if (live) notifyListeners(); }
  String _key(String value) => sha256.convert(utf8.encode(value)).toString();
  String _path(String id, String suffix) => '${_root!.path}/${_key(id)}.$suffix';
  int get used => downloads.values.fold<int>(0, (n, row) => n + rommInt(row['size'])) + _partialSizes.values.fold<int>(0, (n, size) => n + size);
  bool available(RommGame game) => downloads[game.key]?['identity'] == game.identity;
  bool hasPartial(RommGame game) => _partialSizes.containsKey(_key(game.key));
  void _requireDownloadRoom(RommGame game) {
    final keys = {...downloads.keys.map(_key), ..._partialSizes.keys, ..._partialGames.keys, ..._reservations.keys.map(_key)};
    if (keys.length >= 2000 && !keys.contains(_key(game.key))) throw const RommFailure('romm.quotaExceeded');
  }
  Future<void> load() => _track(_load());
  Future<void> _load() async {
    final previous = _owners[profileId];
    if (previous != null && !identical(previous, this) && previous.live) throw const RommFailure('romm.busy');
    _owners[profileId] = this;
    // A quick A → B → A switch must not read a manifest before A's old fsync
    // finishes, or let that retired writer replace the new session's manifest.
    if (previous != null && !identical(previous, this)) await previous._drain();
    final support = await getApplicationSupportDirectory(); check();
    _root = await Directory('${support.path}/romm/${_key(profileId)}').create(recursive: true);
    check();
    try {
      final manifest = File('${_root!.path}/manifest.json');
      final exists = await manifest.exists();
      if (exists && await manifest.length() > 16 * 1024 * 1024) throw const RommFailure('romm.responseTooLarge');
      final decoded = exists ? jsonDecode(await manifest.readAsString()) : {'downloads': [], 'pending': []}; check();
      if (decoded is! Map) throw const RommFailure('romm.invalidResponse');
      final data = rommMap(decoded);
      if (data['downloads'] is! List || data['pending'] is! List ||
          rommList(data['downloads']).length > 2000 || rommList(data['pending']).length > 500) throw const RommFailure('romm.invalidResponse');
      for (final e in rommMap(data['browserPorts']).entries) { final port = rommInt(e.value); if (port >= 1024 && port <= 65535) browserPorts[e.key] = port; }
      _uploadedHashes.addAll(rommMap(data['uploadedHashes']).map((key, value) => MapEntry(key, rommString(value, 128))));
      quota = rommInt(data['quota'], quota).clamp(1024 * 1024 * 1024, 1024 * 1024 * 1024 * 1024);
      for (final row in rommList(data['downloads']).take(10000)) {
        final entry = rommMap(row), key = rommString(rommMap(row)['key'], 256);
        if (key.isNotEmpty && await File(_path(key, 'rom')).exists()) downloads[key] = entry;
      }
      for (final row in rommList(data['pending']).take(1000)) {
        final entry = rommMap(row), id = rommString(rommMap(row)['id'], 128);
        if (id.isNotEmpty) pending[id] = entry;
      }
      // Save bytes have their own small atomic journal. Recover a completed
      // byte write even if the aggregate manifest write was interrupted.
      final retired = <String>[];
      var recoveredDownload = false;
      await for (final entity in _root!.list(followLinks: false)) {
        check();
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (RegExp(r'^[0-9a-f]{64}\.part$').hasMatch(name)) {
          final hash = name.substring(0, 64);
          _partialSizes[hash] = await entity.length();
          final resume = File('${_root!.path}/$hash.resume');
          if (await resume.exists() && await resume.length() < 16384) {
            try {
              final data = rommMap(jsonDecode(await resume.readAsString()));
              final key = rommString(data['key'], 256);
              final game = RommGame.fromJson(rommString(data['connectionId'], 128), rommMap(data['game']));
              if (game.id > 0 && game.key == key && _key(key) == hash) _partialGames[hash] = data;
            } on FormatException { /* Its bytes still count against the quota. */ }
          }
          continue;
        }
        if (RegExp(r'^[0-9a-f]{64}\.resume$').hasMatch(name) && await entity.length() < 16384) {
          try {
            final data = rommMap(jsonDecode(await entity.readAsString()));
            final row = rommMap(data['download']), key = rommString(row['key'], 256);
            final game = RommGame.fromJson(rommString(row['connectionId'], 128), rommMap(row['game']));
            if (key.isNotEmpty && game.id > 0 && game.key == key && entity.path == _path(key, 'resume') &&
                !await File(_path(key, 'part')).exists()) {
              final file = File(_path(key, 'rom')), hash = rommHash(row['sha1'], 40);
              if (hash.isNotEmpty && await file.exists() && await file.length() == rommInt(row['size']) &&
                  (await sha1.bind(file.openRead()).first).toString() == hash) {
                downloads[key] = row; recoveredDownload = true;
              }
            }
          } on FormatException { /* An incomplete transfer remains retryable. */ }
          continue;
        }
        if (!entity.path.endsWith('.pending')) continue;
        if (await entity.length() > 65536) throw const RommFailure('romm.invalidFile');
        final row = rommMap(jsonDecode(await entity.readAsString()));
        final id = rommString(row['id'], 128);
        if (id.isEmpty || entity.path != _path(id, 'pending')) throw const RommFailure('romm.invalidFile');
        if (row['retired'] == true) {
          pending.remove(id); retired.add(id);
        } else {
          if (pending.length >= 500 && !pending.containsKey(id)) throw const RommFailure('romm.quotaExceeded');
          pending.putIfAbsent(id, () => row);
        }
      }
      final ordered = pending.entries.toList()..sort((a, b) => rommString(a.value['created']).compareTo(rommString(b.value['created'])));
      pending..clear()..addEntries(ordered);
      for (final entry in pending.entries) {
        final file = File(_path(entry.key, 'save'));
        final next = File(_path(entry.key, 'save.next')), size = rommInt(entry.value['size']);
        // The journal is written before the bytes. A fully flushed temporary
        // payload can be promoted after an interrupted atomic rename.
        if (!await file.exists() && size > 0 && size <= 128 * 1024 * 1024 &&
            await next.exists() && await next.length() == size &&
            (await sha256.bind(next.openRead()).first).toString() == entry.value['hash']) await next.rename(file.path);
        if (!await file.exists() || await file.length() != rommInt(entry.value['size'])) failures[entry.key] = 'romm.checksumFailed';
      }
      check();
      if (retired.isNotEmpty || recoveredDownload) {
        await _persist();
        for (final id in retired) {
          try {
            for (final suffix in ['save', 'pending']) {
              final file = File(_path(id, suffix)); if (await file.exists()) await file.delete();
            }
          } on FileSystemException { /* The tombstone keeps cleanup retryable. */ }
        }
      }
    } on FormatException { throw const RommFailure('romm.invalidResponse'); }
    changed();
  }
  Future<void> _persist({bool completeOwnedWrite = false}) {
    final operation = _writes.catchError((_) {}).then((_) async {
      if (!completeOwnedWrite) check();
      final temp = File('${_root!.path}/manifest.next');
      final bytes = utf8.encode(jsonEncode({'quota': quota, 'uploadedHashes': _uploadedHashes, 'browserPorts': browserPorts, 'downloads': downloads.values.toList(), 'pending': pending.values.toList()}));
      if (bytes.length > 16 * 1024 * 1024) throw const RommFailure('romm.responseTooLarge');
      await temp.writeAsBytes(bytes, flush: true);
      if (!completeOwnedWrite) check();
      await temp.rename('${_root!.path}/manifest.json');
    });
    _writes = operation; return _track(operation);
  }
  Future<void> _journalPending(String id, Map<String, dynamic> row) async {
    final bytes = utf8.encode(jsonEncode(row));
    if (bytes.length > 65536) throw const RommFailure('romm.invalidFile');
    final file = File(_path(id, 'pending.next'));
    await file.writeAsBytes(bytes, flush: true);
    await file.rename(_path(id, 'pending'));
  }
  Future<void> _retirePending(String id) async {
    // Tombstone before removing the manifest entry: a crash during cleanup
    // must not resurrect a successfully uploaded or explicitly discarded save.
    await _journalPending(id, {'id': id, 'retired': true});
    pending.remove(id);
    await _persist(completeOwnedWrite: true);
    for (final suffix in ['save', 'pending']) {
      final file = File(_path(id, suffix)); if (await file.exists()) await file.delete();
    }
    failures.remove(id);
  }
  /// Reserve origins across all profiles, including retired connections, so a
  /// newly assigned loopback port cannot inherit another account's IndexedDB.
  static Future<void> _originWrites = Future.value();
  Future<bool> rememberBrowserPort(String connection, int port) async {
    final result = Completer<bool>();
    _originWrites = _originWrites.catchError((_) {}).then((_) async {
      RandomAccessFile? lock;
      try {
        check();
        final registry = File('${_root!.parent.path}/browser-origins.json');
        // Lock a stable inode; replacing the registry is atomic and must not
        // replace the file whose cross-process lock serializes its writers.
        lock = await File('${registry.path}.lock').open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
        final exists = await registry.exists();
        final size = exists ? await registry.length() : 0;
        if (size > 1024 * 1024) throw const RommFailure('romm.invalidResponse');
        if (exists && size == 0) throw const RommFailure('romm.invalidResponse');
        final decoded = exists ? jsonDecode(await registry.readAsString()) : <String, dynamic>{};
        if (decoded is! Map) throw const RommFailure('romm.invalidResponse');
        final all = rommMap(decoded);
        final reservations = <String, List<int>>{};
        for (final entry in all.entries) {
          final values = entry.value is int ? [entry.value] : entry.value;
          if (values is! List || values.any((p) => p is! int || p < 1024 || p > 65535)) throw const RommFailure('romm.invalidResponse');
          reservations[entry.key] = values.cast<int>();
        }
        final owner = _key('$profileId:$connection');
        if (reservations.entries.any((e) => e.key != owner && e.value.contains(port))) { result.complete(false); return; }
        final ports = reservations.putIfAbsent(owner, () => []);
        if (!ports.contains(port)) ports.add(port);
        final bytes = utf8.encode(jsonEncode(reservations));
        if (bytes.length > 1024 * 1024) throw const RommFailure('romm.responseTooLarge');
        final next = File('${registry.path}.next');
        await next.writeAsBytes(bytes, flush: true); await next.rename(registry.path);
        browserPorts[connection] = port; await _persist(); result.complete(true);
      } catch (error, stack) { result.completeError(error, stack); }
      finally {
        if (lock != null) {
          try { await lock.unlock(); } catch (_) { /* Closing also releases the lock. */ }
          try { await lock.close(); } catch (_) { /* Preserve the registry result. */ }
        }
      }
    });
    return _track(result.future);
  }
  Future<void> setQuota(int bytes) async {
    check(); quota = bytes.clamp(1024 * 1024 * 1024, 1024 * 1024 * 1024 * 1024); await _persist(); changed();
  }
  Future<File> file(RommGame game) => _track(_file(game));
  Future<File> _file(RommGame game) async {
    check();
    if (!_downloadLocks.add(game.key)) throw const RommFailure('romm.busy');
    try {
    if (!available(game)) throw const RommFailure('romm.notFound');
    final row = downloads[game.key]!;
    final file = File(_path(game.key, 'rom'));
    if (!await file.exists() || await file.length() != rommInt(row['size'])) {
      downloads.remove(game.key); await _persist(); throw const RommFailure('romm.checksumFailed');
    }
    if ((await sha1.bind(file.openRead()).first).toString() != row['sha1']) throw const RommFailure('romm.checksumFailed');
    check(); return file;
    } finally { _downloadLocks.remove(game.key); }
  }
  void cancel(String key) { _active.remove(key)?.close(); }
  Future<void> remove(RommGame game) => _track(_remove(game));
  Future<void> _remove(RommGame game) async {
    check(); if (!_downloadLocks.add(game.key)) throw const RommFailure('romm.busy');
    try {
    // Remove recovery metadata first, then bytes, then the manifest row. An
    // interrupted removal must not re-import a completed download journal.
    for (final suffix in ['resume', 'rom', 'part']) {
      final file = File(_path(game.key, suffix)); if (await file.exists()) await file.delete();
    }
    downloads.remove(game.key); await _persist();
    _partialSizes.remove(_key(game.key)); _partialGames.remove(_key(game.key));
    changed();
    } finally { _downloadLocks.remove(game.key); }
  }
  void requireNoPendingWork(String id) {
    check();
    // Keep pending progress reachable through its source until it is synced,
    // exported/deleted, or explicitly resolved by the owner.
    if (pending.values.any((row) => row['connectionId'] == id) || _saveReservations.isNotEmpty) throw const RommFailure('romm.pendingSaves');
    if (_downloadLocks.any((key) => key.startsWith('romm:$id:'))) throw const RommFailure('romm.downloadProgress');
  }
  Future<void> forgetConnectionDownloads(String id) async {
    requireNoPendingWork(id);
    for (final row in downloads.values.where((row) => row['connectionId'] == id).toList()) {
      await remove(RommGame.fromJson(id, rommMap(row['game'])));
    }
    for (final row in _partialGames.values.where((row) => row['connectionId'] == id).toList()) {
      await remove(RommGame.fromJson(id, rommMap(row['game'])));
    }
  }

  /// One exact file, with stable Range validators and server hashes. Multi-file
  /// sets remain playable by the server engines; we never rename a ZIP as a ROM.
  Future<void> download(RommGame game, {RommFile? selected}) => _track(_downloadLocked(game, selected: selected));
  Future<void> _downloadLocked(RommGame game, {RommFile? selected}) async {
    check();
    if (!_downloadLocks.add(game.key)) throw const RommFailure('romm.busy');
    try { await _download(game, selected: selected); }
    finally { _downloadLocks.remove(game.key); _reservations.remove(game.key); }
  }
  Future<void> _download(RommGame game, {RommFile? selected}) async {
    check();
    _requireDownloadRoom(game);
    if (!game.hasBytes) throw const RommFailure('romm.missing');
    if (selected == null && game.files.length > 1) throw const RommFailure('romm.chooseFile');
    if (selected != null && !game.files.any((file) => file.id == selected.id && file.name == selected.name && file.size == selected.size)) throw const RommFailure('romm.copyMismatch');
    final file = selected ?? game.files.firstOrNull;
    final name = file?.name ?? game.fileName, size = file?.size ?? game.size;
    // Reserve all concurrent transfers in the limit, including resumed bytes.
    final key = _key(game.key), existingPartial = _partialSizes[_key(game.key)] ?? 0;
    final reserved = _reservations.values.fold<int>(0, (n, size) => n + size);
    if (size <= 0 || used - existingPartial + size + reserved > quota) throw const RommFailure('romm.quotaExceeded');
    final owner = await client(game.connectionId); check();
    _requireDownloadRoom(game);
    final nowReserved = _reservations.values.fold<int>(0, (n, value) => n + value);
    if (used - existingPartial + size + nowReserved > quota) throw const RommFailure('romm.quotaExceeded');
    _reservations[game.key] = size;
    _partialSizes.remove(key);
    _partialGames[key] = {'key': game.key, 'connectionId': game.connectionId, 'game': _manifestGame(game)};
    final api = RommClient(owner.base, token: owner.token);
    _active[game.key] = api; failures.remove(game.key); progress[game.key] = 0; changed();
    IOSink? sink;
    try {
      final part = File(_path(game.key, 'part')), resume = File(_path(game.key, 'resume'));
      final identity = '${game.identity}:${file?.id ?? 0}:$name:$size';
      Map<String, dynamic> previous = {};
      if (await resume.exists() && await resume.length() < 16384) {
        try { previous = rommMap(jsonDecode(await resume.readAsString())); } on FormatException { /* Restart. */ }
      }
      var offset = await part.exists() ? await part.length() : 0;
      final validator = rommString(previous['validator'], 1024);
      if (previous['identity'] != identity || validator.isEmpty || offset >= size) offset = 0;
      var response = await (await api.open('GET', api.content(game, file: file), headers: {
        if (offset > 0) 'Range': 'bytes=$offset-', if (offset > 0) 'If-Range': validator,
        'Accept-Encoding': 'identity',
      })).close().timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) offset = 0;
      if (response.statusCode != 200 && response.statusCode != 206) throw const RommFailure('romm.connectionFailed');
      if (response.statusCode == 206 && !RegExp('^bytes $offset-[0-9]+/$size\$').hasMatch(response.headers.value('content-range') ?? '')) {
        throw const RommFailure('romm.downloadChanged');
      }
      final etag = response.headers.value('etag') ?? '';
      final nextValidator = etag.isEmpty || etag.startsWith('W/') ? response.headers.value('last-modified') ?? '' : etag;
      if (offset > 0 && nextValidator != validator) {
        await part.delete(); if (await resume.exists()) await resume.delete();
        throw const RommFailure('romm.downloadChanged');
      }
      await resume.writeAsString(jsonEncode({..._partialGames[key]!, 'identity': identity, 'validator': nextValidator}), flush: true);
      sink = part.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
      var received = offset, lastNotify = DateTime.now();
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        check(); api.requireCurrent(); received += chunk.length;
        if (received > size || received > quota) throw const RommFailure('romm.downloadChanged');
        sink.add(chunk);
        if (DateTime.now().difference(lastNotify).inMilliseconds >= 200) {
          progress[game.key] = received / size; changed(); lastNotify = DateTime.now();
          await sink.flush();
        }
      }
      await sink.flush(); await sink.close(); sink = null; check(); api.requireCurrent();
      if (received != size) throw const RommFailure('romm.downloadChanged');
      final sameFile = game.files.length <= 1 && name == game.fileName && size == game.size;
      final expectedSha = file?.sha1.isNotEmpty == true ? file!.sha1 : sameFile ? game.sha1 : '';
      final expectedMd5 = file?.md5.isNotEmpty == true ? file!.md5 : sameFile ? game.md5 : '';
      final actualSha = (await sha1.bind(part.openRead()).first).toString();
      if (expectedSha.isNotEmpty && actualSha != expectedSha ||
          expectedMd5.isNotEmpty && (await md5.bind(part.openRead()).first).toString() != expectedMd5) {
        await part.delete(); throw const RommFailure('romm.checksumFailed');
      }
      check(); api.requireCurrent();
      final row = <String, dynamic>{'key': game.key, 'identity': game.identity, 'size': size, 'name': name,
        'fileId': file?.id, 'sha1': actualSha, 'serverVerified': expectedSha.isNotEmpty || expectedMd5.isNotEmpty,
        'game': _manifestGame(game), 'connectionId': game.connectionId};
      // Recover a successful rename if the process exits before the aggregate
      // manifest is committed. Verify the renamed bytes before trusting it.
      await resume.writeAsString(jsonEncode({..._partialGames[key]!, 'download': row}), flush: true);
      await part.rename(_path(game.key, 'rom'));
      downloads[game.key] = row;
      _reservations.remove(game.key);
      await _persist(); if (await resume.exists()) await resume.delete();
    } catch (error) {
      failures[game.key] = error is RommFailure ? error.code : 'romm.connectionFailed'; rethrow;
    } finally {
      try { await sink?.close(); }
      finally {
        api.close();
        if (identical(_active[game.key], api)) _active.remove(game.key);
        try {
          final part = File(_path(game.key, 'part'));
          if (await part.exists()) _partialSizes[key] = await part.length();
          else { _partialSizes.remove(key); _partialGames.remove(key); }
        } finally { progress.remove(game.key); _reservations.remove(game.key); changed(); }
      }
    }
  }
  final _reservations = <String, int>{};

  /// Fsync bytes before reporting a local save. Every write is a separate version.
  Future<String> enqueue({required RommGame game, required Uint8List bytes, required String emulator,
      required String core, bool state = false, String slot = 'autosave', String baseHash = '', String nativeFileHash = ''}) =>
    _track(_enqueue(game: game, bytes: bytes, emulator: emulator, core: core, state: state, slot: slot, baseHash: baseHash, nativeFileHash: nativeFileHash));
  Future<String> _enqueue({required RommGame game, required Uint8List bytes, required String emulator,
      required String core, required bool state, required String slot, required String baseHash, required String nativeFileHash}) async {
    check();
    if (bytes.isEmpty || bytes.length > 128 * 1024 * 1024 || pending.length + _saveReservations.length >= 500 || game.id <= 0 ||
        !RegExp(r'^[a-zA-Z0-9_.-]{1,50}$').hasMatch(emulator) || !RegExp(r'^[a-zA-Z0-9_.-]{1,255}$').hasMatch(slot) ||
        core.length > 512 || nativeFileHash.isNotEmpty && rommHash(nativeFileHash, 40).isEmpty) throw const RommFailure('romm.invalidFile');
    final pendingBytes = pending.values.fold<int>(0, (n, row) => n + rommInt(row['size'])) + _saveReservations.values.fold<int>(0, (n, size) => n + size);
    if (pendingBytes + bytes.length > 512 * 1024 * 1024) throw const RommFailure('romm.quotaExceeded');
    final source = connection(game.connectionId), id = const Uuid().v4(), created = DateTime.now().toUtc().toIso8601String();
    _saveReservations[id] = bytes.length;
    try {
    final row = <String, dynamic>{'id': id, 'connectionId': game.connectionId, 'userId': source.userId,
      'game': _manifestGame(game), 'identity': game.identity, 'emulator': emulator, 'core': core, 'state': state,
      if (nativeFileHash.isNotEmpty) 'nativeFileHash': nativeFileHash,
      'slot': slot, 'baseHash': _uploadedHashes['${game.key}:$emulator:$slot'] ?? baseHash, 'hash': sha256.convert(bytes).toString(), 'contentHash': bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b ? '' : md5.convert(bytes).toString(), 'size': bytes.length,
      'created': created, 'conflict': false};
    await _journalPending(id, row);
    final file = File(_path(id, 'save.next'));
    await file.writeAsBytes(bytes, flush: true);
    await file.rename(_path(id, 'save'));
    pending[id] = row;
    _saveReservations.remove(id);
    await _persist(completeOwnedWrite: true); changed(); return id;
    } finally { _saveReservations.remove(id); }
  }
  Future<Uint8List> pendingBytes(String id) async {
    check(); final row = pending[id]; if (row == null) throw const RommFailure('romm.notFound');
    final file = File(_path(id, 'save')), size = rommInt(row['size']);
    if (size <= 0 || size > 128 * 1024 * 1024 || !await file.exists() || await file.length() != size) throw const RommFailure('romm.checksumFailed');
    final bytes = await file.readAsBytes(); check();
    if (bytes.length != size || sha256.convert(bytes).toString() != row['hash']) throw const RommFailure('romm.checksumFailed');
    return bytes;
  }
  Future<void> discardPending(String id, {bool useServer = false}) => _track(_discardPending(id, useServer: useServer));
  Future<void> _discardPending(String id, {bool useServer = false}) async {
    check(); if (!_syncing.add(id)) throw const RommFailure('romm.saveInProgress');
    try {
    final row = pending[id];
    if (row == null) return;
    if (useServer && row != null && rommHash(row['nativeFileHash'], 40).isNotEmpty) {
      final game = RommGame.fromJson(rommString(row['connectionId']), rommMap(row['game']));
      final key = '${game.key}:${game.identity}:${row['nativeFileHash']}:${row['core']}';
      for (final suffix in ['sram', 'state', 'progress']) { final cached = File(_path(key, suffix)); if (await cached.exists()) await cached.delete(); }
    }
    await _retirePending(id); changed();
    } finally { _syncing.remove(id); }
  }
  Future<void> sync(String id, {bool keepBoth = false, bool replace = false}) => _track(_sync(id, keepBoth: keepBoth, replace: replace));
  Future<void> _sync(String id, {bool keepBoth = false, bool replace = false}) async {
    check(); if (!_syncing.add(id)) throw const RommFailure('romm.saveInProgress');
    final pendingRow = pending[id];
    if (pendingRow == null) { _syncing.remove(id); return; }
    // Two versions of one slot must be compared and uploaded in order. A
    // per-ID lock alone allows both to compare against the same server head.
    final lineage = '${pendingRow['connectionId']}:${rommMap(pendingRow['game'])['id']}:${pendingRow['state']}:${pendingRow['emulator']}:${pendingRow['slot']}';
    final previous = _syncLineages[lineage] ?? Future<void>.value();
    final released = Completer<void>();
    _syncLineages[lineage] = released.future;
    try {
      await previous; check();
      final row = pending[id]; if (row == null) return;
      if (row['conflict'] == true && !keepBoth && !replace) throw const RommFailure('romm.conflict');
      final source = connection(rommString(row['connectionId']));
      if (source.userId != row['userId']) throw const RommFailure('romm.accountMismatch');
      final api = await client(source.id);
      final game = RommGame.fromJson(source.id, rommMap(row['game']));
      final remote = await api.game(source.id, game.id); check();
      if (remote.identity != row['identity']) throw const RommFailure('romm.copyMismatch');
      final state = row['state'] == true;
      final matches = remote.saves.where((s) => !s.missing && s.userId == source.userId && s.romId == game.id && s.emulator == row['emulator'] && s.slot == row['slot']).toList()
        ..sort((a, b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
      final knownHashes = [row['baseHash'], row['contentHash'], _uploadedHashes['${game.key}:${row['emulator']}:${row['slot']}']]
        .whereType<String>().where((hash) => hash.isNotEmpty).toSet();
      if (!state && !keepBoth && !replace && matches.isNotEmpty && !knownHashes.contains(matches.first.hash)) {
        row['conflict'] = true; await _persist(); throw const RommFailure('romm.conflict');
      }
      final bytes = await pendingBytes(id); check();
      final slot = keepBoth ? 'plezy-$id' : rommString(row['slot'], 255);
      final uploaded = await api.uploadSave(romId: game.id, name: 'plezy-$id.${state ? 'state' : 'srm'}', bytes: bytes,
        emulator: rommString(row['emulator'], 100), core: rommString(row['core'], 100), deviceId: source.deviceId,
        slot: slot, contentHash: rommString(row['contentHash']).isEmpty ? null : row['contentHash'] as String, state: state, overwrite: replace);
      check();
      if (!state) _uploadedHashes['${game.key}:${row['emulator']}:$slot'] = rommString(uploaded['content_hash'], 128);
      while (_uploadedHashes.length > 4096) { _uploadedHashes.remove(_uploadedHashes.keys.first); }
      if (!state && !keepBoth) {
        // Uploading a newer queued version explicitly must not let a later
        // background retry promote an older local version back to the head.
        for (final entry in pending.entries) {
          if (entry.key == id) break;
          final older = entry.value;
          if (older['connectionId'] == row['connectionId'] && rommMap(older['game'])['id'] == game.id &&
              older['state'] != true && older['emulator'] == row['emulator'] && older['slot'] == row['slot']) older['conflict'] = true;
        }
      }
      await _retirePending(id);
    } catch (error) {
      if (error is RommFailure && error.status == 409 && pending[id] != null) { pending[id]!['conflict'] = true; await _persist(); }
      failures[id] = error is RommFailure ? error.code : 'romm.saveUploadFailed'; rethrow;
    } finally {
      released.complete();
      if (identical(_syncLineages[lineage], released.future)) _syncLineages.remove(lineage);
      _syncing.remove(id); changed();
    }
  }
  Future<void> syncAll() async {
    for (final id in pending.keys.toList()) {
      check(); try { await sync(id); } catch (_) { /* Each version retains its failure and bytes. */ }
    }
  }
  Future<void> rememberSaveBaseline(RommGame game, RommSave save) async {
    check();
    if (save.state || save.hash.isEmpty || save.romId != game.id || save.userId != connection(game.connectionId).userId) return;
    _uploadedHashes['${game.key}:${save.emulator}:${save.slot}'] = save.hash;
    while (_uploadedHashes.length > 4096) { _uploadedHashes.remove(_uploadedHashes.keys.first); }
    await _persist();
  }
  // Durable save/download manifests need identity, not artwork, achievement
  // catalogs or thousands of disc-file rows repeated for every saved version.
  Map<String, dynamic> _manifestGame(RommGame game) => {
    'id': game.id, 'platform_id': game.platformId, 'name': game.name,
    'platform_slug': game.platform, 'platform_display_name': game.platformName,
    'fs_name': game.fileName, 'fs_extension': game.extension, 'fs_size_bytes': game.size,
    'sha1_hash': game.sha1, 'md5_hash': game.md5, 'missing_from_fs': game.missing,
    'is_physical': game.physical, 'igdb_id': game.igdbId,
  };
  Future<Directory> nativeDirectory(RommGame game) async {
    check(); return Directory('${_root!.path}/native/${_key(game.key)}').create(recursive: true);
  }
  String _nativeKey(RommGame game, String core, String fileHash) => '${game.key}:${game.identity}:${fileHash.isEmpty ? downloads[game.key]?['sha1'] : fileHash}:$core';
  Future<void> keepNativeProgress(RommGame game, String core, Uint8List bytes, {bool state = false, String fileHash = ''}) =>
    keepNativeSnapshot(game, core, sram: state ? null : bytes, state: state ? bytes : null, fileHash: fileHash);
  Future<void> keepNativeSnapshot(RommGame game, String core, {Uint8List? sram, Uint8List? state, String fileHash = ''}) =>
    _track(_keepNativeSnapshot(game, core, sram: sram, state: state, fileHash: fileHash));
  Future<void> _keepNativeSnapshot(RommGame game, String core, {Uint8List? sram, Uint8List? state, String fileHash = ''}) async {
    check();
    final a = sram?.length ?? 0, b = state?.length ?? 0;
    if (a + b == 0 || a > 128 * 1024 * 1024 || b > 128 * 1024 * 1024) throw const RommFailure('romm.invalidFile');
    final path = _path(_nativeKey(game, core, fileHash), 'progress'), temp = File('$path.next');
    final header = Uint8List(16)..setAll(0, ascii.encode('PLZYPRG1'));
    ByteData.sublistView(header)..setUint32(8, a)..setUint32(12, b);
    final output = await temp.open(mode: FileMode.write);
    try {
      await output.writeFrom(header);
      if (sram != null) await output.writeFrom(sram);
      if (state != null) await output.writeFrom(state);
      await output.flush();
    } finally { await output.close(); }
    check(); await temp.rename(path); // One commit keeps SRAM and state from the same emulated frame.
  }
  Future<({Uint8List? sram, Uint8List? state})> nativeSnapshot(RommGame game, String core, {String fileHash = ''}) async {
    check(); final key = _nativeKey(game, core, fileHash), file = File(_path(key, 'progress'));
    if (!await file.exists()) {
      Future<Uint8List?> legacy(String suffix) async {
        final old = File(_path(key, suffix)); if (!await old.exists()) return null;
        if (await old.length() > 128 * 1024 * 1024) throw const RommFailure('romm.invalidFile');
        final bytes = await old.readAsBytes(); check(); return bytes;
      }
      return (sram: await legacy('sram'), state: await legacy('state'));
    }
    final size = await file.length();
    if (size < 16 || size > 256 * 1024 * 1024 + 16) throw const RommFailure('romm.invalidFile');
    final bytes = await file.readAsBytes(); check();
    if (bytes.length != size || ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != 'PLZYPRG1') throw const RommFailure('romm.invalidFile');
    final header = ByteData.sublistView(bytes), a = header.getUint32(8), b = header.getUint32(12);
    if (a > 128 * 1024 * 1024 || b > 128 * 1024 * 1024 || 16 + a + b != size) throw const RommFailure('romm.invalidFile');
    return (sram: a == 0 ? null : Uint8List.sublistView(bytes, 16, 16 + a),
      state: b == 0 ? null : Uint8List.sublistView(bytes, 16 + a));
  }
  Future<Uint8List?> nativeProgress(RommGame game, String core, {bool state = false, String fileHash = ''}) async {
    final snapshot = await nativeSnapshot(game, core, fileHash: fileHash); return state ? snapshot.state : snapshot.sram;
  }
  @override void dispose() {
    if (_disposed) return;
    _disposed = true; for (final api in _active.values) api.close(); _active.clear(); super.dispose();
  }
}
