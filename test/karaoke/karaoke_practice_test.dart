import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/karaoke/karaoke_models.dart';
import 'package:plezy/karaoke/karaoke_session.dart';
import 'package:plezy/karaoke/karaoke_store.dart';
import 'package:plezy/services/music/music_playback_service.dart';

class _MemoryKaraokeStore extends KaraokeStore {
  _MemoryKaraokeStore() : super('practice-test');

  final documents = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> read(String name) async {
    final value = documents[name];
    return value == null ? null : Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  }

  @override
  Future<void> write(String name, Map<String, dynamic> value) async {
    documents[name] = Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  }
}

class _UnusedMusicService extends ChangeNotifier implements MusicPlaybackService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

KaraokeTrack _track(String id) => KaraokeTrack(id: id, songId: 'song-$id', title: id, durationMs: 60000);

KaraokeRequest _request(String trackId, {KaraokeRequestState state = KaraokeRequestState.ready}) =>
    KaraokeRequest(id: 'request-$trackId', trackId: trackId, singers: const [], createdMs: 1, state: state);

void main() {
  group('Karaoke practice markers', () {
    test('persists independent rendition loops through profile session recovery', () async {
      final store = _MemoryKaraokeStore();
      final first = KaraokeSession(music: _UnusedMusicService(), profileId: 'practice', store: store);
      await first.ready;
      first.catalog.addAll({'rendition-a': _track('rendition-a'), 'rendition-b': _track('rendition-b')});

      final requestA = _request('rendition-a');
      first.requests.add(requestA);
      first.current = requestA;
      await first.setLoop(1200, 3100);

      first.current = _request('rendition-b');
      await first.setLoop(8400, null);
      expect(first.practiceMarkersFor('rendition-a'), (startMs: 1200, endMs: 3100));
      expect(first.practiceMarkersFor('rendition-b'), (startMs: 8400, endMs: null));

      requestA.state = KaraokeRequestState.playing;
      first.current = requestA;
      await first.save();

      final restored = KaraokeSession(music: _UnusedMusicService(), profileId: 'practice', store: store);
      await restored.ready;
      expect(restored.current?.trackId, 'rendition-a');
      expect(restored.loopStartMs, 1200);
      expect(restored.loopEndMs, 3100);
      expect(restored.practiceMarkersFor('rendition-b'), (startMs: 8400, endMs: null));

      first.dispose();
      restored.dispose();
    });

    test('rejects invalid loop bounds and clear removes only the current rendition', () async {
      final store = _MemoryKaraokeStore();
      final session = KaraokeSession(music: _UnusedMusicService(), profileId: 'practice', store: store);
      await session.ready;
      session.catalog.addAll({'rendition-a': _track('rendition-a'), 'rendition-b': _track('rendition-b')});
      session.current = _request('rendition-a');

      await expectLater(session.setLoop(-1, null), throwsArgumentError);
      await expectLater(session.setLoop(1000, 1499), throwsArgumentError);
      await expectLater(session.setLoop(1000, 60001), throwsArgumentError);
      await session.setLoop(1000, null);
      await expectLater(session.setLoop(1000, 1499), throwsArgumentError);
      expect(session.practiceMarkersFor('rendition-a'), (startMs: 1000, endMs: null));

      session.current = _request('rendition-b');
      await session.setLoop(2000, 3000);
      session.current = null;
      await session.setLoop(null, null);
      expect(session.practiceMarkersFor('rendition-a'), (startMs: 1000, endMs: null));
      expect(session.practiceMarkersFor('rendition-b'), isNull);

      session.current = _request('rendition-a');
      await session.setLoop(null, null);
      expect(session.practiceMarkersFor('rendition-a'), isNull);
      session.dispose();
    });

    test('ignores malformed, out-of-range and unknown rendition markers on restore', () async {
      final store = _MemoryKaraokeStore();
      store.documents['session'] = {
        'schema': 1,
        'catalog': [_track('known').toJson()],
        'practiceMarkers': {
          'known': {'startMs': 1000, 'endMs': 2500},
          'too-late': {'startMs': 1000, 'endMs': 2000},
          'known-bad': {'startMs': -1, 'endMs': 2000},
          'known-too-long': {'startMs': 1000, 'endMs': 60001},
          'known-reversed': {'startMs': 2500, 'endMs': 2000},
          'known-malformed': {'startMs': 1000.5, 'endMs': 2500},
        },
        'practiceRenditionId': 'known',
      };
      final session = KaraokeSession(music: _UnusedMusicService(), profileId: 'practice', store: store);
      await session.ready;
      expect(session.error, isNull);
      expect(session.practiceMarkersFor('known'), (startMs: 1000, endMs: 2500));
      expect(session.loopStartMs, 1000);
      expect(session.loopEndMs, 2500);
      expect(session.practiceMarkersFor('too-late'), isNull);
      expect(session.practiceMarkersFor('known-bad'), isNull);
      expect(session.practiceMarkersFor('known-too-long'), isNull);
      expect(session.practiceMarkersFor('known-reversed'), isNull);
      expect(session.practiceMarkersFor('known-malformed'), isNull);
      session.dispose();
    });
  });
}
