// ignore_for_file: avoid_relative_lib_imports, avoid_print
// Standalone OS IPC probe; fake Steam observer in cloud_transport_probe.py only.
import '../../lib/games/steam_cloud_settings.dart';

Future<void> main(List<String> args) async {
  final mode = args.single;
  var current = true;
  final request = <String, dynamic>{'version': 1, 'op': 'read', 'steamId': '76561198000000001'};
  var expectedStatus = 'observed';
  var expectedValue = true;
  switch (mode) {
    case 'read':
      break;
    case 'set':
      request.addAll({'op': 'set', 'expected': true, 'enabled': false});
      expectedValue = false;
    case 'stale':
      request.addAll({'op': 'set', 'expected': false, 'enabled': true});
      expectedStatus = 'stale';
    case 'wrong_account':
      request['steamId'] = '76561198000000002';
      expectedStatus = 'unknown';
    case 'malformed':
      request['script'] = 'must never execute';
      expectedStatus = 'unknown';
    case 'disabled':
      expectedStatus = 'unknown';
    case 'cancel':
      Future<void>.delayed(const Duration(milliseconds: 150), () => current = false);
      expectedStatus = 'unavailable';
    default:
      throw ArgumentError('Unknown probe mode');
  }
  final result = await localSteamCloudSetting(request, () => current);
  if (mode == 'cancel') {
    if (result.status == 'observed') throw StateError('Cancelled request reported success');
  } else if (result.status != expectedStatus || (expectedStatus == 'observed' && result.enabled != expectedValue)) {
    throw StateError('$mode: expected $expectedStatus, got ${result.status}');
  }
  print('PASS $mode');
}
