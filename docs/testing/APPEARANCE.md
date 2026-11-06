# Appearance and responsive layout checks

The appearance suite runs with the ordinary `flutter test` command and the
existing Linux test job. Baselines use Flutter 3.47.1 (the version pinned in
`.github/workflows/ci.yml`), the bundled Go Noto font and bundled Material
Symbols. No network images, account data or device fonts are needed.

```sh
flutter test test/appearance
```

`responsive_geometry_test.dart` covers folded and ordinary phones, phone
landscape, tablets, automotive, short desktop windows, Windows/macOS/Linux
layouts, ultrawide and super-ultrawide windows, and 720p/4K TV layouts.
Each case runs with normal and doubled text in LTR and Arabic RTL. TV cases
include both a 3840×2160 physical display at DPR 2 (1920×1080 logical) and a
3840×2160 logical viewport. Geometry follows logical pixels, not panel pixels.

The tests mount the home hero/shelves, the media-detail screen, shared settings
components, player controls and login. They check overflow, hero content and
metadata-label clip bounds, and scroll shelves into view. Additional component checks cover:

- identical loading/loaded artwork bounds across text scales and spacing;
- centred, bounded settings content inside a resized pane;
- hosted and modal sheets with a keyboard open and custom theme corners;
- timestamp wrapping and usable seek-track width with enlarged text.

`appearance_golden_test.dart` checks 24 PNG baselines: home, details, settings
and player controls in light, dark and OLED appearances, each as a desktop
layout and a phone layout with Arabic RTL and doubled text. Settings and player
fixtures compose production widgets without network or playback services;
they do not start a native decoder. The detail fixture omits runtime duration
to avoid a wall-clock-dependent "ends at" label in screenshots.

To review an intentional visual change on Linux with the pinned Flutter SDK:

```sh
flutter test --update-goldens test/appearance/appearance_golden_test.dart
flutter test test/appearance
```

Inspect every changed PNG in `test/appearance/goldens/` before committing it.
Do not update baselines merely to make a failed comparison pass. Image failures
write expected/actual/difference artifacts next to the tests. Those artifacts
are temporary and must not be committed.

These are deterministic layout/rendering checks. Physical-device review still
covers platform window chrome, display cutouts, HDR/video backgrounds, remote
focus visibility at viewing distance, and native keyboard behaviour. An
unrepresented route or a new breakpoint needs its own fixture/check.
