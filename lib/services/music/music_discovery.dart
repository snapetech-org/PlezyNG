import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../../database/app_database.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';

/// Optional protocol capability. A successful empty response means no analysis
/// matches; authorization and transport errors must remain errors.
abstract interface class SonicMusicClient {
  Future<List<MediaItem>> sonicallySimilar(String itemId, {int limit = 50, double maxDistance = .25});
  Future<List<MediaItem>> sonicPath({required String libraryId, required String startId, required String endId});
}

enum MusicRecipeKind { mix, adventure }

/// Durable, account-neutral description. No URLs, headers or credentials.
class MusicRecipe {
  final String id;
  final String title;
  final MusicRecipeKind kind;
  final List<MediaItem> seeds;
  final int limit;

  MusicRecipe({
    required this.id,
    required this.title,
    required this.kind,
    required List<MediaItem> seeds,
    this.limit = 100,
  }) : seeds = List.unmodifiable(seeds) {
    if (id.isEmpty || title.trim().isEmpty || seeds.isEmpty || seeds.length > 20 || limit < 1 || limit > 500) {
      throw ArgumentError('A music recipe needs 1–20 seeds and 1–500 tracks');
    }
    if (seeds.any(
      (s) => s.serverId == null || !const [MediaKind.track, MediaKind.artist, MediaKind.album].contains(s.kind),
    )) {
      throw ArgumentError('Seeds must identify playable music on a server');
    }
    if (kind == MusicRecipeKind.adventure && (seeds.length < 2 || seeds.any((s) => s.kind != MediaKind.track))) {
      throw ArgumentError('An adventure needs at least two track waypoints');
    }
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'kind': kind.name,
    'seeds': seeds
        .map(
          (s) => MediaItem(
            id: s.id,
            backend: s.backend,
            kind: s.kind,
            title: s.title,
            serverId: s.serverId,
            serverName: s.serverName,
            libraryId: s.libraryId,
            libraryTitle: s.libraryTitle,
            parentId: s.parentId,
            parentTitle: s.parentTitle,
            index: s.index,
            durationMs: s.durationMs,
          ).toJson(),
        )
        .toList(),
    'limit': limit,
  };

  factory MusicRecipe.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported music recipe');
    }
    return MusicRecipe(
      id: json['id'] as String,
      title: json['title'] as String,
      kind: MusicRecipeKind.values.byName(json['kind'] as String),
      seeds: (json['seeds'] as List).map((s) => MediaItem.fromJson(Map<String, dynamic>.from(s as Map))).toList(),
      limit: json['limit'] as int,
    );
  }
}

/// Uses only authorized clients supplied by the current profile. Every seed is
/// qualified by server; identical local IDs on two servers never collide.
class MusicDiscovery {
  MusicDiscovery(this.clientFor);
  final MediaServerClient? Function(MediaItem) clientFor;

  Future<List<MediaItem>> generate(MusicRecipe recipe) async {
    if (recipe.kind == MusicRecipeKind.adventure) return _adventure(recipe);
    final pools = <List<MediaItem>>[];
    for (final seed in recipe.seeds) {
      final client = clientFor(seed);
      if (client == null) throw StateError('Music server is unavailable');
      pools.add(await client.fetchInstantMix(seed.id, limit: recipe.limit));
    }
    return interleave(pools, limit: recipe.limit);
  }

  Future<List<MediaItem>> _adventure(MusicRecipe recipe) async {
    final first = recipe.seeds.first;
    final library = first.libraryId;
    if (library == null || recipe.seeds.any((s) => s.serverId != first.serverId || s.libraryId != library)) {
      throw ArgumentError('Adventure waypoints must belong to the same music library');
    }
    final client = clientFor(first);
    if (client is! SonicMusicClient) {
      throw UnsupportedError('This server does not support sonic paths');
    }
    final result = <MediaItem>[];
    for (var i = 1; i < recipe.seeds.length; i++) {
      final segment = await (client as SonicMusicClient).sonicPath(
        libraryId: library,
        startId: recipe.seeds[i - 1].id,
        endId: recipe.seeds[i].id,
      );
      if (segment.isEmpty) return [];
      for (final track in segment) {
        if (track.kind != MediaKind.track) continue;
        if (result.isEmpty || result.last.globalKey != track.globalKey) {
          result.add(track);
        }
      }
      // Truncating an adventure would silently discard its destination.
      if (result.length > recipe.limit) {
        throw StateError('Adventure exceeds the selected track budget');
      }
    }
    return result;
  }

  static List<MediaItem> interleave(List<List<MediaItem>> pools, {required int limit, Set<String> exclude = const {}}) {
    final result = <MediaItem>[];
    final seen = {...exclude};
    var index = 0;
    while (result.length < limit && pools.any((p) => index < p.length)) {
      for (final pool in pools) {
        if (index >= pool.length) continue;
        final track = pool[index];
        if (track.kind == MediaKind.track && seen.add(track.globalKey)) {
          result.add(track);
        }
        if (result.length == limit) break;
      }
      index++;
    }
    return result;
  }
}

class MusicRecipeStore {
  MusicRecipeStore(this.database, this.profileId);
  final AppDatabase database;
  final String profileId;

  Future<void> save(MusicRecipe recipe) => database.customStatement(
    'INSERT INTO music_recipes (profile_id, id, recipe, updated_at) VALUES (?, ?, ?, ?) '
    'ON CONFLICT(profile_id, id) DO UPDATE SET recipe = excluded.recipe, updated_at = excluded.updated_at',
    [profileId, recipe.id, jsonEncode(recipe.toJson()), DateTime.now().millisecondsSinceEpoch],
  );

  Future<List<MusicRecipe>> load() async {
    final rows = await database
        .customSelect(
          'SELECT recipe FROM music_recipes WHERE profile_id = ? ORDER BY updated_at DESC',
          variables: [Variable<String>(profileId)],
        )
        .get();
    final result = <MusicRecipe>[];
    for (final row in rows) {
      try {
        result.add(MusicRecipe.fromJson(jsonDecode(row.read<String>('recipe')) as Map<String, dynamic>));
      } on FormatException {
        continue;
      } on ArgumentError {
        continue;
      } on TypeError {
        continue;
      }
    }
    return result;
  }

  Future<void> delete(String id) =>
      database.customStatement('DELETE FROM music_recipes WHERE profile_id = ? AND id = ?', [profileId, id]);
}
