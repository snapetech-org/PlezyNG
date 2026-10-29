# PlezyNG integration

Vendored from `universal_gamepad` 1.5.8, published by
https://github.com/edde746/universal_gamepad under the included MIT license.
The published archive checksum previously pinned by `pubspec.lock` was
`8570c1c2d354c0959592839f45683599fd7d6a3b8b438b5b634388c6a5724798`.
Ordinary device, button, axis and connection APIs retain their upstream format.

The optional `plezy*` methods on `dev.universal_gamepad/methods` add physical
controller effects without a second input enumerator or a second set of IDs:

- `plezyClaimEffects` / `plezyReleaseEffects`: exclusive opaque ownership token.
  Claiming a different owner stops previous effects; stale releases are ignored.
- `plezyControllerEffects`: device ID, change flags, two rumble magnitudes,
  two trigger magnitudes, durations and sensor enable. Magnitudes are bounded to
  65535 and durations to 1000 ms. At most four device effect objects exist.
- `plezyControllerState`: capability bits (rumble, trigger rumble, gyro,
  accelerometer), then three gyro radians/second and three acceleration m/s².
  The receiver independently validates and bounds every returned number.

Windows uses the existing SDL3 handles; its dependency is pinned to upstream
3.2.8 commit `f6864924f76e1a0b4abaefc76ae2ed22b1a8916e`. This plugin uses C++20
to support Flutter's event-channel header stream insertion of unique pointers.
Linux opens force feedback only on the same verified evdev node and controller
sensor siblings under the same canonical sysfs parent. It does not elevate
permissions. Apple uses the existing GCController identities, haptic localities
and controller motion. Android uses InputDevice vibrators and, from API 31,
that controller's SensorManager. It never substitutes the phone's sensors.

Disconnect, pause and disposal retire effects. Missing hardware capabilities or
permissions leave ordinary input usable. Gamepad interface tests remain under
`test/`; Steam ownership, wire limits and fallback tests are in the app's test
and native runtime suites. SDK builds and real controllers are required to
qualify each physical output path; source checks do not establish that result.
