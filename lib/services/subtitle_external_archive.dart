import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'settings_service.dart';
import 'subtitle_revision_service.dart';

enum SubtitleArchiveFailure { folder, changed, invalid, limit, empty, stale }

final class SubtitleArchiveException implements Exception {
  const SubtitleArchiveException(this.failure);
  final SubtitleArchiveFailure failure;
}

final class SubtitleArchiveSnapshot {
  const SubtitleArchiveSnapshot({required this.name, required this.createdAt,
    required this.title, required this.bytes, required this.digest,
    required this.revisionCount});
  final String name;
  final DateTime createdAt;
  final String title;
  final int bytes;
  final String digest;
  final int revisionCount;
}

/// Explicit, immutable history snapshots in a viewer-selected local folder.
/// The existing revision store remains the playback authority. No discovery,
/// upload, attachment, replacement or archive pruning happens automatically.
abstract final class SubtitleExternalArchive {
  static const namespace = 'PlezyNG-subtitles-v1';
  static const maximumSnapshotsPerItem = 24;
  static const maximumProfileBytes = 256 * 1024 * 1024;
  static final _hex = RegExp(r'^[0-9a-f]{64}$');
  static final _name = RegExp(r'^snapshot-[0-9]{13,20}-[0-9a-f]{32}$');
  static Future<void> _tail = Future<void>.value();

