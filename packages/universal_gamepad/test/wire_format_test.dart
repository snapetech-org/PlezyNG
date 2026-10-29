import 'package:flutter_test/flutter_test.dart';
import 'package:universal_gamepad/universal_gamepad.dart';

/// Pins the wire contract shared with every native implementation.
///
/// The enum ordinals ARE the wire format (native platforms send raw W3C
/// indices), so reordering enum members silently breaks all platforms.
void main() {
  test('GamepadButton ordinals match W3C standard-gamepad indices', () {
    const expected = {
      GamepadButton.a: 0,
      GamepadButton.b: 1,
      GamepadButton.x: 2,
      GamepadButton.y: 3,
      GamepadButton.leftShoulder: 4,
      GamepadButton.rightShoulder: 5,
      GamepadButton.leftTrigger: 6,
      GamepadButton.rightTrigger: 7,
      GamepadButton.back: 8,
      GamepadButton.start: 9,
      GamepadButton.leftStickButton: 10,
      GamepadButton.rightStickButton: 11,
      GamepadButton.dpadUp: 12,
      GamepadButton.dpadDown: 13,
      GamepadButton.dpadLeft: 14,
      GamepadButton.dpadRight: 15,
      GamepadButton.guide: 16,
    };
    expect(GamepadButton.values.length, expected.length);
    expected.forEach((button, index) {
      expect(button.index, index, reason: '$button must be index $index');
      expect(GamepadButton.fromIndex(index), button);
    });
    expect(GamepadButton.fromIndex(-1), isNull);
    expect(GamepadButton.fromIndex(17), isNull);
  });

  test('GamepadAxis ordinals match W3C standard-gamepad indices', () {
    const expected = {
      GamepadAxis.leftStickX: 0,
      GamepadAxis.leftStickY: 1,
      GamepadAxis.rightStickX: 2,
      GamepadAxis.rightStickY: 3,
    };
    expect(GamepadAxis.values.length, expected.length);
    expected.forEach((axis, index) {
      expect(axis.index, index, reason: '$axis must be index $index');
      expect(GamepadAxis.fromIndex(index), axis);
    });
    expect(GamepadAxis.fromIndex(-1), isNull);
    expect(GamepadAxis.fromIndex(4), isNull);
  });

  group('GamepadEvent.fromList', () {
    test('decodes a connection event', () {
      final event = GamepadEvent.fromList(
        [0, 3, 1700000000000, true, 'Xbox Wireless Controller', 0x045e, 0x0b12],
      );
      expect(event, isA<GamepadConnectionEvent>());
      final e = event as GamepadConnectionEvent;
      expect(e.gamepadId, 3);
      expect(e.timestamp, 1700000000000);
      expect(e.connected, isTrue);
      expect(e.info.id, 3);
      expect(e.info.name, 'Xbox Wireless Controller');
      expect(e.info.vendorId, 0x045e);
      expect(e.info.productId, 0x0b12);
    });

    test('decodes a connection event with null name/vendor/product '
        '(iOS/macOS send null IDs)', () {
      final event =
          GamepadEvent.fromList([0, 0, 1700000000000, false, null, null, null]);
      final e = event as GamepadConnectionEvent;
      expect(e.connected, isFalse);
      expect(e.info.name, 'Unknown');
      expect(e.info.vendorId, isNull);
      expect(e.info.productId, isNull);
    });

    test('decodes a button event', () {
      final event = GamepadEvent.fromList([1, 2, 1700000000001, 6, true, 0.75]);
      final e = event as GamepadButtonEvent;
      expect(e.gamepadId, 2);
      expect(e.button, GamepadButton.leftTrigger);
      expect(e.pressed, isTrue);
      expect(e.value, 0.75);
    });

    test('decodes a button event with an int value', () {
      final event = GamepadEvent.fromList([1, 0, 1700000000001, 0, true, 1]);
      expect((event as GamepadButtonEvent).value, 1.0);
    });

    test('decodes an axis event', () {
      final event = GamepadEvent.fromList([2, 1, 1700000000002, 3, -0.5]);
      final e = event as GamepadAxisEvent;
      expect(e.gamepadId, 1);
      expect(e.axis, GamepadAxis.rightStickY);
      expect(e.value, -0.5);
    });

    test('throws on unknown type tag / button / axis index', () {
      expect(() => GamepadEvent.fromList([9, 0, 0]), throwsArgumentError);
      expect(() => GamepadEvent.fromList([1, 0, 0, 17, true, 1.0]),
          throwsArgumentError);
      expect(
          () => GamepadEvent.fromList([2, 0, 0, 4, 0.0]), throwsArgumentError);
    });
  });
}
