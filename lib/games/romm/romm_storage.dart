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
  Future<void> _writes = Future.value();
  bool _disposed = false;
  int quota = 10 * 1024 * 1024 * 1024;
  bool get live => !_disposed && current();
  void check() { if (!live) throw const RommFailure('romm.cancelled'); }
  void changed() { if (live) notifyListeners(); }
  String _key(String value) => sha256.convert(utf8.encode(value)).toString();
  String _path(String id, String suffix) => '${_root!.path}/${_key(id)}.$suffix';
  int get used => downloads.values.fold(0, (n, row) => n + rommInt(row['size']));
  bool available(RommGame game) => downloads[game.key]?['identity'] == game.identity;
  Future<void> load() async {
    final support = await getApplicationSupportDirectory(); check();
    _root = await Directory('${support.path}/romm/${_key(profileId)}').create(recursive: true);
    try {
      final manifest = File('${_root!.path}/manifest.json');
      if (await manifest.length() > 8 * 1024 * 1024) return;
      final data = rommMap(jsonDecode(await manifest.readAsString())); check();
      quota = rommInt(data['quota'], quota).clamp(1024 * 1024 * 1024, 1024 * 1024 * 1024 * 1024);
      for (final row in rommList(data['downloads']).take(10000)) {
        final entry = rommMap(row), key = rommString(rommMap(row)['key'], 256);
        if (key.isNotEmpty && await File(_path(key, 'rom')).exists()) downloads[key] = entry;
      }
      for (final row in rommList(data['pending']).take(1000)) {
        final entry = rommMap(row), id = rommString(rommMap(row)['id'], 128);
        if (id.isNotEmpty && await File(_path(id, 'save')).exists()) pending[id] = entry;
      }
    } on FileSystemException { /* First launch or interrupted manifest. */ }
      on FormatException { /* Preserve orphan bytes; never guess their owner. */ }
    changed();
  }
  Future<void> _persist() {
    final operation = _writes.catchError((_) {}).then((_) async {
      check();
      final temp = File('${_root!.path}/manifest.next');
      await temp.writeAsString(jsonEncode({'quota': quota, 'downloads': downloads.values.toList(), 'pending': pending.values.toList()}), flush: true);
      check(); await temp.rename('${_root!.path}/manifest.json');
    });
    _writes = operation; return operation;
  }
  Future<void> setQuota(int bytes) async {
    check(); quota = bytes.clamp(1024 * 1024 * 1024, 1024 * 1024 * 1024 * 1024); await _persist(); changed();
  }
  Future<File> file(RommGame game) async {
    check();
    if (!available(game)) throw const RommFailure('romm.notFound');
    final file = File(_path(game.key, 'rom'));
    if (!await file.exists() || await file.length() != rommInt(downloads[game.key]!['size'])) {
      downloads.remove(game.key); await _persist(); throw const RommFailure('romm.checksumFailed');
    }
    return file;
  }
  void cancel(String key) { _active.remove(key)?.close(); }
  Future<void> remove(RommGame game) async {
    check(); cancel(game.key); downloads.remove(game.key); await _persist();
    for (final suffix in ['rom', 'part', 'resume']) {
      final file = File(_path(game.key, suffix)); if (await file.exists()) await file.delete();
    }
    changed();
  }

  /// One exact file, with stable Range validators and server hashes. Multi-file
  /// sets remain playable by the server engines; we never rename a ZIP as a ROM.
  Future<void> download(RommGame game, {RommFile? selected}) async {
    check(); if (_active.containsKey(game.key)) return;
    if (!game.hasBytes) throw const RommFailure('romm.missing');
    if (selected == null && game.files.length > 1) throw const RommFailure('romm.chooseFile');
    final file = selected ?? game.files.firstOrNull;
    final name = file?.name ?? game.fileName, size = file?.size ?? game.size;
    final existingSize = rommInt(downloads[game.key]?['size']);
    // Reserve all concurrent transfers in the limit, including resumed bytes.
    final reserved = progress.keys.where((k) => k != game.key).fold<int>(0, (n, k) => n + rommInt(_reservations[k]));
    if (size <= 0 || used - existingSize + size + reserved > quota) throw const RommFailure('romm.quotaExceeded');
    final owner = await client(game.connectionId); check();
    final api = RommClient(owner.base, token: owner.token);
    _active[game.key] = api; _reservations[game.key] = size; failures.remove(game.key); progress[game.key] = 0; changed();
    IOSink? sink;
    try {
      final part = File(_path(game.key, 'part')), resume = File(_path(game.key, 'resume'));
      final identity = '${game.identity}:${file?.id ?? 0}:$name:$size';
      Map<String, dynamic> previous = {};
      if (await resume.exists() && await resume.length() < 4096) {
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
      final nextValidator = etag.startsWith('W/') ? response.headers.value('last-modified') ?? '' : etag;
      await resume.writeAsString(jsonEncode({'identity': identity, 'validator': nextValidator}), flush: true);
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
      final expectedSha = (file?.sha1 ?? game.sha1).toLowerCase(), expectedMd5 = (file?.md5 ?? game.md5).toLowerCase();
      final actualSha = (await sha1.bind(part.openRead()).first).toString();
      if (expectedSha.isNotEmpty && actualSha != expectedSha ||
          expectedMd5.isNotEmpty && (await md5.bind(part.openRead()).first).toString() != expectedMd5) {
        await part.delete(); throw const RommFailure('romm.checksumFailed');
      }
      check(); api.requireCurrent();
      await part.rename(_path(game.key, 'rom'));
      downloads[game.key] = {'key': game.key, 'identity': game.identity, 'size': size, 'name': name,
        'fileId': file?.id, 'sha1': actualSha, 'serverVerified': expectedSha.isNotEmpty || expectedMd5.isNotEmpty,
        'game': game.toJson(), 'connectionId': game.connectionId};
      await _persist(); if (await resume.exists()) await resume.delete();
    } catch (error) {
      failures[game.key] = error is RommFailure ? error.code : 'romm.connectionFailed'; rethrow;
    } finally {
      await sink?.close(); api.close();
      if (identical(_active[game.key], api)) _active.remove(game.key);
      progress.remove(game.key); _reservations.remove(game.key); changed();
    }
  }
  final _reservations = <String, int>{};

  /// Fsync bytes before reporting a local save. Every write is a separate version.
  Future<String> enqueue({required RommGame game, required Uint8List bytes, required String emulator,
      required String core, bool state = false, String slot = 'autosave', String baseHash = ''}) async {
    check();
    if (bytes.isEmpty || bytes.length > 128 * 1024 * 1024 || pending.length >= 500) throw const RommFailure('romm.invalidFile');
    final pendingBytes = pending.values.fold<int>(0, (n, row) => n + rommInt(row['size']));
    if (pendingBytes + bytes.length > 512 * 1024 * 1024) throw const RommFailure('romm.quotaExceeded');
    final source = connection(game.connectionId), id = const Uuid().v4();
    final file = File(_path(id, 'save'));
    await file.writeAsBytes(bytes, flush: true); check();
    pending[id] = {'id': id, 'connectionId': game.connectionId, 'userId': source.userId,
      'game': game.toJson(), 'identity': game.identity, 'emulator': emulator, 'core': core, 'state': state,
      'slot': slot, 'baseHash': baseHash, 'hash': sha256.convert(bytes).toString(), 'contentHash': md5.convert(bytes).toString(), 'size': bytes.length,
      'created': DateTime.now().toUtc().toIso8601String(), 'conflict': false};
    await _persist(); changed(); return id;
  }
  Future<Uint8List> pendingBytes(String id) async {
    check(); final row = pending[id]; if (row == null) throw const RommFailure('romm.notFound');
    final bytes = await File(_path(id, 'save')).readAsBytes(); check();
    if (sha256.convert(bytes).toString() != row['hash']) throw const RommFailure('romm.checksumFailed');
    return bytes;
  }
  Future<void> discardPending(String id) async {
    check(); if (_syncing.contains(id)) throw const RommFailure('romm.busy');
    pending.remove(id); await _persist(); final file = File(_path(id, 'save'));
    if (await file.exists()) await file.delete(); changed();
  }
  Future<void> sync(String id, {bool keepBoth = false, bool replace = false}) async {
    check(); if (!_syncing.add(id)) return;
    try {
      final row = pending[id]; if (row == null) return;
      final source = connection(rommString(row['connectionId']));
      if (source.userId != row['userId']) throw const RommFailure('romm.accountMismatch');
      final api = await client(source.id);
      final game = RommGame.fromJson(source.id, rommMap(row['game']));
      final remote = await api.game(source.id, game.id); check();
      if (remote.identity != row['identity']) throw const RommFailure('romm.copyMismatch');
      final state = row['state'] == true;
      final matches = remote.saves.where((s) => s.emulator == row['emulator'] && s.slot == row['slot']).toList()
        ..sort((a, b) => (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)));
      if (!state && !keepBoth && !replace && matches.isNotEmpty &&
          matches.first.hash != row['baseHash'] && matches.first.hash != row['contentHash']) {
        row['conflict'] = true; await _persist(); throw const RommFailure('romm.conflict');
      }
      final bytes = await pendingBytes(id); check();
      final slot = keepBoth ? 'plezy-${id.substring(0, 8)}' : rommString(row['slot'], 100);
      await api.uploadSave(romId: game.id, name: 'plezy-$id.${state ? 'state' : 'srm'}', bytes: bytes,
        emulator: rommString(row['emulator'], 100), core: rommString(row['core'], 100), deviceId: source.deviceId,
        slot: slot, contentHash: row['contentHash'] as String, state: state, overwrite: replace);
      check(); pending.remove(id); await _persist(); await File(_path(id, 'save')).delete(); failures.remove(id);
    } catch (error) {
      failures[id] = error is RommFailure ? error.code : 'romm.saveUploadFailed'; rethrow;
    } finally { _syncing.remove(id); changed(); }
  }
  Future<void> syncAll() async {
    for (final id in pending.keys.toList()) {
      check(); try { await sync(id); } catch (_) { /* Each version retains its failure and bytes. */ }
    }
  }
  Future<Directory> nativeDirectory(RommGame game) async {
    check(); return Directory('${_root!.path}/native/${_key(game.key)}').create(recursive: true);
  }
  Future<void> keepNativeProgress(RommGame game, String core, Uint8List bytes, {bool state = false}) async {
    check(); final key = '${game.key}:${game.identity}:$core';
    final path = _path(key, state ? 'state' : 'sram');
    final temp = File('$path.next'); await temp.writeAsBytes(bytes, flush: true); check(); await temp.rename(path);
  }
  Future<Uint8List?> nativeProgress(RommGame game, String core, {bool state = false}) async {
    check(); final file = File(_path('${game.key}:${game.identity}:$core', state ? 'state' : 'sram'));
    if (!await file.exists()) return null;
    if (await file.length() > 128 * 1024 * 1024) throw const RommFailure('romm.invalidFile');
    final bytes = await file.readAsBytes(); check(); return bytes;
  }
  @override void dispose() {
    _disposed = true; for (final api in _active.values) api.close(); _active.clear(); super.dispose();
  }
}
