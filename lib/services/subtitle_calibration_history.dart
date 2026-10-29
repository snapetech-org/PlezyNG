import 'dart:convert';

import 'library_sync_correction.dart';
import 'settings_service.dart';
import 'subtitle_sync_calibration.dart';

final class SubtitleCalibrationRecord {
  const SubtitleCalibrationRecord({required this.savedAtMs, required this.value, required this.anchors});
  final int savedAtMs;
  final SubtitleSyncCalibration value;
  final List<SubtitleSyncAnchor> anchors;
  Map<String, Object> toJson() => {'savedAtMs': savedAtMs, 'delayMs': value.delayMs,
    'rate': value.timestampMultiplier,
    'anchors': [for (final anchor in anchors) [anchor.subtitleSeconds, anchor.playbackSeconds]]};
  static SubtitleCalibrationRecord? decode(Object? raw) {
    if (raw is! Map || raw['savedAtMs'] is! int || raw['anchors'] is! List) return null;
    final value = LibrarySyncValue.decode(raw);
    final entries = raw['anchors'] as List;
    if (value == null || entries.length > 12 || (raw['savedAtMs'] as int) < 0) return null;
    final anchors = <SubtitleSyncAnchor>[];
    for (final entry in entries) {
      if (entry is! List || entry.length != 2 || entry[0] is! num || entry[1] is! num) return null;
      final anchor = SubtitleSyncAnchor((entry[0] as num).toDouble(), (entry[1] as num).toDouble());
      if (!anchor.valid) return null;
      anchors.add(anchor);
    }
    return SubtitleCalibrationRecord(savedAtMs: raw['savedAtMs'] as int,
      value: SubtitleSyncCalibration(timestampMultiplier: value.rate, delayMs: value.delayMs),
      anchors: List.unmodifiable(anchors));
  }
}

/// Profile-local review history, separate from the active playback preference.
/// Reading it never applies timing. Callers bind its key to the exact source,
/// selected audio, subtitle lane and file-clock origin.
abstract final class SubtitleCalibrationHistory {
  static Future<void> _writes = Future.value();
  static const maximumBytes = 512 * 1024;
  static StringPref _pref(String profile) => StringPref('subtitle_calibration_history_v1_${LibrarySyncSource.digestOf(profile)}');
  static Map<String, List<SubtitleCalibrationRecord>> _read(String profile) {
    try {
      final text = SettingsService.instance.read(_pref(profile));
      if (utf8.encode(text).length > maximumBytes) return {};
      final raw = jsonDecode(text);
      if (raw is! Map || raw['schema'] != 1 || raw['scopes'] is! Map) return {};
      final scopes = raw['scopes'] as Map;
      if (scopes.length > 64) return {};
      final result = <String, List<SubtitleCalibrationRecord>>{};
      for (final entry in scopes.entries) {
        if (entry.key is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.key as String) ||
            entry.value is! List || (entry.value as List).length > 8) continue;
        result[entry.key as String] = (entry.value as List).map(SubtitleCalibrationRecord.decode)
          .whereType<SubtitleCalibrationRecord>().toList(growable: false);
      }
      return result;
    } catch (_) { return {}; }
  }
  static List<SubtitleCalibrationRecord> read(String profile, String key) =>
      List.unmodifiable(_read(profile)[key] ?? const <SubtitleCalibrationRecord>[]);

  static Future<void> append(String profile, String key, SubtitleSyncCalibration previous,
      SubtitleSyncCalibration next, List<SubtitleSyncAnchor> anchors, {required void Function() checkCurrent}) {
    final operation = _writes.then((_) async {
      checkCurrent();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) throw const FormatException('Invalid calibration history scope.');
      final now = DateTime.now().millisecondsSinceEpoch;
      final record = SubtitleCalibrationRecord(savedAtMs: now, value: next, anchors: List.unmodifiable(anchors));
      if (SubtitleCalibrationRecord.decode(record.toJson()) == null) throw const FormatException('Invalid calibration history.');
      final scopes = _read(profile);
      final records = List<SubtitleCalibrationRecord>.of(scopes[key] ?? const []);
      bool equal(SubtitleSyncCalibration a, SubtitleSyncCalibration b) => a.delayMs == b.delayMs &&
        (a.timestampMultiplier - b.timestampMultiplier).abs() < .000001;
      if (records.isEmpty || !equal(records.first.value, previous)) {
        records.insert(0, SubtitleCalibrationRecord(savedAtMs: now - 1, value: previous, anchors: const []));
      }
      records.insert(0, record);
      scopes[key] = records.take(8).toList(growable: false);
      final sorted = scopes.entries.toList()..sort((a, b) =>
        (b.value.isEmpty ? 0 : b.value.first.savedAtMs).compareTo(a.value.isEmpty ? 0 : a.value.first.savedAtMs));
      final retained = Map.fromEntries(sorted.take(64));
      String encode() => jsonEncode({'schema': 1, 'scopes': retained.map((k, v) => MapEntry(k, [for (final r in v) r.toJson()]))});
      var text = encode();
      while (utf8.encode(text).length > maximumBytes && retained.length > 1) {
        retained.remove(retained.keys.last); text = encode();
      }
      if (utf8.encode(text).length > maximumBytes) throw StateError('Calibration history exceeds its storage limit.');
      await SettingsService.instance.write(_pref(profile), text, checkCurrent: checkCurrent);
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }
}
