import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/visualization/visualizer_preset_text.dart';
import 'package:plezy/services/visualization/visualizer_content_limits.dart';

void main() {
  test('legacy names and UTF-16 survive byte decoding', () {
    expect(VisualizerPresetText.decode([65, 0xe9, 0x96]), 'Aé–');
    expect(VisualizerPresetText.decode([0xff, 0xfe, 65, 0, 0x3c, 0xd8, 0x0c, 0xdf]), 'A🌌');
    expect(VisualizerPresetText.decode([0xfe, 0xff, 0, 65]), 'A');
    expect(VisualizerPresetText.decode([0xef, 0xbb, 0xbf, 65]), 'A');
  });
  test('malformed Unicode, binary and undefined code page bytes fail', () {
    for (final bytes in [[0x81], [65, 0, 66], [0xff, 0xfe, 0, 0xd8], [0xff, 0xfe, 65]]) {
      expect(() => VisualizerPresetText.decode(bytes), throwsFormatException);
    }
  });
  test('UTF-16 cannot hide a shader include from import validation', () {
    final bytes = [0xff, 0xfe, for (final unit in '#include "outside.fx"'.codeUnits) ...[unit & 255, unit >> 8]];
    expect(() => VisualizerContentLimits.checkPreset(bytes), throwsFormatException);
  });
}
