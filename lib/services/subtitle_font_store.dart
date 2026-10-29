import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SubtitleStoredFont {
  const SubtitleStoredFont({required this.digest, required this.label, required this.bytes, required this.license});
  final String digest, label, license;
  final int bytes;
  String get family => 'PlezyImported-$digest';
  Map<String, Object> toJson() => {'sha256': digest, 'label': label, 'bytes': bytes, 'license': license};
}

/// Explicitly imported, content-addressed OpenType fonts. No media attachment,
/// network URL or subtitle-controlled path can cause a font to be installed.
/// Table-directory validation bounds the input; it is not font-parser fuzzing
/// or proof that a font is safe for every native shaping implementation.
class SubtitleFontStore {
  SubtitleFontStore._();
  static final instance = SubtitleFontStore._();
  static const maximumFontBytes = 16 * 1024 * 1024;
  static const maximumStoredBytes = 128 * 1024 * 1024;
  static const maximumFonts = 16;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final familyPattern = RegExp(r'^PlezyImported-[a-f0-9]{64}$');
  final Map<String, SubtitleStoredFont> _fonts = {};
  // Flutter cannot unload a registered family. Bound all registrations until
  // process restart, including fonts removed and reimported during a session.
  final Set<String> _registered = {};
  Future<void>? _initialized;
  Future<void> _writes = Future.value();
  String? _root;
  List<SubtitleStoredFont> get fonts => List.unmodifiable(_fonts.values);
  List<String> get families => [for (final font in _fonts.values) if (_registered.contains(font.digest)) font.family];
  int get storedBytes => _fonts.values.fold(0, (sum, font) => sum + font.bytes + utf8.encode(font.license).length);
  int get registeredCount => _registered.length;
  Future<int> diskBytes() async {
    await initialize();
    var bytes = 0;
    await for (final entry in Directory(_root!).list(followLinks: false)) {
      final stat = await entry.stat();
      if (entry is! File || stat.type != FileSystemEntityType.file) throw StateError('The font store contains an unsupported filesystem entry.');
      bytes += stat.size;
    }
    return bytes;
  }
  String label(String family) {
    for (final font in _fonts.values) { if (font.family == family) return '${font.label} (offline)'; }
    return family;
  }
  SubtitleStoredFont? findFamily(String family) {
    for (final font in _fonts.values) { if (font.family == family) return font; }
    return null;
  }
  Future<void> initialize() => _initialized ??= _load().catchError((Object error) { _initialized = null; throw error; });

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Future<void> _load() async {
    _root = p.join((await getApplicationSupportDirectory()).path, 'subtitle_imported_fonts_v1');
    final root = Directory(_root!);
    await root.create(recursive: true);
    Map? document;
    for (final name in ['index.json', 'index.previous.json']) {
      final file = File(p.join(_root!, name));
      if (!await file.exists()) continue;
      try {
        final data = jsonDecode(utf8.decode(await _bounded(file, 512 * 1024)));
        if (data is! Map || data['schema'] != 1 || data['fonts'] is! List || data['fonts'].length > maximumFonts) continue;
        document = data; break;
      } catch (_) { /* Recover the previous committed index after interruption. */ }
    }
    final candidates = <SubtitleStoredFont>[];
    var bytes = 0;
    for (final row in document?['fonts'] ?? const []) {
      if (row is! Map || row['sha256'] is! String || !_digest.hasMatch(row['sha256']) ||
          row['label'] is! String || row['label'].length > 100 || row['bytes'] is! int ||
          row['bytes'] <= 0 || row['bytes'] > maximumFontBytes || row['license'] is! String || utf8.encode(row['license']).length > 16384) continue;
      final font = SubtitleStoredFont(digest: row['sha256'], label: row['label'], bytes: row['bytes'], license: row['license']);
      if (candidates.any((other) => other.digest == font.digest)) continue;
      bytes += font.bytes + utf8.encode(font.license).length;
      if (bytes > maximumStoredBytes) break;
      candidates.add(font);
    }
    _fonts.clear();
    for (final font in candidates) {
      try {
        final bytes = await _verified(font);
        await _register(font, bytes);
        _fonts[font.digest] = font;
      } catch (_) { /* Damaged or unsupported fonts never reach the selector. */ }
    }
    // Only this store writes this private directory. Remove orphan partials and
    // blobs not referenced by the recovered index, so quota includes all blobs.
    await for (final entry in root.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (const {'index.json', 'index.previous.json'}.contains(name) ||
          name.endsWith('.otf') && _fonts.containsKey(name.substring(0, name.length - 4))) continue;
      try { await entry.delete(recursive: true); } catch (_) {}
    }
  }

