import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'karaoke_models.dart';
import 'karaoke_store.dart';

const _showTemplateSchema = 1;
const _showTemplateStoreName = 'show-templates';
const maxKaraokeShowTemplates = 24;
const maxKaraokeShowTemplateReferences = 10000;

class KaraokeShowTemplateRendition {
  const KaraokeShowTemplateRendition({required this.id, required this.fingerprint});

  final String id;
  final String fingerprint;

  factory KaraokeShowTemplateRendition.fromTrack(KaraokeTrack track) =>
      KaraokeShowTemplateRendition(id: track.id, fingerprint: _renditionFingerprint(track));

  factory KaraokeShowTemplateRendition.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final fingerprint = json['fingerprint'];
    if (json.keys.toSet().difference({'id', 'fingerprint'}).isNotEmpty ||
        id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        fingerprint is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('Invalid show-template rendition reference');
    }
    return KaraokeShowTemplateRendition(id: id, fingerprint: fingerprint);
  }

  Map<String, dynamic> toJson() => {'id': id, 'fingerprint': fingerprint};

  bool matches(KaraokeTrack? track) => track != null && track.id == id && _renditionFingerprint(track) == fingerprint;
}

String _renditionFingerprint(KaraokeTrack track) {
  final assets =
      track.assets
          .map(
            (asset) => {
              'path': asset.path,
              'sha256': asset.sha256,
              'bytes': asset.bytes,
              'kind': asset.kind.name,
              'part': asset.part,
              'clockId': asset.clockId,
            },
          )
          .toList()
        ..sort((a, b) {
          for (final key in ['path', 'sha256', 'kind', 'part', 'clockId']) {
            final comparison = (a[key] as String? ?? '').compareTo(b[key] as String? ?? '');
            if (comparison != 0) return comparison;
          }
          return (a['bytes'] as int).compareTo(b['bytes'] as int);
        });
  final identity = jsonEncode({
    'id': track.id,
    'songId': track.songId,
    'providerId': track.providerId,
    'durationMs': track.durationMs,
    'lyricOffsetMs': track.lyricOffsetMs,
    'introTrimEndMs': track.introTrimEndMs,
    'outroTrimStartMs': track.outroTrimStartMs,
    'explicit': track.explicit,
    'assets': assets,
  });
  return sha256.convert(utf8.encode(identity)).toString();
}

typedef ResolvedKaraokeShowTemplate = ({Map<String, List<String>> setlists, List<String> fillerTrackIds});

class KaraokeShowTemplateRenditionsUnavailable implements Exception {
  const KaraokeShowTemplateRenditionsUnavailable(this.count);
  final int count;
}

class KaraokeShowTemplateApplyBlocked implements Exception {
  const KaraokeShowTemplateApplyBlocked();
}

class KaraokeShowTemplateNameConflict implements Exception {
  const KaraokeShowTemplateNameConflict();
}

class KaraokeShowTemplateLimitReached implements Exception {
  const KaraokeShowTemplateLimitReached();
}

class KaraokeShowTemplateReferenceLimitReached implements Exception {
  const KaraokeShowTemplateReferenceLimitReached();
}

class KaraokeShowTemplate {
  const KaraokeShowTemplate({
    required this.id,
    required this.name,
    required this.setlists,
    required this.fillerRenditions,
    required this.fairRotation,
    required this.allowExplicit,
    required this.requireApproval,
    required this.allowVotes,
    required this.perSingerLimit,
    required this.banner,
    required this.stageColor,
    required this.stageTextScale,
    required this.displayOffsetMs,
  });

  final String id;
  final String name;
  final Map<String, List<KaraokeShowTemplateRendition>> setlists;
  final List<KaraokeShowTemplateRendition> fillerRenditions;
  final bool fairRotation;
  final bool allowExplicit;
  final bool requireApproval;
  final bool allowVotes;
  final int perSingerLimit;
  final String banner;
  final int stageColor;
  final double stageTextScale;
  final int displayOffsetMs;

  int get renditionCount => fillerRenditions.length + setlists.values.fold(0, (sum, values) => sum + values.length);

  int unavailableRenditionCount(Map<String, KaraokeTrack> catalog) => [
    ...setlists.values.expand((values) => values),
    ...fillerRenditions,
  ].where((reference) => !reference.matches(catalog[reference.id])).length;

