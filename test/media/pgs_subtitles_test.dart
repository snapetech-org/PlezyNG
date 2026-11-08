import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/pgs_subtitles.dart';

void main() {
  test('renders palette alpha, literal pixels and colored runs at authored coordinates', () {
    final subtitles = PgsSubtitles.parse(_sample());
    final cue = subtitles.at(const Duration(milliseconds: 1500))!;
    final image = cue.rasterize().single;
    expect((cue.width, cue.height), (1920, 1080));
    expect((image.x, image.y, image.width, image.height), (3, 4, 2, 2));
    expect(image.forced, isTrue);
    expect(image.rgba, [255, 255, 255, 128, 255, 255, 255, 128, 0, 0, 0, 255, 0, 0, 0, 255]);
  });

  test('seeking backwards, delayed subtitles and clear compositions follow media time', () {
    final subtitles = PgsSubtitles.parse(_sample());
    expect(subtitles.at(const Duration(milliseconds: 999)), isNull);
    expect(subtitles.at(const Duration(seconds: 1)), isNotNull);
    expect(subtitles.at(const Duration(seconds: 2)), isNull);
    expect(subtitles.at(const Duration(hours: 2)), isNull);
    expect(subtitles.at(const Duration(seconds: 1)), isNotNull);
    expect(subtitles.at(const Duration(seconds: -1)), isNull);
  });

  test('premultiplies translucent palette entries for the Flutter image buffer', () {
    final cue = PgsSubtitles.parse(_sample()).cues.first;
    expect(cue.rasterize(premultiplied: true).single.rgba.sublist(0, 4), [128, 128, 128, 128]);
    expect(cue.rasterize().single.rgba.sublist(0, 4), [255, 255, 255, 128]);
  });

  test('reassembles split object segments before rendering', () {
    final subtitles = PgsSubtitles.parse(_sample(fragmented: true));
    expect(
      subtitles.at(const Duration(seconds: 1))!.rasterize().single.rgba,
      PgsSubtitles.parse(_sample()).cues.first.rasterize().single.rgba,
    );
  });

  test('retains prior object data across palette updates without mutating older cues', () {
    final bytes = BytesBuilder();
    bytes.add(_sample(clear: false));
    bytes.add(_segment(0x16, _composition(state: 0), pts: 135000));
    bytes.add(_segment(0x14, [0, 1, 1, 235, 128, 128, 255], pts: 135000));
    bytes.add(_segment(0x80, [], pts: 135000));
    final subtitles = PgsSubtitles.parse(bytes.takeBytes());
    expect(subtitles.at(const Duration(seconds: 1))!.rasterize().single.rgba[3], 128);
    expect(subtitles.at(const Duration(milliseconds: 1500))!.rasterize().single.rgba[3], 255);
  });

  test('crops source objects and clips to the declared window', () {
    final subtitles = PgsSubtitles.parse(_sample(crop: [1, 0, 1, 2], window: [3, 5, 1, 1]));
    final image = subtitles.cues.first.rasterize().single;
    expect((image.x, image.y, image.width, image.height), (3, 5, 1, 1));
    expect(image.rgba, [0, 0, 0, 255]);
  });

  test('forced-only filtering preserves authored forced flags', () {
    final subtitles = PgsSubtitles.parse(_sample(forced: false));
    expect(subtitles.cues.first.rasterize(forcedOnly: true), isEmpty);
    expect(subtitles.cues.first.rasterize(), hasLength(1));
  });

  test('extended transparent and colored runs preserve full row boundaries', () {
    final data = BytesBuilder();
    data.add(_segment(0x16, _composition(width: 300, height: 2, x: 0, y: 0)));
    data.add(_segment(0x14, [0, 0, 1, 235, 128, 128, 255]));
    final rle = [0, 0x41, 44, 0, 0, 0, 0xc1, 44, 1, 0, 0];
    data.add(_segment(0x15, [0, 1, 0, 0xc0, ..._u24(rle.length + 4), ..._u16(300), 0, 2, ...rle]));
    data.add(_segment(0x80, []));
    final image = PgsSubtitles.parse(data.takeBytes()).cues.first.rasterize().single;
    expect(image.rgba.sublist(0, 300 * 4), everyElement(0));
    expect(image.rgba.sublist(300 * 4), everyElement(255));
  });

  test('rejects truncated segments without indexing outside the input', () {
    final bytes = _sample();
    for (final cut in [0, 1, 2, 8, 12, 14, bytes.length - 1]) {
      expect(() => PgsSubtitles.parse(Uint8List.sublistView(bytes, 0, cut)), throwsFormatException, reason: 'cut=$cut');
    }
  });

  test('refuses missing object data and incomplete fragments', () {
    expect(
      () => PgsSubtitles.parse(Uint8List.fromList([..._segment(0x16, _composition()), ..._segment(0x80, [])])),
      throwsFormatException,
    );
    final bytes = BytesBuilder();
    bytes.add(_segment(0x16, _composition()));
    bytes.add(_segment(0x15, [0, 1, 0, 0x80, 0, 0, 6, 0, 2, 0, 2, 1]));
    bytes.add(_segment(0x80, []));
    expect(() => PgsSubtitles.parse(bytes.takeBytes()), throwsFormatException);
  });

  test('refuses an excessive canvas before bitmap allocation', () {
    expect(() => PgsSubtitles.parse(_segment(0x16, _composition(width: 4097))), throwsFormatException);
  });

  test('refuses malformed RLE rather than drawing an overrun or partial image', () {
    for (final rle in [
      <int>[0],
      [0, 0x83, 1],
      [1, 0, 0],
      [0, 0xc0],
    ]) {
      final bytes = BytesBuilder();
      bytes.add(_segment(0x16, _composition()));
      bytes.add(_segment(0x14, [0, 0, 1, 235, 128, 128, 255]));
      bytes.add(_segment(0x15, [0, 1, 0, 0xc0, ..._u24(rle.length + 4), 0, 2, 0, 2, ...rle]));
      bytes.add(_segment(0x80, []));
      final malformed = bytes.takeBytes();
      expect(() => PgsSubtitles.parse(malformed), throwsFormatException);
    }
  });
}

