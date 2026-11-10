import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/lyrics.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/services/music/music_library_store.dart';
import 'package:plezy/services/music/music_offline_bundle.dart';

import '../../test_helpers/music_experience_fakes.dart';

class LyricsClient extends ExperienceClient {
  Future<Lyrics?> Function()? response;
  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) async => response == null ? null : await response!();
}

class AnalysisClient extends LyricsClient implements PlexLoudnessProfileClient {
  AudioLoudnessProfile? analysis = AudioLoudnessProfile(levelsDb: List.filled(1024, -12), totalSamples: 20000);
  Future<AudioLoudnessProfile?> Function()? analysisResponse;
  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(
    String itemId, {
    int mediaIndex = 0,
    String? mediaSourceId,
    String? preferredVersionSignature,
    String? preferredVersionName,
  }) async => MediaSourceInfo(
    videoUrl: 'not-persisted',
    audioTracks: [MediaAudioTrack(id: 12, selected: true)],
    subtitleTracks: [],
    chapters: [],
  );
  @override
  Future<AudioLoudnessProfile?> fetchAudioLoudnessProfile(int streamId) async =>
      analysisResponse == null ? analysis : await analysisResponse!();
}

void main() {
  late AppDatabase database;
  late MusicLibraryStore store;
  late LyricsClient client;
  const lyrics = Lyrics(synced: true, lines: [LyricLine(text: 'fixture', startMs: 1000)]);
  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = MusicLibraryStore(database, 'profile');
    client = LyricsClient()..response = () async => lyrics;
  });
  tearDown(() => database.close());
  test('stored analysis rejects malformed, oversized, and mismatched revisions', () {
    final track = musicTrack('a').copyWith(updatedAt: 123);
    final document = {
      'version': 1,
      'updatedAt': 123,
      'levels': [-24, -18],
      'samples': 2000,
    };
    expect(musicAnalysisProfile(track, document)?.levelsDb, [-24, -18]);
    for (final invalid in [
      {...document, 'version': 2},
      {...document, 'updatedAt': null},
      {...document, 'samples': 0},
      {...document, 'levels': <double>[]},
      {
        ...document,
        'levels': [double.nan],
      },
      {...document, 'levels': List.filled(513, -24)},
    ]) {
      expect(musicAnalysisProfile(track, invalid), isNull);
    }
  });
  test('explicit downloads retain timed server lyrics in their owning profile', () async {
    await MusicOfflineBundle(store).prepare(musicTrack('a'), client, current: () => true);
    final saved = await store.document('lyrics', 's:a');
    expect(Lyrics.fromJson(saved!['lyrics']).lines.single.startMs, 1000);
    expect(await MusicLibraryStore(database, 'other').document('lyrics', 's:a'), isNull);
  });
  test('revocation, account replacement and permanent teardown discard late enrichment', () async {
    for (final change in [0, 1, 2]) {
      store = MusicLibraryStore(database, 'profile');
      final pending = Completer<Lyrics?>();
      var current = true;
      client.response = () => pending.future;
      final work = MusicOfflineBundle(store).prepare(musicTrack('a'), client, current: () => current);
      if (change == 0) current = false;
      if (change == 1) client.authenticationSessionId = Object();
      if (change == 2) await database.deleteMusicRecipesForProfile('profile');
      pending.complete(lyrics);
      await work;
      expect(await MusicLibraryStore(database, 'profile').document('lyrics', 's:a'), isNull);
    }
  });
  test('unavailable optional lyrics do not fail a download, explicit absence clears stale data', () async {
    final bundle = MusicOfflineBundle(store);
    await bundle.prepare(musicTrack('a'), client, current: () => true);
    client.response = () => Future.error(StateError('offline'));
    await bundle.prepare(musicTrack('a'), client, current: () => true);
    expect(await store.document('lyrics', 's:a'), isNotNull);
    client.response = () async => null;
    await bundle.prepare(musicTrack('a'), client, current: () => true);
    expect(await store.document('lyrics', 's:a'), isNull);
  });
  test('download analysis is bounded and profile scoped without retaining a stream URL', () async {
    await MusicOfflineBundle(store).prepare(musicTrack('a'), AnalysisClient(), current: () => true);
    final document = await store.document('analysis', 's:a');
    expect(document!['levels'], hasLength(512));
    expect(document['samples'], 20000);
    expect(document.toString(), isNot(contains('not-persisted')));
    expect(await MusicLibraryStore(database, 'other').document('analysis', 's:a'), isNull);
  });
  test('late analysis is discarded after account replacement', () async {
    final analyzed = AnalysisClient();
    final pending = Completer<AudioLoudnessProfile?>();
    final requested = Completer<void>();
    analyzed.analysisResponse = () {
      requested.complete();
      return pending.future;
    };
    final work = MusicOfflineBundle(store).prepare(musicTrack('a'), analyzed, current: () => true);
    await requested.future;
    analyzed.authenticationSessionId = Object();
    pending.complete(analyzed.analysis);
    await work;
    expect(await store.document('analysis', 's:a'), isNull);
  });
  test('offline snapshots use only currently owned downloads, preserving occurrence order', () {
    final snapshot = {
      'version': 1,
      'tracks': [
        musicTrack('b').toJson(),
        musicTrack('a').toJson(),
        musicTrack('a', server: 'other').toJson(),
        musicTrack('b').toJson(),
        {'id': 'broken'},
      ],
    };
    final result = musicSnapshotTracks(snapshot, [musicTrack('a'), musicTrack('b')]);
    expect(result.map((item) => item.id), ['b', 'a', 'b']);
    expect(musicSnapshotTracks(snapshot, []), isEmpty);
    expect(musicSnapshotTracks({'version': 2, 'tracks': []}, [musicTrack('a')]), isEmpty);
    expect(musicSnapshotTracks(snapshot, [musicTrack('a')], accountScope: 's/other-user'), isEmpty);
    expect(
      musicSnapshotTracks({...snapshot, 'accountScope': 's/user'}, [musicTrack('a')], accountScope: 's/user'),
      hasLength(1),
    );
  });
  test('invalid analysis never enters persistent offline data', () {
    expect(
      musicAnalysisDocument(musicTrack('a'), AudioLoudnessProfile(levelsDb: [double.nan], totalSamples: 1)),
      isNull,
    );
    expect(musicAnalysisDocument(musicTrack('a'), AudioLoudnessProfile(levelsDb: [-1], totalSamples: 0)), isNull);
  });
}