  factory KaraokeShowTemplate.capture({
    String? id,
    required String name,
    required Map<String, List<String>> setlists,
    required Map<String, KaraokeTrack> catalog,
    required List<String> fillerTrackIds,
    required bool fairRotation,
    required bool allowExplicit,
    required bool requireApproval,
    required bool allowVotes,
    required int perSingerLimit,
    required String banner,
    required int stageColor,
    required double stageTextScale,
    required int displayOffsetMs,
  }) {
    List<KaraokeShowTemplateRendition> references(List<String> ids) {
      if (ids.toSet().length != ids.length) {
        throw const FormatException('A show-template setlist contains duplicate renditions');
      }
      final unavailable = ids.where((id) => catalog[id] == null).length;
      if (unavailable > 0) {
        throw KaraokeShowTemplateRenditionsUnavailable(unavailable);
      }
      return ids.map((id) {
        return KaraokeShowTemplateRendition.fromTrack(catalog[id]!);
      }).toList();
    }

    final template = KaraokeShowTemplate(
      id: id ?? const Uuid().v4(),
      name: name.trim(),
      setlists: {for (final entry in setlists.entries) entry.key: references(entry.value)},
      fillerRenditions: references(fillerTrackIds),
      fairRotation: fairRotation,
      allowExplicit: allowExplicit,
      requireApproval: requireApproval,
      allowVotes: allowVotes,
      perSingerLimit: perSingerLimit,
      banner: banner,
      stageColor: stageColor,
      stageTextScale: stageTextScale,
      displayOffsetMs: displayOffsetMs,
    );
    return KaraokeShowTemplate.fromJson(template.toJson());
  }

  factory KaraokeShowTemplate.fromJson(Map<String, dynamic> json) {
    const keys = {
      'schema',
      'id',
      'name',
      'setlists',
      'fillerRenditions',
      'fairRotation',
      'allowExplicit',
      'requireApproval',
      'allowVotes',
      'perSingerLimit',
      'banner',
      'stageColor',
      'stageTextScale',
      'displayOffsetMs',
    };
    if (json.keys.toSet().difference(keys).isNotEmpty || json['schema'] != _showTemplateSchema) {
      throw const FormatException('Unsupported show template');
    }

    final id = json['id'];
    final name = json['name'];
    final rawSetlists = json['setlists'];
    final rawFillers = json['fillerRenditions'];
    final fairRotation = json['fairRotation'];
    final allowExplicit = json['allowExplicit'];
    final requireApproval = json['requireApproval'];
    final allowVotes = json['allowVotes'];
    final perSingerLimit = json['perSingerLimit'];
    final banner = json['banner'];
    final stageColor = json['stageColor'];
    final stageTextScale = json['stageTextScale'];
    final displayOffsetMs = json['displayOffsetMs'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 80 ||
        name != name.trim() ||
        rawSetlists is! Map ||
        rawSetlists.length > 100 ||
        rawFillers is! List ||
        rawFillers.length > 16 ||
        fairRotation is! bool ||
        allowExplicit is! bool ||
        requireApproval is! bool ||
        allowVotes is! bool ||
        perSingerLimit is! int ||
        perSingerLimit < 1 ||
        perSingerLimit > 10 ||
        banner is! String ||
        banner.length > 160 ||
        stageColor is! int ||
        stageColor < 0 ||
        stageColor > 0xffffffff ||
        stageTextScale is! num ||
        !stageTextScale.isFinite ||
        stageTextScale < .75 ||
        stageTextScale > 2 ||
        displayOffsetMs is! int ||
        displayOffsetMs < -2000 ||
        displayOffsetMs > 2000) {
      throw const FormatException('Invalid show template');
    }

    final setlists = <String, List<KaraokeShowTemplateRendition>>{};
    final setlistNames = <String>{};
    var referenceCount = 0;
    for (final entry in rawSetlists.entries) {
      final name = entry.key;
      final list = entry.value;
      if (name is! String ||
          name.trim().isEmpty ||
          name.trim().length > 100 ||
          name != name.trim() ||
          !setlistNames.add(name) ||
          list is! List ||
          list.length > 256) {
        throw const FormatException('Invalid show-template setlist');
      }
      final references = list
          .map((value) => KaraokeShowTemplateRendition.fromJson(Map<String, dynamic>.from(value as Map)))
          .toList();
      if (references.map((reference) => reference.id).toSet().length != references.length) {
        throw const FormatException('Duplicate rendition in show-template setlist');
      }
      setlists[name] = references;
      referenceCount += references.length;
    }
    final fillerRenditions = rawFillers
        .map((value) => KaraokeShowTemplateRendition.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
    if (fillerRenditions.map((reference) => reference.id).toSet().length != fillerRenditions.length) {
      throw const FormatException('Duplicate show-template filler rendition');
    }
    referenceCount += fillerRenditions.length;
    if (referenceCount > maxKaraokeShowTemplateReferences) {
      throw const FormatException('Show-template rendition limit exceeded');
    }
    return KaraokeShowTemplate(
      id: id,
      name: name,
      setlists: setlists,
      fillerRenditions: fillerRenditions,
      fairRotation: fairRotation,
      allowExplicit: allowExplicit,
      requireApproval: requireApproval,
      allowVotes: allowVotes,
      perSingerLimit: perSingerLimit,
      banner: banner,
      stageColor: stageColor,
      stageTextScale: stageTextScale.toDouble(),
      displayOffsetMs: displayOffsetMs,
    );
  }

  ResolvedKaraokeShowTemplate resolve(Map<String, KaraokeTrack> catalog) {
    var unavailable = 0;
    List<String> ids(List<KaraokeShowTemplateRendition> references) {
      final result = <String>[];
      for (final reference in references) {
        if (!reference.matches(catalog[reference.id])) {
          unavailable++;
        } else {
          result.add(reference.id);
        }
      }
      return result;
    }

    final resolvedSetlists = {for (final entry in setlists.entries) entry.key: ids(entry.value)};
    final resolvedFillers = ids(fillerRenditions);
    if (unavailable != 0) {
      throw KaraokeShowTemplateRenditionsUnavailable(unavailable);
    }
    if (resolvedFillers.any((id) => !catalog[id]!.hasBacking)) {
      throw const FormatException('A show-template filler is no longer instrumental');
    }
    return (setlists: resolvedSetlists, fillerTrackIds: resolvedFillers);
  }

  Map<String, dynamic> toJson() => {
    'schema': _showTemplateSchema,
    'id': id,
    'name': name,
    'setlists': {
      for (final entry in setlists.entries) entry.key: entry.value.map((reference) => reference.toJson()).toList(),
    },
    'fillerRenditions': fillerRenditions.map((reference) => reference.toJson()).toList(),
    'fairRotation': fairRotation,
    'allowExplicit': allowExplicit,
    'requireApproval': requireApproval,
    'allowVotes': allowVotes,
    'perSingerLimit': perSingerLimit,
    'banner': banner,
    'stageColor': stageColor,
    'stageTextScale': stageTextScale,
    'displayOffsetMs': displayOffsetMs,
  };
}

class KaraokeShowTemplateLibrary {
  KaraokeShowTemplateLibrary(this.store);
  final KaraokeStore store;

