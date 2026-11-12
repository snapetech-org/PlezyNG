import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/karaoke/karaoke_models.dart';
import 'package:plezy/karaoke/karaoke_takes.dart';

KaraokeAsset _asset(String path, KaraokeAssetKind kind, {String? part, String? clockId}) =>
    KaraokeAsset(path: path, sha256: List.filled(64, 'a').join(), bytes: 1, kind: kind, part: part, clockId: clockId);

void main() {
  group('Karaoke guide selection', () {
    test('prefers the matching aligned vocal part', () {
      final track = KaraokeTrack(
        id: 'rendition',
        songId: 'song',
        title: 'Song',
        assets: [
          _asset('other-part.wav', KaraokeAssetKind.duetVocal, part: '2', clockId: 'rendition'),
          _asset('unaligned.wav', KaraokeAssetKind.leadVocal),
          _asset('lead.wav', KaraokeAssetKind.leadVocal, clockId: 'rendition'),
          _asset('part-1.wav', KaraokeAssetKind.duetVocal, part: '1', clockId: 'rendition'),
        ],
      );

      expect(karaokeGuideAssetFor(track, part: '1')?.path, 'part-1.wav');
    });

    test('falls back to rendition audio when no aligned vocal stem matches', () {
      final track = KaraokeTrack(
        id: 'rendition',
        songId: 'song',
        title: 'Song',
        assets: [
          _asset('instrumental.wav', KaraokeAssetKind.instrumental, clockId: 'rendition'),
          _asset('wrong-clock.wav', KaraokeAssetKind.leadVocal, clockId: 'another-rendition'),
          _asset('original.wav', KaraokeAssetKind.audio),
        ],
      );

      expect(karaokeGuideAssetFor(track)?.path, 'original.wav');
    });

    test('does not present an instrumental backing as a singer guide', () {
      final track = KaraokeTrack(
        id: 'rendition',
        songId: 'song',
        title: 'Song',
        assets: [_asset('instrumental.wav', KaraokeAssetKind.instrumental, clockId: 'rendition')],
      );

      expect(karaokeGuideAssetFor(track), isNull);
    });
  });
}
