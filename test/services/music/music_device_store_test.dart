import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/companion_remote/lan_discovery_service.dart';
import 'package:plezy/services/music/music_device_store.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);
  DiscoveredHost host(int index) => DiscoveredHost(
    authContextId: 'account',
    clientId: 'device-$index',
    name: 'Player $index',
    platform: 'linux',
    ips: const ['192.0.2.1'],
    port: 48634,
  );

  test('concurrent remembered devices are retained and profile isolated', () async {
    await Future.wait([for (var i = 0; i < 20; i++) MusicDeviceStore.remember('one', host(i))]);
    expect(await MusicDeviceStore.read('one'), hasLength(20));
    expect(await MusicDeviceStore.read('two'), isEmpty);
    await Future.wait([MusicDeviceStore.forget('one', host(1)), MusicDeviceStore.remember('one', host(20))]);
    final devices = await MusicDeviceStore.read('one');
    expect(devices, hasLength(20));
    expect(devices.any((device) => device.clientId == 'device-1'), isFalse);
    expect(devices.any((device) => device.clientId == 'device-20'), isTrue);
  });

  test('remembered list has a bounded most-recent order', () async {
    for (var i = 0; i < 40; i++) {
      await MusicDeviceStore.remember('one', host(i));
    }
    final devices = await MusicDeviceStore.read('one');
    expect(devices, hasLength(32));
    expect(devices.first.clientId, 'device-39');
    expect(devices.last.clientId, 'device-8');
  });
}
