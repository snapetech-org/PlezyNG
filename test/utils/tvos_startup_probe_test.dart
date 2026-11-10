import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/tvos_startup_probe.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/tvos_startup_probe');
  const codec = StandardMethodCodec();

  Future<Object?> request(String method) {
    final response = Completer<Object?>();
    unawaited(
      binding.defaultBinaryMessenger.handlePlatformMessage(channel.name, codec.encodeMethodCall(MethodCall(method)), (
        data,
      ) {
        if (data == null) {
          response.completeError(MissingPluginException());
        } else {
          response.complete(codec.decodeEnvelope(data));
        }
      }),
    );
    return response.future;
  }

  tearDown(() => channel.setMethodCallHandler(null));

  test('native caller waits for actual startup notification and ignores earlier reports', () async {
    final probe = TvosStartupProbe(channel: channel);
    probe.databaseReady('stale');
    expect(probe.register(isTvos: false), isFalse);
    expect(probe.register(isTvos: true), isTrue);
    var completed = false;
    final result = request('waitForDatabase').then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    probe.databaseReady('3.53.3');
    expect(await result, {'sqliteVersion': '3.53.3'});
    probe.databaseReady('later');
    expect(await request('waitForDatabase'), {'sqliteVersion': '3.53.3'});
  });

  test('unrelated methods cannot query other application data', () async {
    final probe = TvosStartupProbe(channel: channel);
    probe.register(isTvos: true);
    await expectLater(request('arbitrarySql'), throwsA(isA<MissingPluginException>()));
  });
}
