import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/subtitles/subtitle_search_result.dart';
import 'settings_service.dart';
import 'subtitle_selection_rules.dart';

/// Remembers provider subtitle revisions the viewer rejected so search and
/// automatic preferred-language downloads do not repeatedly offer the same row.
abstract final class SubtitleRejectionService {
  static const int maximumRememberedRevisions = 256;
  static const Duration retention = Duration(days: 180);

  static Future<void> _writeQueue = Future<void>.value();

  static String revisionKey({
    required String serverId,
    required String itemId,
    required int mediaIndex,
    required SubtitleSearchResult result,
    bool legacy = false,
  }) {
    final identity = <Object?>[
      serverId.trim(),
      itemId.trim(),
      mediaIndex,
      if (legacy) result.id,
      result.key.trim(),
      result.providerTitle?.trim().toLowerCase(),
      result.codec?.trim().toLowerCase(),
      (result.languageCode ?? result.language)?.trim().toLowerCase(),
      result.title?.trim(),
      result.displayTitle?.trim(),
      result.forced,
      result.hearingImpaired,
    ];
    return sha256.convert(utf8.encode(jsonEncode(identity))).toString();
  }

  static bool isRejected(
    SettingsService settings, {
    required String serverId,
    required String itemId,
    required int mediaIndex,
    required SubtitleSearchResult result,
  }) {
    if (result.key.trim().isEmpty) return false;
    try {
      final profile = SubtitleSelectionRules.activeProfileId;
      if (profile == null) return false;
      final rejected = _read(settings, profile);
      final timestamp = rejected[revisionKey(serverId: serverId, itemId: itemId, mediaIndex: mediaIndex, result: result)] ??
          rejected[revisionKey(serverId: serverId, itemId: itemId, mediaIndex: mediaIndex, result: result, legacy: true)];
      if (timestamp == null) return false;
      final now = DateTime.now().millisecondsSinceEpoch;
      final age = now - timestamp;
      return age >= 0 && age <= retention.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  static Future<void> reject(
    SettingsService settings, {
    required String serverId,
    required String itemId,
    required int mediaIndex,
    required SubtitleSearchResult result,
  }) {
    if (result.key.trim().isEmpty) return Future<void>.value();
    final key = revisionKey(serverId: serverId, itemId: itemId, mediaIndex: mediaIndex, result: result);
    final profile = SubtitleSelectionRules.activeProfileId;
    if (profile == null) return Future<void>.value();
    return _enqueueWrite(() async {
      void check() { if (SubtitleSelectionRules.activeProfileId != profile) throw StateError('Profile changed.'); }
      check();
      final now = DateTime.now().millisecondsSinceEpoch;
      final entries = _prune(_read(settings, profile), now);
      entries[key] = now;
      while (entries.length > maximumRememberedRevisions) {
        final oldest = entries.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
        entries.remove(oldest);
      }
      await _save(settings, profile, entries, check);
    });
  }

  static Future<void> restore(
    SettingsService settings, {
    required String serverId,
    required String itemId,
    required int mediaIndex,
    required SubtitleSearchResult result,
  }) {
    if (result.key.trim().isEmpty) return Future<void>.value();
    final key = revisionKey(serverId: serverId, itemId: itemId, mediaIndex: mediaIndex, result: result);
    final profile = SubtitleSelectionRules.activeProfileId;
    if (profile == null) return Future<void>.value();
    return _enqueueWrite(() async {
      void check() { if (SubtitleSelectionRules.activeProfileId != profile) throw StateError('Profile changed.'); }
      check();
      final now = DateTime.now().millisecondsSinceEpoch;
      final entries = _prune(_read(settings, profile), now);
      entries.remove(key);
      entries.remove(revisionKey(serverId: serverId, itemId: itemId, mediaIndex: mediaIndex, result: result, legacy: true));
      await _save(settings, profile, entries, check);
    });
  }

  static StringPref _pref(String profile) => StringPref(
    'subtitle_rejected_revisions_v2_${sha256.convert(utf8.encode(profile))}');

  static Map<String, int> _read(SettingsService settings, String profile) {
    try {
      final text = settings.read(_pref(profile));
      if (utf8.encode(text).length > 32768) return {};
      final raw = jsonDecode(text);
      if (raw is! Map || raw['schema'] != 2) return {};
      return validatePortable(raw['entries']);
    } catch (_) { return {}; }
  }

  static Map<String, int> validatePortable(Object? raw) {
    if (raw is! Map || raw.length > maximumRememberedRevisions) throw const FormatException('Rejected revision limit.');
    final valid = <String, int>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.key as String) ||
          entry.value is! int || (entry.value as int) < 0) throw const FormatException('Invalid rejected revision.');
      valid[entry.key as String] = entry.value as int;
    }
    final pruned = _prune(valid, DateTime.now().millisecondsSinceEpoch);
    final keys = pruned.keys.toList()..sort();
    return Map.unmodifiable({for (final key in keys) key: pruned[key]!});
  }

  static String portableDigest(Map<String, int> entries) {
    final keys = entries.keys.toList()..sort();
    return sha256.convert(utf8.encode(jsonEncode({for (final key in keys) key: entries[key]}))).toString();
  }

  static Future<Map<String, int>> portable(String profile) async {
    await _writeQueue;
    return _read(SettingsService.instance, profile);
  }

  /// Older data had no profile owner. It can only be claimed through the
  /// explicit import UI, never silently inherited by every active profile.
  static Map<String, int> legacyPortable() =>
      validatePortable(SettingsService.instance.read(SettingsService.subtitleRejectedRevisions));

  static Future<void> _save(SettingsService settings, String profile, Map<String, int> entries,
      void Function() checkCurrent) => settings.write(_pref(profile),
        jsonEncode({'schema': 2, 'entries': validatePortable(entries)}), checkCurrent: checkCurrent);

  static Future<void> mergePortable(String profile, Map<String, int> incoming,
      {required String expectedDigest, required void Function() checkCurrent}) {
    final checked = validatePortable(incoming);
    return _enqueueWrite(() async {
      checkCurrent();
      final settings = SettingsService.instance;
      final current = _read(settings, profile);
      if (portableDigest(current) != expectedDigest) throw StateError('Rejected revisions changed. Preview them again.');
      final merged = <String, int>{...current};
      for (final entry in checked.entries) {
        if ((merged[entry.key] ?? 0) < entry.value) merged[entry.key] = entry.value;
      }
      if (merged.length > maximumRememberedRevisions) throw StateError('Rejected revision import exceeds the retention limit.');
      await _save(settings, profile, merged, checkCurrent);
    });
  }

  static Future<void> _enqueueWrite(Future<void> Function() action) {
    final previous = _writeQueue;
    final operation = previous.catchError((Object _, StackTrace _) {}).then((_) => action());
    _writeQueue = operation.catchError((Object _, StackTrace _) {});
    return operation;
  }

  static Map<String, int> _prune(Map<String, int> source, int now) {
    final cutoff = now - retention.inMilliseconds;
    return <String, int>{
      for (final entry in source.entries)
        if (entry.value >= cutoff && entry.value <= now) entry.key: entry.value,
    };
  }
}
