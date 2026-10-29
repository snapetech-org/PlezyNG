import 'dart:convert';
import 'dart:typed_data';

import 'subtitle_font_store.dart';
import 'subtitle_overlay_service.dart';
import 'subtitle_selection_rules.dart';

/// A small allowlisted preference document. It carries no profile/account/title
/// IDs, file paths, fonts, captions, timing corrections or pairing secrets.
class SubtitlePortableDefaults {
  SubtitlePortableDefaults._(this.lanes, this.roles);
  static const maximumBytes = 16384;
  final List<Map<String, Object>> lanes;
  final SubtitleRoleRules roles;
  static const _schema = 'plezyng.subtitle-defaults.v1';

  static SubtitlePortableDefaults capture(String profile, bool Function() isCurrent) {
    if (!isCurrent() || SubtitleSelectionRules.activeProfileId != profile) throw StateError('Profile changed.');
    return SubtitlePortableDefaults._(List.unmodifiable([for (var lane = 0; lane < 2; lane++)
      Map<String, Object>.unmodifiable((SubtitleOverlayTrack(cues: const [], title: '',
        isCurrent: isCurrent, profileId: profile)..restoreAppearance(lane)).appearance())]), SubtitleSelectionRules.resolve());
  }

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({'schema': _schema,
    'lanes': lanes, 'roles': roles.toJson()})));

  static SubtitlePortableDefaults decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maximumBytes) throw const FormatException('Caption defaults must be at most 16 KiB.');
    final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (value is! Map<String, dynamic> || value['schema'] != _schema || value.length != 3 ||
        value['lanes'] is! List || (value['lanes'] as List).length != 2 || value['roles'] is! Map) {
      throw const FormatException('Unsupported caption defaults document.');
    }
    final roles = value['roles'] as Map;
    if (roles.length != 2 || !SubtitleForcedRule.values.any((v) => v.name == roles['forced']) ||
        !SubtitleAccessRule.values.any((v) => v.name == roles['accessibility'])) {
      throw const FormatException('Unsupported subtitle role preference.');
    }
    final lanes = <Map<String, Object>>[];
    for (final raw in value['lanes'] as List) {
      if (raw is! Map<String, dynamic>) throw const FormatException('Invalid caption appearance.');
      final template = SubtitleOverlayTrack(cues: const [], title: '', isCurrent: () => true);
      final keys = template.appearance().keys.toSet();
      if (raw.length != keys.length || raw.keys.any((key) => !keys.contains(key))) {
        throw const FormatException('Unsupported caption appearance fields.');
      }
      for (final bounds in <String, (double, double)>{'fontSize': (16, 64), 'position': (.05, .95),
        'backgroundOpacity': (0, 1), 'outlineWidth': (0, 5), 'margin': (.02, .2), 'overscan': (0, .15)}.entries) {
        final n = raw[bounds.key];
        if (n is! num || !n.isFinite || n < bounds.value.$1 || n > bounds.value.$2) {
          throw const FormatException('Caption appearance number is out of range.');
        }
      }
      for (final key in ['color', 'outline', 'backgroundColor']) {
        final n = raw[key];
        if (n is! int || n < 0 || n > 0xffffffff) throw const FormatException('Invalid caption color.');
      }
      for (final key in ['karaoke', 'ruby', 'bold', 'italic', 'videoAnchored']) {
        if (raw[key] is! bool) throw const FormatException('Invalid caption appearance flag.');
      }
      final font = raw['fontFamily'];
      if (font is! String || !(SubtitleOverlayTrack.fonts.contains(font) || SubtitleFontStore.familyPattern.hasMatch(font)) ||
          !const ['left', 'center', 'right', 'start', 'end'].contains(raw['alignment']) ||
          !const ['horizontal', 'vertical-lr', 'vertical-rl'].contains(raw['writingMode'])) {
        throw const FormatException('Unsupported caption font or layout.');
      }
      template.applyAppearance(raw);
      lanes.add(Map.unmodifiable(template.appearance()));
    }
    return SubtitlePortableDefaults._(List.unmodifiable(lanes), SubtitleRoleRules.fromJson(roles));
  }

  Future<void> importLane(int lane, {required String profile, required bool Function() isCurrent,
      required SubtitlePortableDefaults expected}) async {
    if (lane < 0 || lane > 1 || !isCurrent() || SubtitleSelectionRules.activeProfileId != profile) {
      throw StateError('Profile changed.');
    }
    final track = SubtitleOverlayTrack(cues: const [], title: '', profileId: profile,
      isCurrent: () => isCurrent() && SubtitleSelectionRules.activeProfileId == profile)
      ..applyAppearance(Map<String, dynamic>.from(lanes[lane]));
    await track.saveAppearance(lane, expectedAppearance: expected.lanes[lane]);
  }

  Future<void> importRoles({required String profile, required bool Function() isCurrent,
      required SubtitlePortableDefaults expected}) async {
    if (!isCurrent()) throw StateError('Profile changed.');
    await SubtitleSelectionRules.save(roles, profileId: profile, expectedRules: expected.roles);
  }
}
