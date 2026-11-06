import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/hdr_diagnostics.dart';

void main() {
  for (final platform in ['android', 'ios', 'tvos', 'macos', 'windows', 'linux', 'webos', 'tizen']) {
    test('$platform distinguishes the source and preference from observed output', () {
      final data = hdrConfigurationDiagnostic(
        platform: platform,
        backend: 'mpv',
        requested: false,
        sourceIsHdr: true,
        sourceTransfer: 'pq',
        linuxOutputOverride: 'hdr',
        toneMapping: 'player',
      );
      expect(data['source_hdr'], isTrue);
      expect(data['hdr_requested'], isFalse);
      expect(data.containsKey('hdr_active'), isFalse);
      expect(data.containsKey('output_override'), platform == 'linux');
      expect(data.containsKey('tone_mapping'), platform == 'linux');
    });
  }

  test('unknown source state remains unknown; invalid overrides are not logged verbatim', () {
    final data = hdrConfigurationDiagnostic(
      platform: 'linux',
      backend: 'mpv',
      requested: null,
      linuxOutputOverride: 'arbitrary environment value',
    );
    expect(data['source_hdr'], isNull);
    expect(data['hdr_requested'], isNull);
    expect(data['output_override'], 'invalid');
  });
}
