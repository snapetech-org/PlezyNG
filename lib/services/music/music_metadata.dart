import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import 'music_account_scope.dart';

enum MusicCreditKind { artist, writer, producer, composer, contributor }

class MusicCredit {
  const MusicCredit(this.kind, this.name, [this.role]);
  final MusicCreditKind kind;
  final String name;
  final String? role;
}

List<MusicCredit> musicCredits(MediaItem item) {
  final result = <MusicCredit>[];
  final seen = <(MusicCreditKind, String, String?)>{};
  void add(MusicCreditKind kind, String? name, [String? role]) {
    final value = name?.trim();
    if (value == null || value.isEmpty) return;
    final creditRole = role?.trim();
    if (seen.add((kind, value, creditRole))) result.add(MusicCredit(kind, value, creditRole));
  }

  add(MusicCreditKind.artist, item.trackArtistTitle ?? item.parentTitle);
  for (final name in item.writers ?? const <String>[]) {
    add(MusicCreditKind.writer, name);
  }
  for (final name in item.producers ?? const <String>[]) {
    add(MusicCreditKind.producer, name);
  }
  for (final person in item.roles ?? []) {
    add(MusicCreditKind.contributor, person.tag, person.role);
  }
  final people = item.raw?['People'];
  if (people is List) {
    for (final person in people.whereType<Map>()) {
      final name = person['Name'];
      if (name is! String) continue;
      final kind = switch (person['Type']) {
        'Composer' => MusicCreditKind.composer,
        'Lyricist' || 'Writer' => MusicCreditKind.writer,
        'Producer' => MusicCreditKind.producer,
        'Artist' => MusicCreditKind.artist,
        _ => MusicCreditKind.contributor,
      };
      add(kind, name, person['Role'] is String ? person['Role'] as String : null);
    }
  }
  return List.unmodifiable(result);
}

Future<MediaItem> loadMusicMetadata({
  required MediaItem item,
  required MediaServerClient? Function() clientFor,
  required bool Function() isCurrent,
}) async {
  final client = clientFor();
  if (client == null || !isCurrent()) throw StateError('Music source unavailable');
  final authentication = client.authenticationSessionId;
  final scope = musicAccountScope(client);
  final loaded = await client.fetchItem(item.id);
  if (!isCurrent() ||
      !identical(client, clientFor()) ||
      !identical(authentication, client.authenticationSessionId) ||
      scope != musicAccountScope(client)) {
    throw StateError('Music source changed');
  }
  if (loaded == null ||
      loaded.id != item.id ||
      loaded.serverId != item.serverId ||
      loaded.kind != item.kind ||
      loaded.backend != item.backend ||
      (loaded.libraryId != null && item.libraryId != null && loaded.libraryId != item.libraryId)) {
    throw StateError('Music metadata identity mismatch');
  }
  return loaded;
}
