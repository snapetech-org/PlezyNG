import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../services/base_shared_preferences_service.dart';
import 'profile.dart';

/// All local PIN entry points share durable attempt state. Concurrent attempts
/// are rejected before the KDF, and storage failures fail closed.
class PinAttemptGuard {
  PinAttemptGuard({DateTime Function()? now, Future<bool> Function(String, String)? verifier})
    : _now = now ?? DateTime.now,
      _verifier = verifier ?? verifyPin;

  static final instance = PinAttemptGuard();
  final DateTime Function() _now;
  final Future<bool> Function(String, String) _verifier;
  final Set<String> _busy = {};

  Future<bool> verify(String profileId, String pin, String hash) async {
    if (!_busy.add(profileId)) return false;
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final key = 'profile_pin_attempts_v1_${sha256.convert(utf8.encode(profileId))}';
      final raw = prefs.getString(key);
      final state = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
      final now = _now().millisecondsSinceEpoch;
      final until = state['until'] as int? ?? 0;
      if (until > now) return false;
      final failures = ((state['failures'] as int? ?? 0) + 1).clamp(1, 20).toInt();
      final delay = failures < 5 ? 0 : (30 * (1 << (failures - 5))).clamp(30, 900).toInt();
      // Spend the attempt before verification: a crash cannot refund guesses.
      await prefs.setString(key, jsonEncode({'failures': failures, 'until': now + delay * 1000}));
      if (!await _verifier(pin, hash)) return false;
      await prefs.remove(key);
      return true;
    } catch (_) {
      return false;
    } finally {
      _busy.remove(profileId);
    }
  }
}

Future<bool> verifyLocalProfilePin(Profile profile, String pin) async {
  if (!profile.isLocal) return false;
  final hash = profile.pinHash;
  if (hash == null || hash.isEmpty) return true;
  return PinAttemptGuard.instance.verify(profile.id, pin, hash);
}
