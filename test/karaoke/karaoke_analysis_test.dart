import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/karaoke/karaoke_analysis.dart';
import 'package:plezy/karaoke/karaoke_session.dart';
import 'package:plezy/karaoke/karaoke_store.dart';
import 'package:plezy/services/music/music_playback_service.dart';

class _MemoryKaraokeStore extends KaraokeStore {
  _MemoryKaraokeStore() : super('analysis-test');

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

void main() {
  group('KaraokeAnalysis', () {
    test('normalizes estimates and keeps only bounded display fields', () {
      expect(
        KaraokeAnalysis.normalize({
          'key': '  F# minor ',
          'bpm': 123.5,
          'confidence': .84,
          'chords': [
            {'startMs': 0, 'chord': ' Am7 '},
            {'startMs': 3000, 'chord': ' G', 'confidence': .7},
          ],
          'unrelated': {'large': 'provider metadata is not displayed'},
        }),
        {
          'key': 'F# minor',
          'bpm': 123.5,
          'confidence': .84,
          'chords': [
            {'startMs': 0, 'chord': 'Am7'},
            {'startMs': 3000, 'chord': 'G', 'confidence': .7},
          ],
        },
      );
    });

    test('rejects non-finite or out-of-range estimates', () {
      for (final value in [
        {'bpm': 0},
        {'bpm': 401},
        {'bpm': double.nan},
        {'confidence': -0.1},
        {'confidence': 1.1},
        {'key': 'C\nmajor'},
      ]) {
        expect(() => KaraokeAnalysis.normalize(value), throwsFormatException);
      }
    });

    test('rejects malformed, unsorted, fractional and oversized chord data', () {
      for (final chords in [
        ['C'],
        [
          {'startMs': 1200, 'chord': 'C'},
          {'startMs': 1000, 'chord': 'F'},
        ],
        [
          {'startMs': 12.5, 'chord': 'C'},
        ],
        [
          {'startMs': 0, 'chord': ''},
        ],
        List.filled(KaraokeAnalysis.maxChordCount + 1, {'startMs': 0, 'chord': 'C'}),
      ]) {
        expect(() => KaraokeAnalysis.normalize({'chords': chords}), throwsFormatException);
      }
    });

    test('parses manual corrections and overlays them without mutating estimates', () {
      final estimates = KaraokeAnalysis.normalize({
        'key': 'C major',
        'bpm': 120,
        'chords': [
          {'startMs': 0, 'chord': 'C'},
        ],
      });
      final corrections = KaraokeAnalysis.correctionsFromFields(key: 'D minor', bpm: '92.5', chords: '0 Dm\n1500 G7');

      expect(KaraokeAnalysis.withCorrections(estimates, corrections), {
        'key': 'D minor',
        'bpm': 92.5,
        'chords': [
          {'startMs': 0, 'chord': 'Dm'},
          {'startMs': 1500, 'chord': 'G7'},
        ],
      });
      expect(estimates['key'], 'C major');
      expect(estimates['bpm'], 120.0);
    });

    test('rejects invalid manual tempo and chord lines', () {
      expect(() => KaraokeAnalysis.correctionsFromFields(key: '', bpm: '401', chords: ''), throwsFormatException);
      expect(() => KaraokeAnalysis.correctionsFromFields(key: '', bpm: '', chords: 'C 1000'), throwsFormatException);
      expect(
        () => KaraokeAnalysis.correctionsFromFields(key: '', bpm: '', chords: '1500 G\n1200 C'),
        throwsFormatException,
      );
    });

    test('an empty corrected chord list hides estimated chord cues', () {
      expect(KaraokeAnalysis.correctionsFromFields(key: '', bpm: '', chords: ''), {'chords': []});
    });

    test('corrections survive estimate refresh and profile session restart', () async {
      final store = _MemoryKaraokeStore();
      final first = KaraokeSession(music: _UnusedMusicService(), profileId: 'first', store: store);
      await first.ready;
      await first.saveAnalysis('song', {
        'key': 'C major',
        'bpm': 120,
        'chords': [
          {'startMs': 0, 'chord': 'C'},
        ],
      });
      await first.saveAnalysisCorrections('song', {
        'key': 'D minor',
        'bpm': 92,
        'chords': [
          {'startMs': 0, 'chord': 'Dm'},
        ],
      });
      await first.saveAnalysis('song', {'key': 'F major', 'bpm': 184});
      expect(first.analysis['song'], {
        'key': 'D minor',
        'bpm': 92.0,
        'chords': [
          {'startMs': 0, 'chord': 'Dm'},
        ],
      });

      final restored = KaraokeSession(music: _UnusedMusicService(), profileId: 'first', store: store);
      await restored.ready;
      await restored.loadAnalysis('song');
      expect(restored.analysis['song'], first.analysis['song']);
      expect(store.documents['analysis-${sha256.convert(utf8.encode('song'))}']?['schema'], 2);
      restored.dispose();
      first.dispose();
    });

    test('legacy estimate documents load and migrate on correction', () async {
      final store = _MemoryKaraokeStore();
      final key = 'analysis-${sha256.convert(utf8.encode('legacy-song'))}';
      store.documents[key] = {
        'schema': 1,
        'renditionId': 'legacy-song',
        'analysis': {'key': 'A minor', 'bpm': 100},
      };
      final session = KaraokeSession(music: _UnusedMusicService(), profileId: 'legacy', store: store);
      await session.ready;
      await session.loadAnalysis('legacy-song');
      expect(session.analysis['legacy-song'], {'key': 'A minor', 'bpm': 100.0});
      await session.saveAnalysisCorrections('legacy-song', {'key': 'B minor'});
      expect(store.documents[key]?['schema'], 2);
      expect(session.analysis['legacy-song'], {'key': 'B minor', 'bpm': 100.0});
      session.dispose();
    });
  });
}
