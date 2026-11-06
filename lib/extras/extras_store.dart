import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../services/base_shared_preferences_service.dart';
import '../services/credential_vault.dart';
import 'extras_models.dart';

/// All preferences, personal links, exclusions and progress belong to the
/// captured profile. A late response can never write into the newly active one.
class ExtrasStore {
  ExtrasStore(this.profileId);
  final String profileId;
  String get _scope => sha256.convert(utf8.encode(profileId)).toString();
  String get _key => 'extras_v1_$_scope';
  String get _secretKey => 'user_${_scope}_extras_credentials_v1';
  static final _writes = <String, Future<void>>{};

  Future<Map<String, dynamic>> _read() async {
    final raw = (await BaseSharedPreferencesService.sharedCache()).getString(_key);
    if (raw == null || raw.length > 3 * 1024 * 1024) return {};
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? json : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> _mutate(void Function(Map<String, dynamic>) edit) async {
    final previous = _writes[_key];
    final future = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          /* next write may repair transient failure */
        }
      }
      final data = await _read();
      edit(data);
      final encoded = jsonEncode(data);
      if (encoded.length > 3 * 1024 * 1024) {
        throw StateError('Extras storage limit exceeded');
      }
      await (await BaseSharedPreferencesService.sharedCache()).setString(_key, encoded);
    }();
    _writes[_key] = future;
    try {
      await future;
    } finally {
      if (identical(_writes[_key], future)) {
        unawaited(_writes.remove(_key));
      }
    }
  }

  Future<ExtrasPreferences> preferences() async {
    final data = (await _read())['preferences'];
    return data is Map ? ExtrasPreferences.fromJson(data) : const ExtrasPreferences();
  }

  Future<void> savePreferences(ExtrasPreferences value) => _mutate((data) => data['preferences'] = value.toJson());
  Future<void> exclude(ExtrasSubject subject, ExtraEntry entry, String action) => _mutate((data) {
    var prefs = ExtrasPreferences.fromJson(data['preferences'] is Map ? data['preferences'] as Map : {});
    prefs = switch (action) {
      'publisher' => prefs.copyWith(hiddenPublishers: {...prefs.hiddenPublishers, entry.publisherId}),
      'wrong' => prefs.copyWith(wrongMatches: {...prefs.wrongMatches, '${subject.key}|${entry.id}'}),
      _ => prefs.copyWith(hiddenIds: {...prefs.hiddenIds, entry.id}),
    };
    data['preferences'] = prefs.toJson();
  });
  Future<List<ExtraEntry>> personalEntries() async => ((await _read())['personal'] as List? ?? const [])
      .map((raw) => ExtraEntry.parse(raw, userAdded: true))
      .whereType<ExtraEntry>()
      .toList();
  Future<void> add(ExtraEntry entry) => _mutate((data) {
    final entries = (data['personal'] as List? ?? []).where((e) => e is Map && e['id'] != entry.id).toList();
    if (entries.length >= 500) {
      throw StateError('Personal extras limit reached');
    }
    data['personal'] = [...entries, entry.toJson()];
  });
  Future<void> removePersonal(String id) => _mutate((data) {
    data['personal'] = (data['personal'] as List? ?? []).where((e) => e is Map && e['id'] != id).toList();
  });
  Future<String> secret(String name) async {
    final raw = (await BaseSharedPreferencesService.sharedCache()).getString(_secretKey);
    if (raw == null) return '';
    final plain = await CredentialVault.reveal(raw);
    if (plain == null) throw StateError('Extras credentials unavailable');
    final data = jsonDecode(plain);
    return data is Map && data[name] is String ? data[name] as String : '';
  }

  Future<void> saveSecrets({required String discovery, required String ai}) async {
    final encrypted = await CredentialVault.protect(jsonEncode({'discovery': discovery, 'ai': ai}));
    await (await BaseSharedPreferencesService.sharedCache()).setString(_secretKey, encrypted);
  }

  Future<({List<ExtraEntry> entries, DateTime fetched})?> cache(String key) async {
    final all = (await _read())['cache'];
    final item = all is Map ? all[key] : null;
    if (item is! Map || item['fetched'] is! int || item['entries'] is! List) {
      return null;
    }
    final fetched = DateTime.fromMillisecondsSinceEpoch(item['fetched'] as int);
    final age = DateTime.now().difference(fetched);
    if (age.isNegative || age > const Duration(days: 29)) {
      await _mutate((data) {
        if (data['cache'] is Map) (data['cache'] as Map).remove(key);
      });
      return null;
    }
    return (
      entries: (item['entries'] as List).map(ExtraEntry.parse).whereType<ExtraEntry>().toList(),
      fetched: fetched,
    );
  }

  Future<void> saveCache(String key, List<ExtraEntry> entries) => _mutate((data) {
    final cache = Map<String, dynamic>.from(data['cache'] is Map ? data['cache'] as Map : {});
    final cutoff = DateTime.now().subtract(const Duration(days: 29)).millisecondsSinceEpoch;
    cache.removeWhere((_, v) => v is! Map || v['fetched'] is! int || (v['fetched'] as int) < cutoff);
    cache.remove(key);
    final value = {
      'fetched': DateTime.now().millisecondsSinceEpoch,
      'entries': entries.take(80).map((e) => e.toJson()).toList(),
    };
    if (jsonEncode(value).length < 256 * 1024) cache[key] = value;
    while (cache.length > 24 || jsonEncode(cache).length > 1024 * 1024) {
      cache.remove(cache.keys.first);
    }
    data['cache'] = cache;
  });
  Future<Map<String, dynamic>> progress(String id) async {
    final data = (await _read())['progress'];
    return data is Map && data[id] is Map ? Map<String, dynamic>.from(data[id] as Map) : {};
  }

  Future<void> recordProgress(String id, {int? seconds, bool completed = false}) => _mutate((data) {
    final all = Map<String, dynamic>.from(data['progress'] is Map ? data['progress'] as Map : {});
    final previous = all.remove(id);
    all[id] = {
      'opened': DateTime.now().millisecondsSinceEpoch,
      'seconds': seconds?.clamp(0, 86400) ?? (previous is Map ? previous['seconds'] : null),
      'completed': completed || (previous is Map && previous['completed'] == true),
    };
    while (all.length > 500) {
      all.remove(all.keys.first);
    }
    data['progress'] = all;
  });
  Future<List<ExtraPassage>?> transcript(String id) async {
    final data = (await _read())['transcripts'];
    final value = data is Map ? data[id] : null;
    return value is List ? value.map(ExtraPassage.parse).whereType<ExtraPassage>().toList() : null;
  }

  Future<void> saveTranscript(String id, List<ExtraPassage> passages) => _mutate((data) {
    final all = Map<String, dynamic>.from(data['transcripts'] is Map ? data['transcripts'] as Map : {});
    all.remove(id);
    all[id] = passages.take(500).map((p) => p.toJson()).toList();
    if (jsonEncode(all[id]).length > 256 * 1024) throw StateError('Transcript too large');
    while (all.length > 20 || jsonEncode(all).length > 512 * 1024) {
      all.remove(all.keys.first);
    }
    data['transcripts'] = all;
  });
  Future<void> clear() async {
    final pending = _writes[_key];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        /* Still remove. */
      }
    }
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.remove(_key);
    await prefs.remove(_secretKey);
  }

  static Future<void> clearAll() async {
    for (final pending in List<Future<void>>.of(_writes.values)) {
      try {
        await pending;
      } catch (_) {
        /* Still remove. */
      }
    }
    final prefs = await BaseSharedPreferencesService.sharedCache();
    for (final key
        in prefs.keys.where((key) => key.startsWith('extras_v1_') || key.endsWith('_extras_credentials_v1')).toList()) {
      await prefs.remove(key);
    }
  }

  Future<void> clearCache() => _mutate((data) => data.remove('cache'));
}
