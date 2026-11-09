import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/profiles/pin_attempt_guard.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  test('lockout persists across instances, expires and resets after success', () async {
    var now = DateTime.utc(2026);
    var calls = 0;
    Future<bool> verifier(String pin, String _) async { calls++; return pin == '1234'; }
    PinAttemptGuard create() => PinAttemptGuard(now: () => now, verifier: verifier);
    for (var i = 0; i < 5; i++) {
      expect(await create().verify('owner', '0000', 'hash'), isFalse);
    }
    expect(await create().verify('owner', '1234', 'hash'), isFalse);
    expect(calls, 5);
    now = now.add(const Duration(seconds: 30));
    expect(await create().verify('owner', '1234', 'hash'), isTrue);
    expect(await create().verify('owner', '0000', 'hash'), isFalse);
    expect(await create().verify('other', '1234', 'hash'), isTrue);
  });

  test('concurrent guesses never enter the verifier', () async {
    final pending = Completer<bool>();
    final entered = Completer<void>();
    final guard = PinAttemptGuard(verifier: (_, _) { entered.complete(); return pending.future; });
    final first = guard.verify('owner', '0000', 'hash');
    await entered.future;
    expect(await guard.verify('owner', '1234', 'hash'), isFalse);
    pending.complete(false);
    expect(await first, isFalse);
  });
}
