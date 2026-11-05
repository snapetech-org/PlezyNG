import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'visualizer_content_limits.dart';

/// Immutable texture-pack references; the hash covers integrity.json.
class VisualizerTextureDependency {
  const VisualizerTextureDependency(this.id, this.version, this.integritySha256);
  final String id, version, integritySha256;
  String get identity => '$id@$version';
  static List<VisualizerTextureDependency> parse(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.length > 16) throw const FormatException('At most 16 texture dependencies are allowed.');
    final result = <VisualizerTextureDependency>[], identities = <String>{};
    final part = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$');
    bool component(Object? text) => text is String && part.hasMatch(text) &&
        !text.endsWith('.') && !text.endsWith('.previous') && !text.endsWith('.partial') &&
        !RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])($|\.)', caseSensitive: false).hasMatch(text);
    for (final item in value) {
      if (item is! Map || !component(item['id']) || !component(item['version']) ||
          item['integritySha256'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(item['integritySha256'])) {
        throw const FormatException('A texture dependency must name an exact pack, version and integrity hash.');
      }
      final dependency = VisualizerTextureDependency(item['id'], item['version'], item['integritySha256']);
      if (!identities.add(dependency.identity)) throw const FormatException('Repeated texture dependency.');
      result.add(dependency);
    }
    return result;
  }
}

class VisualizerPackDependencies {
  VisualizerPackDependencies(this.library, this.safePath);
  final Directory library;
  final String Function(String) safePath;
  static const maxBytes = 64 * 1024 * 1024, maxFiles = 2500;

