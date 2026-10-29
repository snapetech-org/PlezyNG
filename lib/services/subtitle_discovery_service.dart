import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'settings_service.dart';

final class SubtitleDiscoveryResult {
  const SubtitleDiscoveryResult(this.paths, this.warnings, this.scanned, this.limited);
  final List<String> paths;
  final List<SubtitleDiscoveryWarning> warnings;
  final int scanned;
  final bool limited;
}

enum SubtitleDiscoveryWarningKind { permissionExpired, unreadable, timedOut }

final class SubtitleDiscoveryWarning {
  const SubtitleDiscoveryWarning(this.kind, this.folder);
  final SubtitleDiscoveryWarningKind kind;
  final String folder;
}

enum SubtitleDiscoveryFailure { queryBounds, tooManyRoots, staleOwner }

final class SubtitleDiscoveryException implements Exception {
  const SubtitleDiscoveryException(this.failure);
  final SubtitleDiscoveryFailure failure;
}

/// User-selected local roots only. No remote URL probing, recursive symlink
/// traversal, file movement or automatic attachment happens during discovery.
abstract final class SubtitleDiscoveryService {
  static String _key(String profile) => 'subtitle_roots.v1.${sha256.convert(utf8.encode(profile))}';
  static Future<List<String>> roots(String profile) async => List.unmodifiable(
    (await SettingsService.getInstance()).prefs.getStringList(_key(profile))?.take(8) ?? const <String>[]);

  static Future<void> saveRoots(String profile, List<String> roots) async {
    if (roots.length > 8 || roots.any((r) => r.length > 4096 || !p.isAbsolute(r) || r.contains('\u0000'))) {
      throw const FormatException('Choose at most eight local subtitle folders.');
    }
    await (await SettingsService.getInstance()).prefs.setStringList(_key(profile), roots.toSet().toList());
  }

  static String? localMediaPath(String? value) {
    if (value == null || value.isEmpty || value.length > 8192 || value.contains('\u0000')) return null;
    try {
      if (value.startsWith('file:')) return p.normalize(p.fromUri(Uri.parse(value)));
      if (p.isAbsolute(value) && !value.contains('://')) return p.normalize(value);
    } catch (_) { return null; }
    return null;
  }

  static String _matchText(String value) => value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  static Future<SubtitleDiscoveryResult> discover({required List<String> roots, required String title,
    required Set<String> extensions, required bool Function() isCurrent, bool includeSubfolders = true}) async {
    final query = _matchText(title);
    final queryLength = query.runes.length;
    if (queryLength < 2 || queryLength > 256) throw const SubtitleDiscoveryException(SubtitleDiscoveryFailure.queryBounds);
    if (roots.length > 9) throw const SubtitleDiscoveryException(SubtitleDiscoveryFailure.tooManyRoots);
    final found = <String>{}, visited = <String>{}, warnings = <SubtitleDiscoveryWarning>[];
    final queue = <(String, int)>[for (final root in roots.toSet()) (root, 0)];
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var scanned = 0, limited = false;
    for (var cursor = 0; cursor < queue.length; cursor++) {
      if (!isCurrent()) throw const SubtitleDiscoveryException(SubtitleDiscoveryFailure.staleOwner);
      if (DateTime.now().isAfter(deadline)) { limited = true; break; }
      final directory = queue[cursor];
      if (!p.isAbsolute(directory.$1) || !visited.add(p.normalize(directory.$1))) continue;
      try {
        await for (final entity in Directory(directory.$1).list(followLinks: false).timeout(const Duration(seconds: 3))) {
          if (!isCurrent()) throw const SubtitleDiscoveryException(SubtitleDiscoveryFailure.staleOwner);
          if (++scanned > 10000 || DateTime.now().isAfter(deadline) || found.length >= 128) { limited = true; break; }
          if (entity is Directory && includeSubfolders && directory.$2 == 0) {
            if (queue.length >= 128) { limited = true; break; }
            queue.add((entity.path, 1));
          } else if (entity is File) {
            final extension = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
            if (!extensions.contains(extension)) continue;
            final name = _matchText(p.basenameWithoutExtension(entity.path));
            if (name != query && !name.startsWith('$query ')) continue;
            final size = await entity.length().timeout(const Duration(seconds: 2));
            if (size > 0 && size <= 32 * 1024 * 1024) found.add(entity.path);
          }
        }
      } on FileSystemException { warnings.add(SubtitleDiscoveryWarning(SubtitleDiscoveryWarningKind.permissionExpired, p.basename(directory.$1))); }
      on IOException { warnings.add(SubtitleDiscoveryWarning(SubtitleDiscoveryWarningKind.unreadable, p.basename(directory.$1))); }
      on TimeoutException { warnings.add(SubtitleDiscoveryWarning(SubtitleDiscoveryWarningKind.timedOut, p.basename(directory.$1))); }
      if (limited) break;
    }
    final paths = found.toList()..sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    final idx = paths.where((path) => p.extension(path).toLowerCase() == '.idx').map((path) => p.withoutExtension(path).toLowerCase()).toSet();
    paths.removeWhere((path) => p.extension(path).toLowerCase() == '.sub' && idx.contains(p.withoutExtension(path).toLowerCase()));
    return SubtitleDiscoveryResult(List.unmodifiable(paths), List.unmodifiable(warnings.take(16)), scanned, limited);
  }

  static Future<void> validateBitmapPair(String indexPath) async {
    if (p.extension(indexPath).toLowerCase() != '.idx') return;
    final stem = p.withoutExtension(indexPath);
    for (final suffix in ['.sub', '.SUB']) {
      final path = '$stem$suffix';
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file) continue;
      final size = await File(path).length();
      if (size > 0 && size <= 32 * 1024 * 1024) return;
    }
    throw const FormatException('This VobSub index needs a matching, non-empty SUB file of at most 32 MiB.');
  }
}
