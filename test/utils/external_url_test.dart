import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/external_url.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.plezy/external_player');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugTvosRunnerOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() {
    debugTvosRunnerOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('provider links cannot launch unrelated OS handlers', () async {
    for (final link in [
      'file:///private/data',
      'javascript:alert(1)',
      'data:text/plain,hello',
      'intent://other',
      'vlc://other',
    ]) {
      expect(await openExternalUrl(Uri.parse(link)), isFalse);
    }
    expect(calls, isEmpty);
  });

  test('web links and the tvOS YouTube handoff reach the native channel', () async {
    for (final link in ['https://example.com/trailer', 'youtube://www.youtube.com/watch?v=abc']) {
      expect(await openExternalUrl(Uri.parse(link)), isTrue);
      expect(calls.last.method, 'openUrl');
      expect(calls.last.arguments, {'url': link});
    }
  });

  test('a native handoff failure returns false', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'UNAVAILABLE');
    });
    expect(await openExternalUrl(Uri.parse('https://example.com/trailer')), isFalse);
  });
}
