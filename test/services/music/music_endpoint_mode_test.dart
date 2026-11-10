import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/music_endpoint_mode.dart';

void main() {
  tearDown(() => MusicEndpointMode.enabled = false);

  test('ordinary offline sessions never advertise a music host', () {
    MusicEndpointMode.enabled = false;
    expect(MusicEndpointMode.shouldStartHost(offline: true, enabledBySetting: true), isFalse);
    expect(MusicEndpointMode.shouldStartHost(offline: false, enabledBySetting: false), isFalse);
  });

  test('explicit endpoint launch allows the paired host without an online server', () {
    MusicEndpointMode.enabled = true;
    expect(MusicEndpointMode.shouldStartHost(offline: true, enabledBySetting: false), isTrue);
  });
}