Uint8List _sample({
  bool fragmented = false,
  bool clear = true,
  bool forced = true,
  List<int>? crop,
  List<int>? window,
}) {
  final data = BytesBuilder();
  data.add(_segment(0x16, _composition(crop: crop, forced: forced)));
  if (window != null) data.add(_segment(0x17, [1, 0, ...window.expand(_u16)]));
  data.add(_segment(0x14, [0, 0, 1, 235, 128, 128, 128, 2, 16, 128, 128, 255]));
  final rle = [1, 1, 0, 0, 0, 0x82, 2, 0, 0];
  data.add(
    _segment(0x15, [
      0,
      1,
      0,
      fragmented ? 0x80 : 0xc0,
      ..._u24(rle.length + 4),
      0,
      2,
      0,
      2,
      ...rle.take(fragmented ? 4 : rle.length),
    ]),
  );
  if (fragmented) data.add(_segment(0x15, [0, 1, 0, 0x40, ...rle.skip(4)]));
  data.add(_segment(0x80, []));
  if (clear) {
    data.add(_segment(0x16, _composition(count: 0, state: 0), pts: 180000));
    data.add(_segment(0x80, [], pts: 180000));
  }
  return data.takeBytes();
}

List<int> _composition({
  int width = 1920,
  int height = 1080,
  int state = 0x80,
  int count = 1,
  int x = 3,
  int y = 4,
  bool forced = true,
  List<int>? crop,
}) => [
  ..._u16(width),
  ..._u16(height),
  0x10,
  0,
  0,
  state,
  0,
  0,
  count,
  if (count != 0) ...[
    0,
    1,
    0,
    (forced ? 0x40 : 0) | (crop == null ? 0 : 0x80),
    ..._u16(x),
    ..._u16(y),
    if (crop != null) ...crop.expand(_u16),
  ],
];

Uint8List _segment(int type, List<int> payload, {int pts = 90000}) => Uint8List.fromList([
  0x50,
  0x47,
  (pts >> 24) & 255,
  (pts >> 16) & 255,
  (pts >> 8) & 255,
  pts & 255,
  0,
  0,
  0,
  0,
  type,
  ..._u16(payload.length),
  ...payload,
]);
List<int> _u16(int value) => [(value >> 8) & 255, value & 255];
List<int> _u24(int value) => [(value >> 16) & 255, (value >> 8) & 255, value & 255];