  static Future<Map<String, dynamic>> readJson(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file ||
        await file.length() > 16 * 1024 * 1024) throw const FormatException('Missing or oversized pack metadata.');
    final bytes = await file.openRead(0, 16 * 1024 * 1024 + 1).fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    if (bytes.length > 16 * 1024 * 1024) throw const FormatException('Pack metadata exceeds its limit.');
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) throw const FormatException('Malformed pack metadata.');
    return value;
  }

  Future<Directory> locate(VisualizerTextureDependency dependency) async {
    for (final lane in ['packs', 'community-packs']) {
      final candidate = Directory(p.join(library.path, lane, dependency.id, dependency.version));
      if (!await candidate.exists()) continue;
      final canonical = await candidate.resolveSymbolicLinks();
      if (!p.isWithin(library.path, canonical)) throw const FormatException('Texture dependency escapes the library.');
      final manifest = await readJson(File(p.join(canonical, 'manifest.json')));
      if (manifest['id'] != dependency.id || manifest['version'] != dependency.version ||
          manifest['kind'] != 'textures' || VisualizerTextureDependency.parse(manifest['dependencies']).isNotEmpty) {
        throw FormatException('${dependency.identity} is not a self-contained texture pack.');
      }
      final integrity = File(p.join(canonical, 'integrity.json'));
      await readJson(integrity);
      if ((await sha256.bind(integrity.openRead()).first).toString() != dependency.integritySha256) {
        throw FormatException('${dependency.identity} has the wrong integrity hash.');
      }
      return Directory(canonical);
    }
    throw FormatException('Install texture pack ${dependency.identity} first.');
  }

  /// Reconstruct reference counts from installed manifests after every restart.
  Future<List<String>> dependents(String id, {String? version, String? replacingIntegrity}) async {
    final result = <String>[];
    var visited = 0;
    for (final lane in ['packs', 'community-packs']) {
      final root = Directory(p.join(library.path, lane));
      if (!await root.exists()) continue;
      await for (final pack in root.list(followLinks: false)) {
        if (pack is! Directory || p.basename(pack.path).startsWith('.stage-')) continue;
        await for (final installed in pack.list(followLinks: false)) {
          if (++visited > 5000) throw const FormatException('Too many installed packs.');
          if (installed is! Directory || installed.path.endsWith('.previous')) continue;
          // Permit removal of a damaged pack itself; other unreadable metadata
          // must be repaired/removed before we can prove a dependency unused.
          if (p.basename(pack.path) == id && (version == null || p.basename(installed.path) == version)) continue;
          final manifest = await readJson(File(p.join(installed.path, 'manifest.json')));
          if (VisualizerTextureDependency.parse(manifest['dependencies']).any((item) => item.id == id &&
              (version == null || item.version == version) &&
              (replacingIntegrity == null || item.integritySha256 != replacingIntegrity))) result.add('${manifest['name']} ${manifest['version']}');
        }
      }
    }
    return result;
  }

  Future<void> removeViews(String id, {String? version}) async {
    final root = Directory(p.join(library.path, 'resolved'));
    if (!await root.exists()) return;
    await for (final item in root.list(followLinks: false)) {
      if (item is! Directory || p.basename(item.path).startsWith('.stage-')) continue;
      final manifest = await readJson(File(p.join(item.path, 'manifest.json')));
      if (manifest['id'] == id && (version == null || manifest['version'] == version)) await item.delete(recursive: true);
    }
  }

  /// Both engines consume an ordinary relative-path view. Immutable dependency
  /// packs remain shared; disposable render copies count against library quota.
  Future<Directory> resolve(Directory owner, Map<String, dynamic> manifest,
      Future<void> Function(int bytes, String replacing) reserve) async {
    final dependencies = VisualizerTextureDependency.parse(manifest['dependencies']);
    final ownTextures = manifest['textures'] as List? ?? const [];
    final needsAliases = ownTextures.any((item) => item is Map &&
        ((item['aliases'] is List && (item['aliases'] as List).isNotEmpty) ||
         (item['file'] is String && item['file'] != 'textures/${p.posix.basename(item['file'] as String)}') ||
         (item['id'] is String && item['file'] is String &&
          item['id'] != p.posix.basenameWithoutExtension(item['file'] as String))));
    if (dependencies.isEmpty && !needsAliases) return owner;
    final sources = <({Directory root, Map<String, dynamic> manifest, Map<String, dynamic> integrity})>[];
    sources.add((root: owner, manifest: manifest, integrity: await readJson(File(p.join(owner.path, 'integrity.json')))));
    for (final dependency in dependencies) {
      final root = await locate(dependency);
      sources.add((root: root, manifest: await readJson(File(p.join(root.path, 'manifest.json'))),
          integrity: await readJson(File(p.join(root.path, 'integrity.json')))));
    }
    final identity = sha256.convert(utf8.encode(jsonEncode(sources.map((item) => item.integrity).toList()))).toString();
    final root = Directory(p.join(library.path, 'resolved')), target = Directory(p.join(library.path, 'resolved', identity));
    if (await File(p.join(target.path, '.complete')).exists()) return target;
    await root.create(recursive: true);
    final stage = Directory(p.join(root.path, '.stage-$identity'));
    if (await stage.exists()) await stage.delete(recursive: true);
    await stage.create();
    var bytesCopied = 0, imagePixels = 0;
    final paths = <String, String>{};
    try {
      for (var index = 0; index < sources.length; index++) {
        final source = sources[index], records = sources[index].integrity['files'];
        if (records is! List || records.length > maxFiles) throw const FormatException('Invalid dependency integrity index.');
        final byPath = <String, Map>{};
        for (final record in records) {
          if (record is! Map || record['path'] is! String || record['size'] is! int || record['sha256'] is! String ||
              record['size'] < 0 || record['size'] > 16 * 1024 * 1024 ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(record['sha256'])) throw const FormatException('Invalid dependency file record.');
          final path = safePath(record['path']);
          if (byPath.containsKey(path)) throw const FormatException('Duplicate dependency file.');
          byPath[path] = record;
        }
        final mounts = <String, String>{};
        if (index == 0) {
          for (final path in byPath.keys) mounts[path] = path;
        }
        if (index > 0 || ownTextures.isNotEmpty) {
          final textures = source.manifest['textures'];
          if (textures is! List || textures.isEmpty || textures.length > maxFiles) throw const FormatException('Empty texture dependency.');
          for (final notice in index == 0 ? const [] : (source.manifest['licenseFiles'] as List? ?? const [])) {
            if (notice is! String) throw const FormatException('Invalid dependency notice.');
            mounts['licenses/texture-dependencies/${source.manifest['id']}-${source.manifest['version']}/${safePath(notice)}'] = safePath(notice);
          }
          for (final texture in textures) {
            if (texture is! Map || texture['file'] is! String) throw const FormatException('Invalid dependency texture.');
            final file = safePath(texture['file']), extension = p.extension(file).toLowerCase();
            if (!VisualizerContentLimits.imageExtensions.contains(extension)) throw const FormatException('Unsupported dependency texture.');
            final aliases = texture['aliases'] ?? const [];
            if (aliases is! List || aliases.length > 32 || aliases.any((alias) => alias is! String)) throw const FormatException('Invalid texture aliases.');
            for (final alias in [p.basename(file), if (texture['id'] is String) texture['id'] as String, ...aliases.cast<String>()]) {
              final path = safePath('textures/${p.extension(alias).isEmpty ? '$alias$extension' : alias}');
              if (mounts.containsKey(path) && mounts[path] != file) throw const FormatException('Ambiguous texture aliases.');
              mounts[path] = file;
            }
          }
        }
        for (final mount in mounts.entries) {
          final record = byPath[mount.value];
          if (record == null) throw const FormatException('Unindexed dependency texture.');
          final folded = mount.key.toLowerCase();
          if (paths.containsKey(folded)) {
            if (paths[folded] == record['sha256']) continue;
            throw FormatException('Conflicting texture path: ${mount.key}.');
          }
          if (paths.length >= maxFiles - 2 || bytesCopied + (record['size'] as int) > maxBytes) throw const FormatException('Resolved pack exceeds 2,500 files or 64 MiB.');
          final file = File(p.join(source.root.path, mount.value)), canonical = await File(p.join(source.root.path, mount.value)).resolveSymbolicLinks();
          if (!p.isWithin(source.root.path, canonical) || await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) throw const FormatException('Unsafe dependency asset.');
          final bytes = await file.openRead(0, (record['size'] as int) + 1).fold<List<int>>([], (all, chunk) => all..addAll(chunk));
          if (bytes.length != record['size'] || sha256.convert(bytes).toString() != record['sha256']) throw const FormatException('Dependency asset checksum mismatch.');
          final extension = p.extension(mount.key).toLowerCase();
          if (VisualizerContentLimits.imageExtensions.contains(extension)) {
            imagePixels += VisualizerContentLimits.imagePixels(extension, Uint8List.fromList(bytes));
            if (imagePixels > VisualizerContentLimits.maxPackImagePixels) throw const FormatException('Resolved textures exceed 32 megapixels.');
          }
          final destination = File(p.join(stage.path, mount.key));
          await destination.parent.create(recursive: true);
          await destination.writeAsBytes(bytes, flush: true);
          paths[folded] = record['sha256'];
          bytesCopied += bytes.length;
        }
      }
      final provenance = utf8.encode(jsonEncode({
        'schemaVersion': 1, 'kind': 'plezy-resolved-preset-provenance',
        'sources': sources.map((item) => {'manifest': item.manifest, 'integrity': item.integrity}).toList(),
      }));
      if (bytesCopied + provenance.length + identity.length > maxBytes) throw const FormatException('Resolved provenance exceeds the pack budget.');
      if (paths.containsKey('visualizer-provenance.json')) throw const FormatException('Pack uses a reserved provenance path.');
      await File(p.join(stage.path, 'VISUALIZER-PROVENANCE.json')).writeAsBytes(provenance, flush: true);
      await reserve(bytesCopied + provenance.length + identity.length, target.path);
      await File(p.join(stage.path, '.complete')).writeAsString(identity, flush: true);
      if (await target.exists()) await target.delete(recursive: true);
      await stage.rename(target.path);
      return target;
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }
}
