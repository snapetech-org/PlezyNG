import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../base_shared_preferences_service.dart';
import '../../utils/serial_future_queue.dart';
import '../companion_remote/lan_discovery_service.dart';

/// Remembered network coordinates are profile-scoped metadata. Pairing
/// capabilities stay separately encrypted in RemotePairingStore.
abstract final class MusicDeviceStore {
  static final _writes = SerialFutureQueue();
  static String _key(String profile) => 'music_devices_${sha256.convert(utf8.encode(profile))}';

  static Future<List<DiscoveredHost>> read(String profile) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = readTolerantString(prefs, _key(profile));
    if (raw == null || raw.length > 64 * 1024) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.length > 32) return [];
      return [for (final entry in decoded) ?_parse(entry)];
    } on FormatException {
      return [];
    }
  }

  static DiscoveredHost? _parse(Object? value) {
    if (value is! Map) return null;
    final auth = value['auth'], id = value['id'], name = value['name'], platform = value['platform'];
    final ips = value['ips'], port = value['port'];
    if (auth is! String ||
        auth.isEmpty ||
        auth.length > 256 ||
        id is! String ||
        id.isEmpty ||
        id.length > 256 ||
        name is! String ||
        name.isEmpty ||
        name.length > 256 ||
        platform is! String ||
        platform.length > 40 ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        ips is! List ||
        ips.isEmpty ||
        ips.length > 8 ||
        ips.any((ip) => ip is! String || ip.isEmpty || ip.length > 255 || RegExp(r'[\s/?#@]').hasMatch(ip))) {
      return null;
    }
    return DiscoveredHost(
      authContextId: auth,
      clientId: id,
      name: name,
      platform: platform,
      port: port,
      ips: ips.cast<String>(),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static Future<void> remember(String profile, DiscoveredHost host) => _writes.run(() async {
    final devices = await read(profile);
    devices.removeWhere((entry) => entry.authContextId == host.authContextId && entry.clientId == host.clientId);
    devices.insert(0, host);
    await _write(profile, devices.take(32).toList());
  });

  static Future<void> forget(String profile, DiscoveredHost host) => _writes.run(() async {
    final devices = await read(profile);
    devices.removeWhere((entry) => entry.authContextId == host.authContextId && entry.clientId == host.clientId);
    await _write(profile, devices);
  });

  static Future<void> _write(String profile, List<DiscoveredHost> hosts) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(
      _key(profile),
      jsonEncode([
        for (final host in hosts)
          {
            'auth': host.authContextId,
            'id': host.clientId,
            'name': host.name,
            'platform': host.platform,
            'ips': host.ips,
            'port': host.port,
          },
      ]),
    );
  }
}
