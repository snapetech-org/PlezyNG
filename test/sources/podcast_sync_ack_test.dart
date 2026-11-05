import 'package:drift/native.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/sources/source_database.dart';
import 'package:plezy/sources/source_models.dart';
import 'package:plezy/sources/podcast_sync.dart';

void main() {
  test('version 11 migration preserves progress and tolerates damaged optional cache rows', () async {
    final directory = await Directory.systemTemp.createTemp('podcast-migration-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/publications.sqlite');
    final before = SourceDatabase(NativeDatabase(file));
    final repository = SourceRepository(before);
    final saved = await repository.saveProgress(
      'profile',
      const PublicationProgress(
        entryKey: 'entry',
        edition: 'edition',
        mode: PublicationMode.listening,
        session: 'session',
        positionMs: 12345,
      ),
    );
    await before.customStatement('DROP TABLE podcast_sync_ack');
    await before.customStatement('DROP INDEX entries_podcast_sync_identity');
    await before.customStatement('INSERT INTO entries(profile,source,id,payload) VALUES (?,?,?,?)', [
      'profile',
      'bad',
      'bad',
      'damaged',
    ]);
    await before.customStatement('PRAGMA user_version=11');
    await before.close();
    final after = SourceDatabase(NativeDatabase(file));
    addTearDown(after.close);
    final migrated = SourceRepository(after);
    expect((await migrated.progress('profile', saved.key))!.positionMs, 12345);
    expect(await migrated.podcastEntryBySyncIdentity('profile', 'missing'), isNull);
    expect(await migrated.podcastSyncAck('profile', 'account', saved.key), isNull);
  });
  test('podcast acknowledgments are independent of publication pending flags and exact revisions', () async {
    final database = SourceDatabase(NativeDatabase.memory());
    final repository = SourceRepository(database);
    addTearDown(database.close);
    const entry = SourceEntry(
      sourceId: 'feed',
      id: 'episode',
      title: 'Episode',
      kind: SourceItemKind.music,
      identifiers: {'podcast': 'episode', 'podcastSyncIdentity': 'identity'},
      files: [PublicationFile(id: 'audio', name: 'audio.mp3', mimeType: 'audio/mpeg', durationMs: 60000)],
    );
    await repository.cacheEntries('profile', [entry]);
    final first = await repository.saveProgress(
      'profile',
      PublicationProgress(
        entryKey: entry.key,
        edition: 'edition',
        mode: PublicationMode.listening,
        session: 'session',
        positionMs: 1000,
      ),
    );
    await repository.acknowledge('profile', first.key, first.revision);
    expect(await repository.podcastSyncChanges('profile', 'account'), hasLength(1));
    await repository.acknowledgePodcastSync('profile', 'account', first, PodcastSync.progressHash(first));
    expect(await repository.podcastSyncChanges('profile', 'account'), isEmpty);
    final second = await repository.saveProgress('profile', first.copyWith(positionMs: 2000));
    // A delayed upload response for the prior snapshot cannot acknowledge it.
    await repository.acknowledgePodcastSync('profile', 'account', first, PodcastSync.progressHash(first));
    expect((await repository.podcastSyncChanges('profile', 'account')).single.progress.revision, second.revision);
    expect((await repository.podcastEntryBySyncIdentity('profile', 'identity'))!.key, entry.key);
    expect(await repository.podcastSyncChanges('other-profile', 'account'), isEmpty);
  });
}
