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
      final temporary = File('${file.path}.tmp'), backup = File('${file.path}.bak');
      await temporary.writeAsString(encoded, flush: true);
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
      }
      await temporary.rename(file.path);
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