  static String _profileKey(String profile) {
    if (profile.trim().isEmpty || profile.length > 4096) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.stale);
    }
    return sha256.convert(utf8.encode(profile)).toString();
  }

  static String _setting(String profile) => 'subtitle_archive_root.v1.${_profileKey(profile)}';

  static Future<String?> selectedRoot(String profile) async =>
      (await SettingsService.getInstance()).prefs.getString(_setting(profile));

  static Future<void> selectRoot(String profile, String? path,
      {required bool Function() isCurrent}) async {
    final normalized = path == null ? null : await _root(path);
    final prefs = (await SettingsService.getInstance()).prefs;
    _current(isCurrent);
    final saved = normalized == null ? await prefs.remove(_setting(profile)) :
        await prefs.setString(_setting(profile), normalized.path);
    if (!saved) throw const SubtitleArchiveException(SubtitleArchiveFailure.folder);
  }

  static void _current(bool Function() check) {
    if (!check()) throw const SubtitleArchiveException(SubtitleArchiveFailure.stale);
  }

  static Future<Directory> _root(String path) async {
    if (path.isEmpty || path.length > 4096 || !p.isAbsolute(path) || path.contains('\u0000')) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.folder);
    }
    // The explicitly selected root may itself resolve through a mount/symlink.
    // All managed descendants below this canonical directory must be real dirs.
    final root = Directory(await Directory(path).resolveSymbolicLinks());
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.folder);
    }
    return root;
  }

  static Future<Directory?> _child(Directory parent, String name, {bool create = false}) async {
    final child = Directory(p.join(parent.path, name));
    var type = await FileSystemEntity.type(child.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await child.create();
      type = await FileSystemEntity.type(child.path, followLinks: false);
    }
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory ||
        !p.equals(await child.resolveSymbolicLinks(), child.path)) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.changed);
    }
    return child;
  }

  static Future<(Directory, Directory?)> _item(String root, SubtitleRevisionIdentity identity,
      {bool create = false}) async {
    final base = await _root(root);
    final space = await _child(base, namespace, create: create);
    final profile = space == null ? null : await _child(space, _profileKey(identity.profileId), create: create);
    final item = profile == null ? null : await _child(profile, identity.storageKey, create: create);
    return (base, item);
  }

  static Future<Uint8List> _read(File file, int maximum) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file ||
        !p.equals(await file.resolveSymbolicLinks(), file.path)) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.invalid);
    }
    final size = await file.length();
    if (size <= 0 || size > maximum) throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
    final bytes = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in file.openRead(0, maximum + 1)) {
      count += chunk.length;
      if (count > maximum) throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
      bytes.add(chunk);
    }
    if (count != size) throw const SubtitleArchiveException(SubtitleArchiveFailure.changed);
    return bytes.takeBytes();
  }

  static Future<SubtitleArchiveSnapshot> _manifest(Directory directory, String itemKey) async {
    final name = p.basename(directory.path);
    if (!_name.hasMatch(name)) throw const SubtitleArchiveException(SubtitleArchiveFailure.invalid);
    final decoded = jsonDecode(utf8.decode(await _read(File(p.join(directory.path, 'manifest.json')), 16384)));
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 'plezyng.subtitle-archive.v1' ||
        decoded['itemKey'] != itemKey || decoded['historyFile'] != 'history.json' ||
        decoded['sha256'] is! String || !_hex.hasMatch(decoded['sha256'] as String) ||
        decoded['bytes'] is! int || (decoded['bytes'] as int) <= 0 ||
        (decoded['bytes'] as int) > SubtitleRevisionService.maximumHistoryBundleBytes ||
        decoded['revisionCount'] is! int || (decoded['revisionCount'] as int) < 1 ||
        (decoded['revisionCount'] as int) > SubtitleRevisionService.maximumRevisionsPerItem ||
        decoded['title'] is! String || (decoded['title'] as String).length > 512 ||
        decoded['createdAt'] is! String) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.invalid);
    }
    final created = DateTime.tryParse(decoded['createdAt'] as String);
    if (created == null) throw const SubtitleArchiveException(SubtitleArchiveFailure.invalid);
    return SubtitleArchiveSnapshot(name: name, createdAt: created.toUtc(),
      title: decoded['title'] as String, bytes: decoded['bytes'] as int,
      digest: decoded['sha256'] as String, revisionCount: decoded['revisionCount'] as int);
  }

  static Future<List<SubtitleArchiveSnapshot>> list(String root, SubtitleRevisionIdentity identity,
      {required bool Function() isCurrent}) async {
    _current(isCurrent);
    final (_, item) = await _item(root, identity);
    if (item == null) return const [];
    final snapshots = <SubtitleArchiveSnapshot>[];
    var entries = 0;
    await for (final entry in item.list(followLinks: false)) {
      _current(isCurrent);
      if (++entries > 128) throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
      if (!_name.hasMatch(p.basename(entry.path))) continue;
      if (entry is! Directory) throw const SubtitleArchiveException(SubtitleArchiveFailure.invalid);
      if (snapshots.length >= maximumSnapshotsPerItem) {
        throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
      }
      final safe = await _child(item, p.basename(entry.path));
      snapshots.add(await _manifest(safe!, identity.storageKey));
    }
    _current(isCurrent);
    snapshots.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(snapshots);
  }

  static Future<List<SubtitleRevision>> read(String root, SubtitleRevisionIdentity identity,
      SubtitleArchiveSnapshot snapshot, {required bool Function() isCurrent}) async {
    _current(isCurrent);
    if (!_name.hasMatch(snapshot.name)) throw const SubtitleArchiveException(SubtitleArchiveFailure.invalid);
    final (_, item) = await _item(root, identity);
    final directory = item == null ? null : await _child(item, snapshot.name);
    if (directory == null) throw const SubtitleArchiveException(SubtitleArchiveFailure.changed);
    final manifest = await _manifest(directory, identity.storageKey);
    if (manifest.digest != snapshot.digest || manifest.bytes != snapshot.bytes ||
        manifest.revisionCount != snapshot.revisionCount) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.changed);
    }
    final bytes = await _read(File(p.join(directory.path, 'history.json')), manifest.bytes);
    if (bytes.length != manifest.bytes || sha256.convert(bytes).toString() != manifest.digest) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.changed);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 'plezyng.subtitle-history.v1' ||
        decoded['revisions'] is! List || (decoded['revisions'] as List).length != manifest.revisionCount) {
      throw const SubtitleArchiveException(SubtitleArchiveFailure.invalid);
    }
    final revisions = <SubtitleRevision>[];
    final ids = <String>{};
    for (final row in decoded['revisions'] as List) {
      if (utf8.encode(jsonEncode(row)).length > SubtitleRevisionService.maximumRevisionBytes) {
        throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
      }
      final revision = SubtitleRevision.fromJson(row);
      if (!ids.add(revision.id)) throw const SubtitleArchiveException(SubtitleArchiveFailure.invalid);
      revisions.add(revision);
    }
    _current(isCurrent);
    return List.unmodifiable(revisions);
  }

  static Future<int> _profileUsage(Directory profile, bool Function() isCurrent) async {
    var entries = 0, bytes = 0;
    await for (final entry in profile.list(recursive: true, followLinks: false)) {
      _current(isCurrent);
      if (++entries > 6000 || entry is Link) throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
      if (entry is File) bytes += await entry.length();
      if (bytes > maximumProfileBytes) throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
    }
    return bytes;
  }

  static Future<SubtitleArchiveSnapshot> save(String root, SubtitleRevisionIdentity identity,
      {required bool Function() isCurrent}) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    Directory? staging;
    try {
      _current(isCurrent);
      final revisions = await SubtitleRevisionService.loadRevisions(identity);
      if (revisions.isEmpty) throw const SubtitleArchiveException(SubtitleArchiveFailure.empty);
      final now = DateTime.now().toUtc();
      final bytes = utf8.encode(jsonEncode({
        'schema': 'plezyng.subtitle-history.v1', 'generatedBy': 'PlezyNG',
        'exportedAt': now.toIso8601String(), 'revisions': revisions.map((r) => r.toJson()).toList(),
      }));
      if (bytes.length > SubtitleRevisionService.maximumHistoryBundleBytes) {
        throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
      }
      final digest = sha256.convert(bytes).toString();
      final (_, item) = await _item(root, identity, create: true);
      final existing = await list(root, identity, isCurrent: isCurrent);
      if (existing.length >= maximumSnapshotsPerItem) {
        throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
      }
      if (await _profileUsage(item!.parent, isCurrent) + bytes.length + 16384 > maximumProfileBytes) {
        throw const SubtitleArchiveException(SubtitleArchiveFailure.limit);
      }
      final random = Random.secure();
      final nonce = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final name = 'snapshot-${now.microsecondsSinceEpoch}-$nonce';
      _current(isCurrent);
      staging = await item.createTemp('.pending-');
      await File(p.join(staging.path, 'history.json')).writeAsBytes(bytes, flush: true);
      await File(p.join(staging.path, 'manifest.json')).writeAsString(jsonEncode({
        'schema': 'plezyng.subtitle-archive.v1', 'itemKey': identity.storageKey,
        'title': String.fromCharCodes((identity.mediaTitle ?? '').runes.take(160)),
        'createdAt': now.toIso8601String(), 'historyFile': 'history.json',
        'bytes': bytes.length, 'sha256': digest, 'revisionCount': revisions.length,
      }), flush: true);
      // Revalidate the selected root/ancestors immediately before publication.
      final (_, stillItem) = await _item(root, identity);
      if (stillItem == null || !p.equals(stillItem.path, item.path)) {
        throw const SubtitleArchiveException(SubtitleArchiveFailure.changed);
      }
      _current(isCurrent);
      final committed = await staging.rename(p.join(item.path, name));
      staging = null;
      return await _manifest(committed, identity.storageKey);
    } finally {
      try {
        if (staging != null && await staging.exists()) await staging.delete(recursive: true);
      } finally { done.complete(); }
    }
  }
}
