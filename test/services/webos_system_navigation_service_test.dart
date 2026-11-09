import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/webos_system_navigation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = BasicMessageChannel<Object?>('com.plezy/webos_system_navigation', StandardMessageCodec());
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    WebosSystemNavigationService.resetForTesting();
    WebosSystemNavigationService.debugPlatformSupported = true;
  });

  tearDown(() {
    messenger.setMockDecodedMessageHandler<Object?>(channel, null);
    WebosSystemNavigationService.resetForTesting();
  });

  test('false and null acknowledgements remain retryable until true', () async {
    final messages = <Object?>[];
    final replies = <Object?>[false, null, true];
    messenger.setMockDecodedMessageHandler<Object?>(channel, (message) async {
      messages.add(message);
      return replies.removeAt(0);
    });

    await WebosSystemNavigationService.setBackPassthroughEnabled(true);
    await WebosSystemNavigationService.setBackPassthroughEnabled(true);
    await WebosSystemNavigationService.setBackPassthroughEnabled(true);
    await WebosSystemNavigationService.setBackPassthroughEnabled(true);

    expect(messages, [
      {'backPassthroughEnabled': true},
      {'backPassthroughEnabled': true},
      {'backPassthroughEnabled': true},
    ]);
  });

  test('serializes an opposing trailing value and latest desired state wins', () async {
    final messages = <Object?>[];
    var activeSends = 0;
    var maximumActiveSends = 0;
    final trueStarted = Completer<void>();
    final releaseTrue = Completer<Object?>();

    messenger.setMockDecodedMessageHandler<Object?>(channel, (message) async {
      messages.add(message);
      activeSends++;
      maximumActiveSends = activeSends > maximumActiveSends ? activeSends : maximumActiveSends;
      try {
        final enabled = (message as Map<Object?, Object?>)['backPassthroughEnabled'];
        if (enabled == true) {
          trueStarted.complete();
          return await releaseTrue.future;
        }
        return true;
      } finally {
        activeSends--;
      }
    });

    await WebosSystemNavigationService.setBackPassthroughEnabled(false);
    final enable = WebosSystemNavigationService.setBackPassthroughEnabled(true);
    await trueStarted.future;
    final disable = WebosSystemNavigationService.setBackPassthroughEnabled(false);
    releaseTrue.complete(true);
    await Future.wait([enable, disable]);
    await WebosSystemNavigationService.setBackPassthroughEnabled(false);

    expect(maximumActiveSends, 1);
    expect(messages, [
      {'backPassthroughEnabled': false},
      {'backPassthroughEnabled': true},
      {'backPassthroughEnabled': false},
    ]);
  });

  test('platform exception does not poison an identical retry', () async {
    final messages = <Object?>[];
    var fail = true;
    messenger.setMockDecodedMessageHandler<Object?>(channel, (message) async {
      messages.add(message);
      if (fail) {
        fail = false;
        throw PlatformException(code: 'controller_unavailable');
      }
      return true;
    });

    await WebosSystemNavigationService.setBackPassthroughEnabled(true);
    await WebosSystemNavigationService.setBackPassthroughEnabled(true);
    await WebosSystemNavigationService.setBackPassthroughEnabled(true);

    expect(messages, [
      {'backPassthroughEnabled': true},
      {'backPassthroughEnabled': true},
    ]);
  });

  test('non-webOS calls never reach the platform channel', () async {
    final messages = <Object?>[];
    messenger.setMockDecodedMessageHandler<Object?>(channel, (message) async {
      messages.add(message);
      return true;
    });
    WebosSystemNavigationService.debugPlatformSupported = false;

    await WebosSystemNavigationService.setBackPassthroughEnabled(true);
    await WebosSystemNavigationService.setBackPassthroughEnabled(false);

    expect(messages, isEmpty);
  });
}
