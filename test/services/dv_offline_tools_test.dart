import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/dv_offline_tools.dart';

void main() {
  test('frame rates reject invalid and unbounded inputs', () {
    for (final value in ['24', '23.976', '24000/1001', '120']) {
      expect(DvOfflineTools.validFrameRate(value), isTrue, reason: value);
    }
    for (final value in ['0', '121', '24/0', '-24', 'NaN', 'Infinity', '24;echo x', '1/1001']) {
      expect(DvOfflineTools.validFrameRate(value), isFalse, reason: value);
    }
  });

  test('export paths remain literal arguments and invalid requests fail', () {
    final arguments = DvOfflineTools.arguments(
      base: '/media/a \$(id).hevc',
      enhancement: '/media/b.hevc',
      fps: '24000/1001',
      target: 'hdr10',
      output: '/media/out.mkv',
    );
    expect(arguments[1], '/media/a \$(id).hevc');
    expect(arguments.last, '--execute');
    expect(
      () => DvOfflineTools.arguments(base: '/a', enhancement: '/a', fps: '24', target: 'sdr', output: '/out.mkv'),
      throwsArgumentError,
    );
  });
}
