# universal_gamepad

Cross-platform Flutter plugin for gamepad input. Provides a unified API for
connection events, button presses, analog triggers, and thumbstick axes across
all six Flutter platforms.

## Platform support

| Platform | Backend                  | Min version     |
|----------|--------------------------|-----------------|
| Android  | InputDevice / KeyEvent   | API 21          |
| iOS      | GameController framework | iOS 14.0        |
| macOS    | GameController framework | macOS 11.0      |
| Windows  | SDL3                     | Windows 10      |
| Linux    | evdev (libevdev)         | -               |
| Web      | W3C Gamepad API          | -               |

## Installation

```yaml
dependencies:
  universal_gamepad: ^1.5.8
```

## Linux

The Linux backend reads gamepad input directly via evdev using
[libevdev](https://www.freedesktop.org/wiki/Software/libevdev/). Hotplug is
handled by monitoring `/dev/input/` with GLib. Events are delivered on the GLib
main loop -- no polling thread, no UI freezes.

```sh
# Debian/Ubuntu
sudo apt install libevdev-dev

# Arch/SteamOS
sudo pacman -S libevdev
```

## Quick start

```dart
import 'package:universal_gamepad/universal_gamepad.dart';

// List connected gamepads
final gamepads = await Gamepad.instance.listGamepads();

// Listen to all events
Gamepad.instance.events.listen((event) {
  switch (event) {
    case GamepadConnectionEvent e:
      print('${e.info.name} ${e.connected ? "connected" : "disconnected"}');
    case GamepadButtonEvent e:
      print('${e.button.name}: ${e.pressed}');
    case GamepadAxisEvent e:
      print('${e.axis.name}: ${e.value}');
  }
});
```

## Filtered streams

```dart
// Only connection events
Gamepad.instance.connectionEvents.listen((e) { ... });

// Only button events
Gamepad.instance.buttonEvents.listen((e) { ... });

// Only axis events
Gamepad.instance.axisEvents.listen((e) { ... });
```

## API reference

### `Gamepad.instance`

| Member             | Type                                | Description                          |
|--------------------|-------------------------------------|--------------------------------------|
| `events`           | `Stream<GamepadEvent>`              | All gamepad events                   |
| `connectionEvents` | `Stream<GamepadConnectionEvent>`    | Connect/disconnect only              |
| `buttonEvents`     | `Stream<GamepadButtonEvent>`        | Button press/release only            |
| `axisEvents`       | `Stream<GamepadAxisEvent>`          | Axis value changes only              |
| `listGamepads()`   | `Future<List<GamepadInfo>>`         | Currently connected gamepads         |
| `dispose()`        | `Future<void>`                      | Release native resources             |
| `pause()`          | `Future<void>`                      | Release device handles / input listeners (Android & Windows; no-op elsewhere) |
| `resume()`         | `Future<void>`                      | Re-acquire gamepads after `pause()`  |

### Event types

**`GamepadConnectionEvent`**
- `gamepadId` -- unique identifier for the session
- `connected` -- `true` on connect, `false` on disconnect
- `info` -- `GamepadInfo` with `id`, `name`, `vendorId?`, `productId?`

**`GamepadButtonEvent`**
- `button` -- `GamepadButton` enum value
- `pressed` -- whether the button is held
- `value` -- analog value from `0.0` (released) to `1.0` (fully pressed)

**`GamepadAxisEvent`**
- `axis` -- `GamepadAxis` enum value
- `value` -- from `-1.0` to `1.0`

### Button mapping (W3C Standard Gamepad)

| Index | Button             | Index | Button           |
|-------|--------------------|-------|------------------|
| 0     | `a` (South)        | 9     | `start` / Menu   |
| 1     | `b` (East)         | 10    | `leftStickButton`|
| 2     | `x` (West)         | 11    | `rightStickButton`|
| 3     | `y` (North)        | 12    | `dpadUp`         |
| 4     | `leftShoulder`     | 13    | `dpadDown`       |
| 5     | `rightShoulder`    | 14    | `dpadLeft`       |
| 6     | `leftTrigger`      | 15    | `dpadRight`      |
| 7     | `rightTrigger`     | 16    | `guide` / Home   |
| 8     | `back` / View      |       |                  |

### Axis mapping

| Index | Axis           | Range                        |
|-------|----------------|------------------------------|
| 0     | `leftStickX`   | -1.0 (left) to 1.0 (right)  |
| 1     | `leftStickY`   | -1.0 (up) to 1.0 (down)     |
| 2     | `rightStickX`  | -1.0 (left) to 1.0 (right)  |
| 3     | `rightStickY`  | -1.0 (up) to 1.0 (down)     |

## Platform notes

- **tvOS**: the Siri Remote only exposes Apple's `microGamepad` profile, which
  this plugin does not map. It will emit a connect event but produce no
  button/axis input; only controllers with an `extendedGamepad` profile
  (e.g. Xbox/PlayStation controllers) deliver input.
- **Linux**: face buttons are mapped per the Linux gamepad spec (by physical
  location). The `xpad` driver (Xbox controllers) reports X/Y by label
  instead; the plugin detects `xpad` via sysfs (with a Microsoft vendor-ID
  fallback) and corrects the mapping. Exotic pads with non-conforming drivers
  may still report X/Y swapped.
- **Web**: state is polled via `requestAnimationFrame`, so input stops while
  the tab is hidden. Browsers may not expose a gamepad until a button is
  pressed. Controllers whose `Gamepad.mapping` is not `"standard"` are still
  mapped positionally and may report wrong button/axis identities.
- **Timestamps** are wall-clock milliseconds since the Unix epoch on all
  platforms.

## Example

The `example/` directory contains a visual demo app that displays connected
gamepad state in real time -- thumbstick crosshairs, button highlights with
analog intensity, and a scrolling event log.

```sh
cd example
flutter run
```
