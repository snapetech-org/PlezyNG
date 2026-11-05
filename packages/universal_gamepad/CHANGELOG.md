## 1.5.8

- **Web**: fix broken web builds — the plugin's `WebGamepad` class was not reachable from the entry point declared in `pubspec.yaml`, so `flutter build web` failed in consuming apps. The web entry point is now `universal_gamepad_web.dart`.
- **Windows**: `resume()` now re-enumerates gamepads that stayed connected during `pause()` (previously they were never re-detected until physically re-plugged).
- **Windows**: fix a rare wedge where events sent before the window handle was captured were queued but never flushed.
- **Android**: holding a button no longer emits repeated `pressed` events (auto-repeat key events are filtered).
- **Android**: process batched historical motion samples and apply the device-reported flat region (deadzone) to stick axes, per the Android game-controller guidance; trigger press threshold unified to 0.5 to match other platforms.
- **Android**: input events are no longer emitted for devices that fail the gamepad check; disconnect events now carry the real device name/vendor/product.
- **Linux**: Xbox-family controllers driven by `xpad` no longer report the X and Y face buttons swapped (xpad maps them by label; PlayStation and spec-compliant drivers by location — detected via the sysfs driver link).
- **Linux**: fix duplicate connect events when the Dart side subscribes right after startup, and stop invoking the engine callback while holding an internal lock.
- **iOS**: guard against duplicate connect notifications (matching macOS behavior).
- **iOS/macOS**: gamepad names now use the same precedence on both platforms (`vendorName`, then `productCategory`); events already on the main thread are delivered without an extra runloop hop and can no longer hit a cancelled sink.
- Removed the unconditional `dart:io` import from the shared Dart code.
- Podspec versions now track the package version.

## 1.5.7

- Fix Linux gamepad reconnect detection after controller sleep or disconnect.

## 1.5.6

- Add Android support for `pause()` and `resume()` by detaching and reattaching native input listeners.