  static Future<Uint8List> _bounded(File file, int limit) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file || await file.length() > limit) {
      throw const FormatException('The font file is not a bounded regular file.');
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (out.length + chunk.length > limit) throw const FormatException('The font file exceeded its size limit.');
      out.add(chunk);
    }
    return out.takeBytes();
  }

  static void _validate(Uint8List bytes) {
    if (bytes.length < 12 || bytes.length > maximumFontBytes) throw const FormatException('Invalid font size.');
    final data = ByteData.sublistView(bytes), signature = ByteData.sublistView(bytes).getUint32(0);
    if (signature != 0x00010000 && signature != 0x4f54544f) throw const FormatException('Select a single TrueType or OpenType font; collections and web fonts are unsupported.');
    final count = data.getUint16(4);
    final end = 12 + count * 16;
    if (count < 1 || count > 128 || end > bytes.length) throw const FormatException('Invalid font table directory.');
    final tags = <String>{};
    for (var index = 0; index < count; index++) {
      final start = 12 + index * 16;
      final tag = String.fromCharCodes(bytes.sublist(start, start + 4));
      final offset = data.getUint32(start + 8), length = data.getUint32(start + 12);
      if (!RegExp(r'^[\x20-\x7e]{4}$').hasMatch(tag) || !tags.add(tag) || offset % 4 != 0 ||
          offset < end || offset > bytes.length || length > bytes.length - offset) throw const FormatException('Invalid font table bounds.');
    }
    if (!tags.containsAll({'head', 'maxp', 'cmap', 'name'}) ||
        !(tags.contains('glyf') && tags.contains('loca') || tags.contains('CFF ') || tags.contains('CFF2'))) {
      throw const FormatException('The font lacks required outline or text tables.');
    }
  }

  Future<Uint8List> _verified(SubtitleStoredFont font) async {
    final bytes = await _bounded(File(p.join(_root!, '${font.digest}.otf')), maximumFontBytes);
    if (bytes.length != font.bytes || sha256.convert(bytes).toString() != font.digest) throw const FormatException('Font integrity check failed.');
    _validate(bytes);
    return bytes;
  }
  Future<Uint8List> verifiedBytes(SubtitleStoredFont font) async {
    await initialize();
    if (!_fonts.containsKey(font.digest)) throw StateError('This font was removed.');
    return _verified(font);
  }

  Future<void> _register(SubtitleStoredFont font, Uint8List bytes) async {
    if (_registered.contains(font.digest)) return;
    if (_registered.length >= maximumFonts) throw StateError('Restart the app before registering more fonts.');
    final loader = FontLoader(font.family)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _registered.add(font.digest);
  }

  Future<SubtitleStoredFont> importFile(File file, {required String label, String license = ''}) => _serialize(() async {
    await initialize();
    final name = label.trim();
    if (name.isEmpty || name.length > 100 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) || utf8.encode(license).length > 16384) {
      throw const FormatException('Use a short font label and at most 16 KiB of license text.');
    }
    final bytes = await _bounded(file, maximumFontBytes);
    _validate(bytes);
    final digest = sha256.convert(bytes).toString();
    if (_fonts[digest] case final SubtitleStoredFont existing) return existing;
    // Include recovery metadata and orphan bytes whose deletion failed. Reserve
    // both index generations and the small temporary index during promotion.
    if (_fonts.length >= maximumFonts || await diskBytes() + bytes.length + 1536 * 1024 > maximumStoredBytes) {
      throw StateError('Offline fonts are limited to 16 entries and 128 MiB. Remove unused fonts first.');
    }
    if (!_registered.contains(digest) && _registered.length >= maximumFonts) throw StateError('Restart the app before registering more fonts.');
    final font = SubtitleStoredFont(digest: digest, label: name, bytes: bytes.length, license: license);
    final target = File(p.join(_root!, '$digest.otf')), partial = File(p.join(_root!, '$digest.partial'));
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(target.path);
    try {
      await _register(font, bytes);
      _fonts[digest] = font;
      await _persist();
    } catch (_) {
      _fonts.remove(digest);
      try { await target.delete(); } catch (_) {}
      rethrow;
    }
    return font;
  });

  Future<void> remove(SubtitleStoredFont font) => _serialize(() async {
    await initialize();
    final previous = _fonts.remove(font.digest);
    if (previous == null) return;
    try { await _persist(); } catch (_) { _fonts[font.digest] = previous; rethrow; }
    final file = File(p.join(_root!, '${font.digest}.otf'));
    if (await file.exists()) await file.delete();
  });

  Future<void> _persist() async {
    final target = File(p.join(_root!, 'index.json')), previous = File(p.join(_root!, 'index.previous.json'));
    final partial = File(p.join(_root!, 'index.partial'));
    await partial.writeAsString(jsonEncode({'schema': 1, 'fonts': _fonts.values.map((font) => font.toJson()).toList()}), flush: true);
    if (await target.exists()) {
      if (await previous.exists()) await previous.delete();
      await target.rename(previous.path);
    }
    await partial.rename(target.path);
  }
}
