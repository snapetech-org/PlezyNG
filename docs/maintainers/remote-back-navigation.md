# Remote Back navigation

Back belongs to the innermost visible UI. During TV playback it returns from
an options subpage (including Audio Output) to options, closes options, hides
the paused OSD, then leaves the player. Each press performs one step. Explicit
Back can hide controls held for scrubbing/pointer interaction; automatic
hide retains those holds. A second press during the OSD fade can leave playback.
Phone Back retains its direct player-exit behavior.

`BackKeyOwner` owns both the physical key and a focused `SystemBackIntent`.
`InputModeTracker` dispatches native/gesture Back to the innermost action before
the navigator, retaining Android's held-key duplicate suppression. Do not add
independent nested `PopScope` handlers for sheet subpages: Flutter can notify
every vetoing scope on one Back. The sheet host handles pushed pages and closes
only after the internal page owner declines. Focus must land inside even
pointer-opened pages so neither key nor native Back skips the inner owner.
Covered routes cannot consume Back through stale focus.

The native webOS runner claims `_WEBOS_ACCESS_POLICY_KEYS_BACK` before Dart
starts. Otherwise webOS intercepts the key and shows its exit dialog while
menus remain open. [Kodi's webOS shell](https://github.com/xbmc/xbmc/blob/master/xbmc/windowing/wayland/ShellSurfaceWebOSShell.cpp)
uses this same window property to receive Back. `MainScreen` updates the
`com.plezy/webos_system_navigation` channel to allow system passthrough only
at the home root with sidebar focus, no profile picker/sheet, and a current
route. The existing tvOS Menu bridge uses the same root policy. Keep updates
serialized so a delayed home acknowledgement cannot enable exit over playback.

Regression coverage lives in `back_press_test.dart`,
`navigator_back_handler_test.dart`, `video_settings_sheet_test.dart`,
`video_controls_test.dart`, `main_screen_layout_test.dart`, and the two TV
navigation-service tests. The settings tests exercise both native Back and
remote key presses against the actual sheet. The release's
`tools/webos/check_audio_plugin_syntax.sh` also compiles the runner against the
checksum-pinned LG ARM SDK before the expensive native build.

Device acceptance requires a fresh TV test window; do not switch inputs or
launch the app while someone is watching. Check submenu → options → OSD →
hidden OSD → browse, other-tab → home, and native exit only at home. Headless
tests and SDK compilation establish routing correctness; they do not claim a
physical remote/device qualification.