  Future<List<KaraokeShowTemplate>> load() async {
    final json = await store.read(_showTemplateStoreName);
    if (json == null) return const [];
    if (json.keys.toSet().difference({'schema', 'templates'}).isNotEmpty ||
        json['schema'] != _showTemplateSchema ||
        json['templates'] is! List) {
      throw const FormatException('Unsupported show-template library');
    }
    final values = (json['templates'] as List)
        .map((value) => KaraokeShowTemplate.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
    if (values.length > maxKaraokeShowTemplates ||
        values.map((template) => template.id).toSet().length != values.length ||
        values.map((template) => template.name.toLowerCase()).toSet().length != values.length ||
        values.fold<int>(0, (sum, template) => sum + template.renditionCount) > maxKaraokeShowTemplateReferences) {
      throw const FormatException('Invalid show-template library');
    }
    return List.unmodifiable(values);
  }

  Future<void> save(KaraokeShowTemplate template) async {
    final validated = KaraokeShowTemplate.fromJson(template.toJson());
    final existing = await load();
    final matches = existing.indexWhere((value) => value.id == validated.id);
    if (matches < 0 && existing.length >= maxKaraokeShowTemplates) {
      throw const KaraokeShowTemplateLimitReached();
    }
    if (existing.any((value) => value.id != validated.id && value.name.toLowerCase() == validated.name.toLowerCase())) {
      throw const KaraokeShowTemplateNameConflict();
    }
    final updated = [...existing];
    if (matches < 0) {
      updated.add(validated);
    } else {
      updated[matches] = validated;
    }
    if (updated.fold<int>(0, (sum, value) => sum + value.renditionCount) > maxKaraokeShowTemplateReferences) {
      throw const KaraokeShowTemplateReferenceLimitReached();
    }
    await store.write(_showTemplateStoreName, {
      'schema': _showTemplateSchema,
      'templates': updated.map((value) => value.toJson()).toList(),
    });
  }

  Future<void> remove(String id) async {
    final existing = await load();
    final updated = existing.where((template) => template.id != id).toList();
    if (updated.length == existing.length) return;
    await store.write(_showTemplateStoreName, {
      'schema': _showTemplateSchema,
      'templates': updated.map((value) => value.toJson()).toList(),
    });
  }
}
