import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/karaoke/cdg_decoder.dart';
import 'package:plezy/karaoke/karaoke_formats.dart';
import 'package:plezy/karaoke/karaoke_midi.dart';
import 'package:plezy/karaoke/karaoke_models.dart';

void main() {
  test('WebVTT preserves singer and source word timings', () {
    final track = KaraokeFormats.parse(
      'WEBVTT\n\n00:01.000 --> 00:03.000\n<v Alice>Hello <00:02.000>world &amp; you</v>\n',
      '.vtt',
    );
    final line = track.lyrics.lines.single;
    expect(line.part, 'Alice');
    expect(line.text, 'Hello world & you');
    expect(line.spans.map((s) => s.startMs), [1000, 2000]);
    expect(line.spans.map((s) => s.endMs), [2000, 3000]);
    expect(
      () => KaraokeFormats.parse('WEBVTT\n\n00:01.000 --> 00:02.000\n<00:03.000>late\n', '.vtt'),
      throwsFormatException,
    );
  });

  test('portable assets reject path traversal and arbitrary identities', () {
    Map<String, dynamic> asset(String path) => {
      'path': path,
      'sha256': List.filled(64, 'a').join(),
      'bytes': 12,
      'kind': KaraokeAssetKind.audio.name,
    };
    for (final path in ['../secret', '/secret', 'a/../../secret', r'a\secret', 'C:/secret']) {
      expect(() => KaraokeAsset.fromJson(asset(path)), throwsFormatException);
    }
    expect(KaraokeAsset.fromJson(asset('audio/backing.wav')).path, 'audio/backing.wav');
    expect(() => KaraokeAsset.fromJson(asset('backing.wav')..['sha256'] = 'bad'), throwsFormatException);
  });

  test('CD+G backwards seek reconstructs palette and pixels', () {
    List<int> packet(int instruction, List<int> payload) => [
      9,
      instruction,
      0,
      0,
      ...payload,
      ...List.filled(16 - payload.length, 0),
      0,
      0,
      0,
      0,
    ];
    final decoder = CdgDecoder(
      Uint8List.fromList([
        ...packet(1, [3, 0]),
        ...packet(1, [7, 0]),
      ]),
    );
    decoder.seek(4);
    expect(decoder.frame.pixels.first, 3);
    decoder.seek(7);
    expect(decoder.frame.pixels.first, 7);
    decoder.seek(4);
    expect(decoder.frame.pixels.first, 3);
    decoder.seek(0);
    expect(decoder.frame.pixels.first, 0);
  });

  test('KAR tempo map keeps source note duration and lyric events', () {
    final midi = Uint8List.fromList([
      ...'MThd'.codeUnits,
      0,
      0,
      0,
      6,
      0,
      0,
      0,
      1,
      0,
      96,
      ...'MTrk'.codeUnits,
      0,
      0,
      0,
      22,
      0,
      0xff,
      0x51,
      3,
      7,
      0xa1,
      0x20,
      0,
      0xff,
      5,
      2,
      72,
      105,
      0,
      0x90,
      60,
      100,
      96,
      0x80,
      60,
      0,
      0,
      0xff,
      0x2f,
      0,
    ]);
    // The track contains 25 bytes, including its end marker.
    midi[21] = midi.length - 22;
    final track = parseKaraokeMidi(midi);
    expect(track.notes.single.startMs, 0);
    expect(track.notes.single.endMs, 500);
    expect(track.lyrics.lines.single.text, 'Hi');
    expect(() => parseKaraokeMidi(Uint8List.fromList(midi.sublist(0, midi.length - 1))), throwsFormatException);
  });
}
