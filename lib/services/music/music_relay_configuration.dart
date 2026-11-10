import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../utils/serial_future_queue.dart';
import '../base_shared_preferences_service.dart';
import '../credential_vault.dart';
import '../plezy_server.dart';

bool isMusicRelayCapability(Object? value) => value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Uri musicRelayUri(String value) {
  final base = Uri.parse(requirePleazyngServiceUrl(value, service: 'Music relay'));
  final path = base.path.endsWith('/music/connect/relay') ? base.path : '${base.path}/music/connect/relay';
  return base.replace(scheme: 'wss', path: path);
}

/// This invitation is delivered only inside the existing paired channel.
/// The relay sees a room capability. Music commands require separate E2E proof.
class MusicRelayTarget {
  const MusicRelayTarget({required this.uri, required this.room, required this.control});
  final Uri uri;
  final String room;
  final String control;

  Map<String, dynamic> toJson() => {'url': uri.replace(scheme: 'https').toString(), 'room': room, 'control': control};

  static MusicRelayTarget? read(Object? value) {
    if (value is! Map || value.length != 3) return null;
    final url = value['url'], room = value['room'], control = value['control'];
    if (url is! String || url.length > 2048 || !isMusicRelayCapability(room) || !isMusicRelayCapability(control)) {
      return null;
    }
    try {
      final uri = musicRelayUri(url);
      if (!Uri.parse(url).path.endsWith('/music/connect/relay')) return null;
      return MusicRelayTarget(uri: uri, room: room as String, control: control as String);
    } catch (_) {
      return null;
    }
  }
}

class MusicRelayHostCredentials {
  const MusicRelayHostCredentials(this.secret, this.control);
  final String secret;
  final String control;
  String get room => sha256.convert(utf8.encode(secret)).toString();
}

abstract final class MusicRelayStore {
  static final _writes = SerialFutureQueue();
  static String prefix(String profile) => 'music_pairing_relay_${sha256.convert(utf8.encode(profile))}_';

  static Future<({String url, bool enabled})> configuration(String profile) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final key = prefix(profile);
    return (
      url: readTolerantString(prefs, '${key}url') ?? pleazyngRelayBaseUrl,
      enabled: readPreferenceTolerantly(prefs, '${key}enabled', () => prefs.getBool('${key}enabled')) ?? false,
    );
  }

  static Future<void> configure(String profile, String url, bool enabled) => _writes.run(() async {
    if (url.trim().isNotEmpty) musicRelayUri(url);
    if (enabled && url.trim().isEmpty) throw const FormatException('Music relay URL required');
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString('${prefix(profile)}url', url.trim());
    await prefs.setBool('${prefix(profile)}enabled', enabled);
  });

  static Future<MusicRelayHostCredentials> host(String profile, String pairingCode) => _writes.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final key = '${prefix(profile)}root';
    final stored = readTolerantString(prefs, key);
    String? root = stored == null ? null : await CredentialVault.reveal(stored);
    if (!isMusicRelayCapability(root)) {
      final random = Random.secure();
      root = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString(key, await CredentialVault.protect(root));
    }
    String derive(String role) =>
        Hmac(sha256, utf8.encode(root!)).convert(utf8.encode('pleazyng-music-relay-v1|$role|$pairingCode')).toString();
    return MusicRelayHostCredentials(derive('host'), derive('controller'));
  });

  static String _targetKey(String profile, String peer) =>
      '${prefix(profile)}peer_${sha256.convert(utf8.encode(peer))}';

  static Future<MusicRelayTarget?> target(String profile, String peer) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final value = readTolerantString(prefs, _targetKey(profile, peer));
    if (value == null || value.length > 16384) return null;
    try {
      final clear = await CredentialVault.reveal(value);
      return clear == null ? null : MusicRelayTarget.read(jsonDecode(clear));
    } catch (_) {
      return null;
    }
  }

  static Future<void> remember(String profile, String peer, MusicRelayTarget? target) => _writes.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final key = _targetKey(profile, peer);
    if (target == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, await CredentialVault.protect(jsonEncode(target.toJson())));
    }
  });

  static Future<void> removeProfile(String profile) => _writes.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    for (final key in prefs.keys.where((key) => key.startsWith(prefix(profile))).toList()) {
      await prefs.remove(key);
    }
  });
}
