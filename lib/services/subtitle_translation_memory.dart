import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'subtitle_retimer.dart';

/// Explicitly reviewed text only. Exact surrounding-cue and glossary matching
/// prevents a remembered correction from silently crossing unrelated contexts.
abstract final class SubtitleTranslationMemory {
  static const _maximumBytes = 2 * 1024 * 1024;
  static const _maximumEntries = 2000;
  static Future<void> _writes = Future.value();

  static String digest(Object value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static String namespace({required String source, required String target, required String engine,
    required Map<String, String> glossary, required bool bilingual}) {
    final keys = glossary.keys.toList()..sort();
    return digest([source, target, engine, bilingual, {for (final key in keys) key: glossary[key]}]);
  }

  static String _key(List<SubtitleCue> cues, int index, String namespace) => digest([
    namespace, index == 0 ? null : cues[index - 1].text, cues[index].text,
    index + 1 == cues.length ? null : cues[index + 1].text,
    if (RegExp(r'<lang[. \t>]', caseSensitive: false).hasMatch(cues[index].text)) 'drop-source-language-spans-v1',
  ]);

  static Future<File> _file(String profileId) async {
    final root = Directory(p.join((await getApplicationSupportDirectory()).path, 'subtitle_translation_memory'));
    await root.create(recursive: true);
    return File(p.join(root.path, '${digest(profileId)}.json'));
  }

  static Future<Map<String, dynamic>> _read(File file) async {
    for (final path in [file, File('${file.path}.bak')]) {
      if (!await path.exists() || await path.length() > _maximumBytes) continue;
      try {
        final data = jsonDecode(await path.readAsString());
        if (data is! Map<String, dynamic> || data['schema'] != 1 || data['entries'] is! Map) continue;
        final entries = Map<String, dynamic>.from(data['entries'] as Map);
        if (entries.length > _maximumEntries) continue;
        return entries;
      } catch (_) { continue; }
    }
    return {};
  }

  static Future<Map<String, String>> lookup({required String profileId, required String namespace,
    required List<SubtitleCue> cues}) async {
    final entries = await _read(await _file(profileId));
    final output = <String, String>{};
    for (var i = 0; i < cues.length; i++) {
      final entry = entries[_key(cues, i, namespace)];
      if (entry is! Map || entry['sourceFingerprint'] != digest(cues[i].text)) continue;
      final text = entry['text'];
      if (text is String && text.trim().isNotEmpty && text.length <= 4000) output[cues[i].stableId] = text;
    }
    return output;
  }

  /// Portable entries remain suggestions: the normal translation review still
  /// precedes attachment. No model, language qualification or source URL travels.
  static Map<String, Map<String, Object?>> validatePortable(Object? raw) {
    if (raw is! Map || raw.length > _maximumEntries) throw const FormatException('Translation memory entry limit.');
    final output = <String, Map<String, Object?>>{};
    final hex = RegExp(r'^[0-9a-f]{64}$');
    final keys = raw.keys.whereType<String>().toList()..sort();
    if (keys.length != raw.length) throw const FormatException('Invalid memory key.');
    for (final key in keys) {
      final value = raw[key];
      const fields = {'text', 'sourceFingerprint', 'namespace', 'reviewRevision', 'itemIdentity',
        'cueId', 'backend', 'modelRevision', 'reviewedAt'};
      if (!hex.hasMatch(key) || value is! Map || value.length != fields.length ||
          value.keys.any((field) => !fields.contains(field))) throw const FormatException('Invalid memory entry.');
      final text = value['text'], source = value['sourceFingerprint'], namespace = value['namespace'];
      final revision = value['reviewRevision'], reviewed = value['reviewedAt'];
      if (text is! String || text.trim().isEmpty || text.length > 4000 ||
          source is! String || !hex.hasMatch(source) || namespace is! String || !hex.hasMatch(namespace) ||
          revision is! String || !hex.hasMatch(revision) || reviewed is! String || reviewed.length > 64 ||
          DateTime.tryParse(reviewed) == null) throw const FormatException('Invalid reviewed translation.');
      String bounded(String name, int maximum) {
        final item = value[name];
        if (item is! String || item.length > maximum) throw const FormatException('Invalid memory provenance.');
        return item;
      }
      output[key] = Map.unmodifiable({'text': text, 'sourceFingerprint': source, 'namespace': namespace,
        'reviewRevision': revision, 'itemIdentity': bounded('itemIdentity', 256),
        'cueId': bounded('cueId', 256), 'backend': bounded('backend', 256),
        'modelRevision': bounded('modelRevision', 256), 'reviewedAt': reviewed});
    }
    if (utf8.encode(jsonEncode({'schema': 1, 'entries': output})).length > _maximumBytes) {
      throw const FormatException('Translation memory size limit.');
    }
    return Map.unmodifiable(output);
  }

  static Future<Map<String, Map<String, Object?>>> portable(String profileId) async {
    await _writes;
    return validatePortable(await _read(await _file(profileId)));
  }

  static Future<void> mergePortable(String profileId, Map<String, Map<String, Object?>> incoming,
      {required String expectedDigest, required Set<String> replaceKeys, required void Function() checkCurrent}) {
    final validated = validatePortable(incoming);
    if (!replaceKeys.every(validated.containsKey)) throw const FormatException('Invalid conflict choice.');
    final replacements = Set<String>.unmodifiable(replaceKeys);
    final next = _writes.then((_) async {
      checkCurrent();
      final file = await _file(profileId);
      final current = validatePortable(await _read(file));
      if (digest(current) != expectedDigest) throw StateError('Translation memory changed. Preview it again.');
      final merged = <String, dynamic>{...current};
      for (final entry in validated.entries) {
        if (!merged.containsKey(entry.key) || replacements.contains(entry.key)) merged[entry.key] = entry.value;
      }
      // An import never silently discards unrelated accepted translations.
      final checked = validatePortable(merged);
      checkCurrent();
      await _save(file, jsonEncode({'schema': 1, 'entries': checked}), checkCurrent: checkCurrent);
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  static Future<void> _save(File file, String encoded, {void Function()? checkCurrent}) async {
    final temporary = File('${file.path}.tmp'), backup = File('${file.path}.bak');
    var backedUp = false;
    try {
      await temporary.writeAsString(encoded, flush: true);
      checkCurrent?.call();
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        checkCurrent?.call();
        await file.rename(backup.path); backedUp = true;
      }
      try { checkCurrent?.call(); await temporary.rename(file.path); }
      catch (_) { if (backedUp && await backup.exists()) await backup.rename(file.path); rethrow; }
    } finally { if (await temporary.exists()) await temporary.delete(); }
  }

  static Future<void> remember({required String profileId, required String namespace,
    required List<SubtitleCue> source, required List<SubtitleCue> reviewed,
    required String backendLabel, required String itemIdentity}) {
    final next = _writes.then((_) async {
      final file = await _file(profileId);
      final entries = await _read(file);
      final reviewedById = {for (final cue in reviewed) cue.stableId: cue};
      final revisionDigest = digest(reviewed.map((c) => [c.stableId, c.startMs, c.endMs, c.text]).toList());
      for (var i = 0; i < source.length; i++) {
        final cue = reviewedById[source[i].stableId];
        if (cue == null || cue.text.trim().isEmpty || cue.text.length > 4000) continue;
        final key = _key(source, i, namespace);
        entries.remove(key); // insertion order is bounded LRU by accepted review.
        entries[key] = {'text': cue.text, 'sourceFingerprint': digest(source[i].text), 'namespace': namespace,
          'reviewRevision': revisionDigest, 'itemIdentity': itemIdentity, 'cueId': cue.stableId,
          'backend': backendLabel.length > 256 ? backendLabel.substring(0, 256) : backendLabel,
          'modelRevision': 'not-reported-by-local-translator', 'reviewedAt': DateTime.now().toUtc().toIso8601String()};
        if (entries.length > _maximumEntries) entries.remove(entries.keys.first);
      }
      var encoded = jsonEncode({'schema': 1, 'entries': entries});
      while (utf8.encode(encoded).length > _maximumBytes && entries.isNotEmpty) {
        // Trim in batches so a large track cannot cause quadratic serialization.
        for (final key in entries.keys.take(100).toList()) { entries.remove(key); }
        encoded = jsonEncode({'schema': 1, 'entries': entries});
      }
      await _save(file, encoded);
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  static Future<void> clear(String profileId) {
    final next = _writes.then((_) async {
      final file = await _file(profileId);
      for (final path in [file, File('${file.path}.bak'), File('${file.path}.tmp')]) {
        if (await path.exists()) await path.delete();
      }
    });
    _writes = next.catchError((Object _) {});
    return next;
  }
}
