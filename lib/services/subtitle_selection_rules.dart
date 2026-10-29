import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../profiles/active_profile_provider.dart';
import '../mpv/mpv.dart';
import '../utils/subtitle_forced_semantics.dart';
import 'settings_service.dart';

enum SubtitleForcedRule { any, full, forced }
enum SubtitleAccessRule { any, prefer, avoid }

class SubtitleRoleRules {
  const SubtitleRoleRules({this.forced = SubtitleForcedRule.any, this.accessibility = SubtitleAccessRule.any});
  final SubtitleForcedRule forced;
  final SubtitleAccessRule accessibility;
  bool acceptsForced(bool value) => switch (forced) {
    SubtitleForcedRule.any => true,
    SubtitleForcedRule.full => !value,
    SubtitleForcedRule.forced => value,
  };
  int accessRank(bool hearingImpaired) => switch (accessibility) {
    SubtitleAccessRule.any => 0,
    SubtitleAccessRule.prefer => hearingImpaired ? 0 : 1,
    SubtitleAccessRule.avoid => hearingImpaired ? 1 : 0,
  };
  List<SubtitleTrack> arrange(List<SubtitleTrack> tracks) {
    final indexed = [for (var i = 0; i < tracks.length; i++)
      if (tracks[i].id != SubtitleTrack.off.id && tracks[i].id != SubtitleTrack.auto.id &&
          acceptsForced(tracks[i].effectiveForced)) (i, tracks[i])];
    indexed.sort((a, b) {
      final rank = accessRank(a.$2.effectiveHearingImpaired).compareTo(accessRank(b.$2.effectiveHearingImpaired));
      return rank != 0 ? rank : a.$1.compareTo(b.$1);
    });
    return [for (final entry in indexed) entry.$2];
  }
  Map<String, String> toJson() => {'forced': forced.name, 'accessibility': accessibility.name};
  static SubtitleRoleRules fromJson(Object? value) {
    if (value is! Map) return const SubtitleRoleRules();
    try { return SubtitleRoleRules(forced: SubtitleForcedRule.values.byName(value['forced'] as String),
      accessibility: SubtitleAccessRule.values.byName(value['accessibility'] as String)); }
    catch (_) { return const SubtitleRoleRules(); }
  }
}

/// Synchronous reads use the already initialized settings cache. Profile scope
/// follows the application's active profile provider; there is no device-wide
/// role setting that can leak a different viewer's accessibility preferences.
abstract final class SubtitleSelectionRules {
  static ActiveProfileProvider? _profiles;
  static Future<void> _writes = Future.value();
  static void bindProfile(ActiveProfileProvider profiles) { _profiles = profiles; }
  static String? get activeProfileId => _profiles?.activeId;
  static String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
  static StringPref _preference(String profile) => StringPref('subtitle_selection_rules_v1_${_digest(profile)}');
  static String titleKey(String identity) => _digest(identity);

  static Map<String, dynamic> _data(String profile, SettingsService settings) {
    try {
      final text = settings.read(_preference(profile));
      if (text.length > 65536) return {};
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic> || value['schema'] != 1 || value['titles'] is! Map ||
          (value['titles'] as Map).length > 200) return {};
      return value;
    } catch (_) { return {}; }
  }

  static SubtitleRoleRules resolve({String? titleIdentity}) {
    final profile = activeProfileId, settings = SettingsService.instanceOrNull;
    if (profile == null || settings == null) return const SubtitleRoleRules();
    final data = _data(profile, settings), titles = data['titles'];
    final override = titleIdentity == null || titles is! Map ? null : titles[titleKey(titleIdentity)];
    return SubtitleRoleRules.fromJson(override ?? data['default']);
  }

  static bool hasOverride(String identity) {
    final profile = activeProfileId, settings = SettingsService.instanceOrNull;
    if (profile == null || settings == null) return false;
    return (_data(profile, settings)['titles'] as Map?)?.containsKey(titleKey(identity)) == true;
  }

  static Future<void> save(SubtitleRoleRules? rules, {required String profileId, String? titleIdentity,
      SubtitleRoleRules? expectedRules}) {
    final next = _writes.then((_) async {
      final settings = await SettingsService.getInstance();
      if (activeProfileId != profileId) throw StateError('Profile changed.');
      final data = _data(profileId, settings);
      final titles = Map<String, dynamic>.from(data['titles'] as Map? ?? {});
      if (expectedRules != null) {
        final current = SubtitleRoleRules.fromJson(titleIdentity == null ? data['default']
            : titles[titleKey(titleIdentity)] ?? data['default']);
        if (current.forced != expectedRules.forced || current.accessibility != expectedRules.accessibility) {
          throw StateError('The subtitle role preference changed. Preview it again.');
        }
      }
      if (titleIdentity == null) { data['default'] = (rules ?? const SubtitleRoleRules()).toJson(); }
      else {
        final key = titleKey(titleIdentity);
        if (rules == null) { titles.remove(key); }
        else {
          if (!titles.containsKey(key) && titles.length >= 200) throw StateError('Remove an earlier title override before adding another.');
          titles[key] = rules.toJson();
        }
      }
      final text = jsonEncode({'schema': 1, 'default': data['default'], 'titles': titles});
      if (utf8.encode(text).length > 65536) throw StateError('Subtitle preferences exceed their storage limit.');
      await settings.write(_preference(profileId), text, checkCurrent: () {
        if (activeProfileId != profileId) throw StateError('Profile changed.');
      });
    });
    _writes = next.catchError((Object _) {}); return next;
  }
}
