import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/music/music_metadata.dart';

import '../../test_helpers/music_experience_fakes.dart';

class _MetadataClient extends ExperienceClient {
  Future<MediaItem?> Function()? fetch;
  @override
  Future<MediaItem?> fetchItem(String id) => fetch!.call();
}

void main() {
  test('metadata rejects stale authentication and different recording identity', () async {
    final item = musicTrack('one');
    final client = _MetadataClient();
    final pending = Completer<MediaItem?>();
    client.fetch = () => pending.future;
    final loading = loadMusicMetadata(item: item, clientFor: () => client, isCurrent: () => true);
    final rejected = expectLater(loading, throwsStateError);
    client.authenticationSessionId = Object();
    pending.complete(item);
    await rejected;
    for (final replacement in [
      musicTrack('two'),
      musicTrack('one', server: 'other'),
      item.copyWith(libraryId: 'other'),
    ]) {
      client.fetch = () async => replacement;
      await expectLater(
        loadMusicMetadata(item: item, clientFor: () => client, isCurrent: () => true),
        throwsStateError,
      );
    }
    client.fetch = () async => MediaItem.fromJson({...item.toJson(), 'editionTitle': 'Deluxe'});
    expect(
      (await loadMusicMetadata(item: item, clientFor: () => client, isCurrent: () => true)).editionTitle,
      'Deluxe',
    );
    await expectLater(loadMusicMetadata(item: item, clientFor: () => client, isCurrent: () => false), throwsStateError);
  });
  test('credits preserve roles and deduplicate only identical attributions', () {
    final item = musicTrack('one').copyWith(
      writers: ['Writer', 'Writer'],
      producers: ['Writer'],
      raw: {
        'People': [
          {'Name': 'Composer', 'Type': 'Composer'},
          {'Name': 'Player', 'Type': 'Musician', 'Role': 'Violin'},
          {'Name': 'Player', 'Type': 'Musician', 'Role': 'Cello'},
          {'Name': null},
        ],
      },
    );
    final credits = musicCredits(item);
    expect(credits.where((credit) => credit.kind == MusicCreditKind.writer), hasLength(1));
    expect(credits.where((credit) => credit.kind == MusicCreditKind.producer), hasLength(1));
    expect(credits.where((credit) => credit.kind == MusicCreditKind.composer).single.name, 'Composer');
    expect(credits.where((credit) => credit.name == 'Player').map((credit) => credit.role), ['Violin', 'Cello']);
  });

  test('missing credits remain absent instead of inferring from a title', () {
    final item = MediaItem.fromJson({
      ...musicTrack('one').toJson(),
      'originalTitle': null,
      'grandparentTitle': null,
      'parentTitle': 'The album is not the performer',
    });
    expect(musicCredits(item), isEmpty);
  });

  test('the album parent is still a valid artist credit for an album', () {
    final album = musicTrack('one').copyWith(kind: MediaKind.album, parentTitle: 'Album artist');
    final credit = musicCredits(album).single;
    expect(credit.kind, MusicCreditKind.artist);
    expect(credit.name, 'Album artist');
  });
}
