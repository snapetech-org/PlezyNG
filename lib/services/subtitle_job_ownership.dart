import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A real SQLite writer transaction, held until the owner finishes all file
/// writes and native calls. No expiring lease can admit a second writer while
/// a suspended engine still owns a checkpoint or a retained WAV. This database
/// is separate from all library/profile databases, so they remain writable.
final class SubtitleJobOwnership extends GeneratedDatabase {
  SubtitleJobOwnership._(super.executor);
  bool _held = false;
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (_) async {
    await customStatement('CREATE TABLE ownership (id INTEGER PRIMARY KEY)');
  });

  static Future<SubtitleJobOwnership?> acquire(Directory root) async {
    await root.create(recursive: true);
    final db = SubtitleJobOwnership._(NativeDatabase.createInBackground(
      File(p.join(root.path, 'ownership.sqlite')),
      setup: (connection) { connection.execute('PRAGMA busy_timeout=50'); },
    ));
    try {
      // Open/migrate first; Drift must not start a migration inside our lock.
      await db.customSelect('SELECT 1').get();
      await db.customStatement('BEGIN IMMEDIATE');
      db._held = true;
      return db;
    } on SqliteException catch (error) {
      await db.close();
      if (error.resultCode == 5 || error.resultCode == 6) return null; // BUSY / LOCKED
      rethrow;
    } on Object {
      await db.close();
      rethrow;
    }
  }

  Future<void> release() async {
    try {
      if (_held) await customStatement('ROLLBACK');
    } finally {
      _held = false;
      await close();
    }
  }
}

/// A foreground request retires a headless worker at its next safe boundary.
/// The profile ownership transaction, not this heartbeat, protects files.
/// Native mobile activity is checked independently by the worker.
final class SubtitleJobActivity with WidgetsBindingObserver {
  SubtitleJobActivity._();
  static final instance = SubtitleJobActivity._();
  Timer? _timer;
  File? _marker;
  Future<void> _writes = Future.value();
  bool _started = false;
  bool _active = true;

  static Future<void> _authorizationWrites = Future.value();
  static String profileKey(String id) => sha256.convert(utf8.encode(id)).toString();

  static Future<void> authorize(String? key) {
    final next = _authorizationWrites.then((_) async {
      final directory = await root();
      await directory.create(recursive: true);
      await File(p.join(directory.path, 'authorized_profile')).writeAsString(key ?? '', flush: true);
    });
    _authorizationWrites = next.catchError((Object _) {});
    return next;
  }

  static Future<String?> authorizedProfile() async {
    try {
      final file = File(p.join((await root()).path, 'authorized_profile'));
      if (!await file.exists() || await file.length() != 64) return null;
      final key = await file.readAsString();
      return RegExp(r'^[0-9a-f]{64}$').hasMatch(key) && !await isRevoked(key) ? key : null;
    } on Object { return null; }
  }

  static Future<bool> isRevoked(String key) async =>
      File(p.join((await root()).path, 'revoked', key)).exists();

  static Future<void> revokeProfile(String id) async {
    final file = File(p.join((await root()).path, 'revoked', profileKey(id)));
    await file.parent.create(recursive: true);
    await file.writeAsString('1', flush: true);
  }

  static Future<void> reauthorize(String key) async {
    final file = File(p.join((await root()).path, 'revoked', key));
    if (await file.exists()) await file.delete();
  }

  static Future<Directory> root() async => Directory(p.join(
    (await getApplicationSupportDirectory()).path, 'subtitle_jobs'));

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _active = state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    final directory = Directory(p.join((await root()).path, 'activity'));
    await directory.create(recursive: true);
    _marker = File(p.join(directory.path, '${pid}_${DateTime.now().microsecondsSinceEpoch}'));
    await _write();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) { unawaited(_write()); });
  }

  Future<void> _write() {
    final next = _writes.then((_) async {
      final file = _marker;
      if (file == null) return;
      if (_active) {
        await file.writeAsString('1');
      } else if (await file.exists()) {
        await file.delete();
      }
    });
    _writes = next.catchError((Object _) {});
    return _writes;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    unawaited(_write());
  }

  static Future<bool> foregroundRequested() async {
    try {
      final directory = Directory(p.join((await root()).path, 'activity'));
      if (!await directory.exists()) return false;
      final now = DateTime.now();
      var count = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (++count > 128) return true;
        if (entity is! File) continue;
        final modified = (await entity.stat()).modified;
        if (now.difference(modified) < const Duration(seconds: 12)) return true;
        if (now.difference(modified) > const Duration(hours: 1)) {
          try { await entity.delete(); } on Object { /* No ownership depends on cleanup. */ }
        }
      }
      return false;
    } on Object {
      return true; // Unknown activity never admits speculative inference.
    }
  }
}
